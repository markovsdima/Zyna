//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#include <metal_stdlib>
#include "loki_header.metal"

using namespace metal;

// MARK: - Data Structures

struct Droplet {
    packed_float2 position;     // relative to item frame origin, in points (Y-down)
    packed_float2 velocity;     // px/s (Y-down = gravity positive)
    packed_float4 color;        // RGB from bubble texture, A = per-droplet opacity
    float         baseSize;     // radius in points
    float         aspectRatio;  // Y/X scale (reserved for velocity stretching)
    float         rotation;     // radians
    float         lifetime;     // remaining seconds
    uint          phase;        // 0=flying, 2=fading
    float         dragFactor;   // deceleration rate
    packed_float2 srcUV;        // source UV in bubble texture (for textured fragments)
};

// MARK: - Quad Geometry

constant static float2 quadVertices[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 1.0)
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float  alpha;
    float2 srcUV;
    float2 patchExtent;  // UV extent of this droplet's texture patch
};

// MARK: - Compute: Initialize Droplets

kernel void splashInitializeDroplet(
    device Droplet *droplets             [[buffer(0)]],
    texture2d<float, access::sample> tex [[texture(0)]],
    const device float2 &itemSize        [[buffer(1)]],
    const device uint   &dropletCount    [[buffer(2)]],
    uint gid                             [[thread_position_in_grid]]
) {
    if (gid >= dropletCount) return;

    Loki rng = Loki(gid, 42, 137);

    Droplet d;

    // Gentle scaling: large bubbles get more droplets (Swift side) rather than bigger ones
    float areaScale = pow(sqrt(itemSize.x * itemSize.y) / 90.0, 0.35);
    areaScale = clamp(areaScale, 1.0, 1.6);

    // Grid layout: distribute droplets to cover the entire bubble
    uint cols = uint(ceil(sqrt(float(dropletCount) * itemSize.x / itemSize.y)));
    uint rows = (dropletCount + cols - 1) / cols;

    float cellW = itemSize.x / float(cols);
    float cellH = itemSize.y / float(rows);

    float posX, posY;

    if (gid < rows * cols) {
        uint col = gid % cols;
        uint row = gid / cols;
        float jitterX = (rng.rand() - 0.5) * cellW * 0.3;
        float jitterY = (rng.rand() - 0.5) * cellH * 0.3;
        posX = (float(col) + 0.5) * cellW + jitterX;
        posY = (float(row) + 0.5) * cellH + jitterY;
    } else {
        posX = rng.rand() * itemSize.x;
        posY = rng.rand() * itemSize.y;
    }

    posX = clamp(posX, 0.0, itemSize.x);
    posY = clamp(posY, 0.0, itemSize.y);
    d.position = packed_float2(posX, posY);

    // Source UV for textured fragment rendering
    float2 uv = float2(posX / itemSize.x, posY / itemSize.y);
    d.srcUV = packed_float2(uv);

    // Color: sample from bubble texture; alpha encodes per-droplet opacity variation
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 sampledColor = tex.sample(s, uv);
    float opacity = 0.4 + rng.rand() * 0.6;
    d.color = packed_float4(float4(sampledColor.rgb, opacity));

    // Size: more small droplets, fewer large ones
    float baseGridSize = max(cellW, cellH);
    float sizeRoll = rng.rand();
    float sizeMul;
    if (sizeRoll < 0.70) {
        sizeMul = 0.4 + rng.rand() * 0.4;       // 70% small: 0.4–0.8×
    } else if (sizeRoll < 0.92) {
        sizeMul = 0.8 + rng.rand() * 0.7;       // 22% medium: 0.8–1.5×
    } else {
        sizeMul = 1.5 + rng.rand() * 1.5;       // 8% large: 1.5–3.0×
    }
    d.baseSize = max(baseGridSize * sizeMul * areaScale, 2.0);

    // Velocity: outward from center
    float2 center = itemSize * 0.5;
    float2 toEdge = float2(posX, posY) - center;
    float distFromCenter = length(toEdge);
    float2 dir;
    if (distFromCenter > 0.001) {
        dir = toEdge / distFromCenter;
    } else {
        float a = rng.rand() * 6.28318530718;
        dir = float2(cos(a), sin(a));
    }

    // Angular spread for natural scatter
    float spread = (rng.rand() - 0.5) * 0.6;
    float cs = cos(spread);
    float sn = sin(spread);
    dir = float2(dir.x * cs - dir.y * sn, dir.x * sn + dir.y * cs);

    float bubbleDiag = sqrt(itemSize.x * itemSize.x + itemSize.y * itemSize.y);
    float normalizedDist = distFromCenter / (bubbleDiag * 0.5);
    float speed = bubbleDiag * (1.2 + rng.rand() * 1.5);
    speed *= (0.7 + normalizedDist * 0.6);     // edge droplets slightly faster
    speed /= max(d.baseSize / (baseGridSize * areaScale), 0.5);

    d.velocity = packed_float2(dir.x * speed, dir.y * speed);

    d.aspectRatio = 1.0;
    d.rotation = rng.rand() * 6.28318530718;
    d.lifetime = 0.5 + rng.rand() * 0.4;
    d.phase = 0;
    d.dragFactor = 5.0 / max(d.baseSize / (baseGridSize * areaScale), 1.0);

    droplets[gid] = d;
}

// MARK: - Compute: Update Droplets

kernel void splashUpdateDroplet(
    device Droplet *droplets          [[buffer(0)]],
    const device float  &timeStep     [[buffer(1)]],
    const device uint   &dropletCount [[buffer(2)]],
    uint gid                          [[thread_position_in_grid]]
) {
    if (gid >= dropletCount) return;

    Droplet d = droplets[gid];

    if (d.phase == 0) {
        // Flying: apply physics
        float2 vel = float2(d.velocity);
        float2 pos = float2(d.position);

        // Gravity (Y-down in UIKit; appears upward due to inverted table scroll)
        vel.y += 800.0 * timeStep;

        // Air drag (smaller particles decelerate faster)
        float drag = 1.0 - d.dragFactor * timeStep;
        drag = max(drag, 0.0);
        vel *= drag;

        pos += vel * timeStep;

        d.velocity = packed_float2(vel);
        d.position = packed_float2(pos);

        d.lifetime -= timeStep;
        if (d.lifetime <= 0.0) {
            d.phase = 2;
            d.lifetime = 0.15;
        }
    } else {
        // Fading out
        d.lifetime -= timeStep;
        if (d.lifetime <= 0.0) {
            d.position = packed_float2(-1000.0, -1000.0);
            d.lifetime = -1.0;
        }
    }

    droplets[gid] = d;
}

// MARK: - Noise Utilities

float splashHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float splashNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = splashHash(i);
    float b = splashHash(i + float2(1.0, 0.0));
    float c = splashHash(i + float2(0.0, 1.0));
    float d = splashHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Inflate quads so gaussian blobs overlap and merge into metaballs
constant float blobScale = 2.5;

// MARK: - Vertex Shader

vertex VertexOut splashVertex(
    const device float2   &containerSize [[buffer(0)]],  // container bounds in points
    const device float2   &itemOrigin    [[buffer(1)]],  // item frame origin (UIKit points)
    const device float2   &itemSize      [[buffer(2)]],  // item frame size (UIKit points)
    const device Droplet  *droplets      [[buffer(3)]],
    unsigned int vid                      [[vertex_id]],
    unsigned int iid                      [[instance_id]]
) {
    VertexOut out;

    Droplet d = droplets[iid];

    if (d.lifetime < -0.5) {
        out.position = float4(-10.0, -10.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.color = float4(0.0);
        out.alpha = 0.0;
        out.srcUV = float2(0.0);
        out.patchExtent = float2(0.0);
        return out;
    }

    float2 quadVertex = quadVertices[vid];
    out.uv = quadVertex;

    // Droplet quad: inflated by blobScale for metaball overlap
    float w = d.baseSize * blobScale;
    float h = d.baseSize * d.aspectRatio * blobScale;

    // Rotate quad around center
    float cosR = cos(d.rotation);
    float sinR = sin(d.rotation);

    float2 local = (quadVertex - 0.5) * float2(w, h);
    float2 rotated = float2(
        local.x * cosR - local.y * sinR,
        local.x * sinR + local.y * cosR
    );

    // Item-local position → screen position (UIKit coords, Y-down)
    float2 screenPos = itemOrigin + float2(d.position) + rotated;

    // UIKit → Metal NDC: X [0,w]→[-1,+1], Y [0,h]→[+1,-1] (flip Y)
    float ndcX = screenPos.x / containerSize.x * 2.0 - 1.0;
    float ndcY = 1.0 - screenPos.y / containerSize.y * 2.0;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);

    out.color = float4(d.color);

    // Texture mapping: source UV and patch extent for fragment sampling
    out.srcUV = float2(d.srcUV);
    out.patchExtent = float2(w, h) / itemSize;

    // Alpha based on phase
    if (d.phase == 2) {
        out.alpha = max(0.0, d.lifetime / 0.15);
    } else {
        out.alpha = 1.0;
    }

    return out;
}

// MARK: - Pass 1: Blob Accumulation

fragment half4 splashBlobFragment(VertexOut in [[stage_in]]) {
    float2 centered = in.uv - 0.5;
    float dist2 = dot(centered, centered) * 4.0;

    // Gaussian falloff — soft enough for smooth merging
    float energy = exp(-dist2 * 5.0);
    if (energy < 0.001) discard_fragment();

    // Output: energy-weighted color (RGB * e) and raw energy (A)
    // color.a carries per-droplet opacity variation from init
    half e = half(energy * in.alpha * in.color.a);
    return half4(half3(in.color.rgb) * e, e);
}

// MARK: - Pass 2: Metaball Composite

struct CompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeVertexOut splashCompositeVertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
    };
    float2 uvs[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
        float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0)
    };

    CompositeVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment half4 splashCompositeFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> blobTex [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, filter::linear);
    float4 blob = blobTex.sample(s, in.uv);

    float energy = blob.a;
    if (energy < 0.05) discard_fragment();

    // Multi-scale noise for organic edge deformation
    float2 pixelCoord = in.uv * float2(blobTex.get_width(), blobTex.get_height());
    float n = splashNoise(pixelCoord * 0.04) * 0.06
            + splashNoise(pixelCoord * 0.12) * 0.04;

    // Metaball threshold with noisy boundary
    float threshold = 0.4;
    float edge = smoothstep(threshold - 0.06 + n, threshold + 0.02 + n, energy);
    if (edge < 0.01) discard_fragment();

    // Reconstruct color from energy-weighted accumulation
    float3 baseColor = blob.rgb / max(energy, 0.001);

    // Gradient-based pseudo-normal from energy field
    float2 texelSize = 1.0 / float2(blobTex.get_width(), blobTex.get_height());
    float eL = blobTex.sample(s, in.uv + float2(-texelSize.x, 0.0)).a;
    float eR = blobTex.sample(s, in.uv + float2( texelSize.x, 0.0)).a;
    float eU = blobTex.sample(s, in.uv + float2(0.0, -texelSize.y)).a;
    float eD = blobTex.sample(s, in.uv + float2(0.0,  texelSize.y)).a;

    float3 normal = normalize(float3((eL - eR) * 2.0, (eU - eD) * 2.0, 0.15));

    // Blinn-Phong lighting — top-right light source
    float3 lightDir = normalize(float3(0.3, -0.5, 1.0));
    float diffuse = max(dot(normal, lightDir), 0.0) * 0.2 + 0.8;
    float3 halfVec = normalize(lightDir + float3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(normal, halfVec), 0.0), 32.0);

    float3 finalColor = baseColor * diffuse + spec * 0.3;

    // Edge darkening for volume
    float depth = smoothstep(threshold, threshold + 0.3, energy);
    finalColor *= 0.88 + 0.12 * depth;

    // Thin areas (low energy) are more transparent — liquid feel
    float alphaFromEnergy = smoothstep(threshold, threshold + 0.4, energy);
    float alphaNoise = splashNoise(pixelCoord * 0.06) * 0.15;
    float finalAlpha = edge * (0.65 + 0.35 * alphaFromEnergy + alphaNoise);

    return half4(half3(finalColor), half(finalAlpha));
}
