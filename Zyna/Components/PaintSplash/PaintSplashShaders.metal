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
    float         flightAge;    // seconds since this droplet entered flight
    float         rotation;     // radians
    float         lifetime;     // remaining seconds
    uint          phase;        // 0=flying, 2=fading
    float         dragFactor;   // deceleration rate
    packed_float2 srcUV;        // source UV in bubble texture (for textured fragments)
};

constant uint splashPhaseMask = 0x3;
constant uint splashPhaseFlying = 0;
constant uint splashPhaseFading = 2;
constant uint splashPhaseGlassChecked = 0x4;
constant uint splashGlassCellCols = 12;
constant uint splashGlassCellRows = 8;
constant uint splashGlassCellsPerTarget = splashGlassCellCols * splashGlassCellRows;
constant uint splashGlassNozzleSlotsPerTarget = 8;
constant uint splashSPHParticlesPerNozzle = 4;
constant float splashSPHStateEmpty = 0.0;
constant float splashSPHStateAttached = 1.0;
constant float splashSPHStateDetached = 2.0;

struct GlassHitTarget {
    packed_float4 rect;         // x, y, width, height in overlay points
    packed_float4 params;       // radius, hitProbability, shapeKind, stableSeed
};

struct GlassDroplet {
    packed_float2 position;     // overlay points, Y-down
    packed_float2 velocity;     // points/s
    packed_float4 color;        // source paint color, A = opacity
    float radius;               // points
    float age;                  // seconds since glass impact
    float lifetime;             // seconds
    float seed;                 // deterministic variation
    float stretch;              // vertical shape multiplier
    float active;               // 0 or 1
    float impact;               // initial impact energy
    float pad;                  // keeps the struct at 16 floats
};

struct GlassSPHParticle {
    packed_float2 position;     // overlay points, Y-down
    packed_float2 velocity;     // points/s
    packed_float4 color;        // unpremultiplied paint color
    float radius;               // metaball radius in points
    float mass;                 // paint amount
    float density;              // SPH density estimate
    float pressure;             // incompressibility pressure
    float age;                  // seconds in current state
    float lifetime;             // detached fade lifetime
    float seed;                 // deterministic variation
    float active;               // 0 or 1
    float anchorStrength;       // adhesion to lower glass edge
    packed_float2 anchor;       // lower edge contact point
    float state;                // 0 empty, 1 attached, 2 detached
    float pad;                  // spare / cooldown age
    packed_float2 surfaceNormal;// contact normal captured at spawn
    float surfaceCurvature;     // local curvature, 0 on straight lower rim
    float profile;              // per-source behavior family
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

// Seeds textured splash droplets from the item snapshot. Transparent pixels are
// disabled immediately so only visible paint contributes to later glass mass.
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

    float areaScale = pow(sqrt(itemSize.x * itemSize.y) / 90.0, 0.35);
    areaScale = clamp(areaScale, 1.0, 1.6);

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

    float2 uv = float2(posX / itemSize.x, posY / itemSize.y);
    d.srcUV = packed_float2(uv);

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 sampledColor = tex.sample(s, uv);
    float coverage = saturate(sampledColor.a);
    if (coverage < 0.018) {
        d.velocity = packed_float2(0.0, 0.0);
        d.color = packed_float4(0.0, 0.0, 0.0, 0.0);
        d.baseSize = 0.0;
        d.flightAge = 0.0;
        d.rotation = 0.0;
        d.lifetime = -1.0;
        d.phase = splashPhaseFading | splashPhaseGlassChecked;
        d.dragFactor = 1.0;
        droplets[gid] = d;
        return;
    }
    float coverageWeight = smoothstep(0.018, 0.18, coverage);
    float3 paintColor = clamp(sampledColor.rgb / max(coverage, 0.001), 0.0, 1.0);
    float opacity = (0.4 + rng.rand() * 0.6) * coverageWeight;
    d.color = packed_float4(float4(paintColor, opacity));

    float baseGridSize = max(cellW, cellH);
    float sizeRoll = rng.rand();
    float sizeMul;
    if (sizeRoll < 0.70) {
        sizeMul = 0.4 + rng.rand() * 0.4;
    } else if (sizeRoll < 0.92) {
        sizeMul = 0.8 + rng.rand() * 0.7;
    } else {
        sizeMul = 1.5 + rng.rand() * 1.5;
    }
    d.baseSize = max(baseGridSize * sizeMul * areaScale, 2.0);

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

    float spread = (rng.rand() - 0.5) * 0.6;
    float cs = cos(spread);
    float sn = sin(spread);
    dir = float2(dir.x * cs - dir.y * sn, dir.x * sn + dir.y * cs);

    float bubbleDiag = sqrt(itemSize.x * itemSize.x + itemSize.y * itemSize.y);
    float normalizedDist = distFromCenter / (bubbleDiag * 0.5);
    float speed = bubbleDiag * (1.2 + rng.rand() * 1.5);
    speed *= (0.7 + normalizedDist * 0.6);
    speed /= max(d.baseSize / (baseGridSize * areaScale), 0.5);

    d.velocity = packed_float2(dir.x * speed, dir.y * speed);

    d.flightAge = 0.0;
    d.rotation = rng.rand() * 6.28318530718;
    d.lifetime = 0.5 + rng.rand() * 0.4;
    d.phase = 0;
    d.dragFactor = 5.0 / max(d.baseSize / (baseGridSize * areaScale), 1.0);

    droplets[gid] = d;
}

float splashHash(float2 p);
float splashNoise(float2 p);

// MARK: - Glass Target Geometry

// Signed-distance helpers keep hit tests, normals, and outlet placement tied to
// the same rounded-rect/circle model the glass renderer uses.
inline float splashRoundedRectDistance(float2 p, float2 size, float radius) {
    radius = min(radius, min(size.x, size.y) * 0.5);
    float2 halfSize = size * 0.5;
    float2 q = abs(p - halfSize) - (halfSize - radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

inline float splashCircleDistance(float2 p, float2 size) {
    float radius = min(size.x, size.y) * 0.5;
    return length(p - size * 0.5) - radius;
}

inline float splashGlassTargetDistance(float2 p, float2 size, float4 params) {
    if (params.z > 0.5) {
        return splashCircleDistance(p, size);
    }
    return splashRoundedRectDistance(p, size, params.x);
}

inline float2 splashClampToGlassTarget(float2 p, float2 size, float4 params) {
    float2 clamped = clamp(p, float2(0.0), size);
    if (params.z <= 0.5) {
        return clamped;
    }

    float2 center = size * 0.5;
    float radius = min(size.x, size.y) * 0.5;
    float2 delta = clamped - center;
    float len = length(delta);
    if (len <= radius || len <= 0.001) {
        return clamped;
    }
    return center + delta / len * radius;
}

inline float2 splashGlassTargetNormal(float2 p, float2 size, float4 params) {
    float eps = max(0.35, min(size.x, size.y) * 0.002);
    float dx = splashGlassTargetDistance(p + float2(eps, 0.0), size, params)
             - splashGlassTargetDistance(p - float2(eps, 0.0), size, params);
    float dy = splashGlassTargetDistance(p + float2(0.0, eps), size, params)
             - splashGlassTargetDistance(p - float2(0.0, eps), size, params);
    float2 n = float2(dx, dy);
    float len = length(n);
    return len > 0.0001 ? n / len : float2(0.0, 1.0);
}

// MARK: - Glass Bottom Outlets

// Lower-edge masks describe where surface film is allowed to gather and feed
// drips. Capsules use distributed slots; circles drain along their curved rim.
struct GlassTargetBottomInfo {
    float distance;
    float footMask;
    float nozzleMask;
    float nozzleX;
    float bottomY;
    float nozzleWidth;
    float seed;
};

inline float splashRoundedRectBottomY(float x, float2 size, float radius) {
    radius = min(radius, min(size.x, size.y) * 0.5);
    float clampedX = clamp(x, 0.0, size.x);
    if (radius <= 0.001) {
        return size.y;
    }

    if (clampedX < radius) {
        float dx = clampedX - radius;
        return size.y - radius + sqrt(max(radius * radius - dx * dx, 0.0));
    }
    if (clampedX > size.x - radius) {
        float dx = clampedX - (size.x - radius);
        return size.y - radius + sqrt(max(radius * radius - dx * dx, 0.0));
    }
    return size.y;
}

inline float splashGaussian(float x, float width) {
    float t = x / max(width, 0.001);
    return exp(-t * t);
}

inline float splashPaintedSurfaceMask(float4 state) {
    float mass = max(state.a, 0.0);
    if (mass <= 0.001) {
        return 0.0;
    }

    float paintMass = max(max(state.r, state.g), state.b);
    float paintRatio = paintMass / max(mass, 0.001);
    return smoothstep(0.006, 0.026, paintMass)
        * smoothstep(0.010, 0.055, paintRatio);
}

inline GlassTargetBottomInfo splashGlassTargetBottomInfo(float2 local, float2 size, float4 params) {
    GlassTargetBottomInfo info;
    info.distance = 100000.0;
    info.footMask = 0.0;
    info.nozzleMask = 0.0;
    info.nozzleX = size.x * 0.5;
    info.bottomY = size.y;
    info.nozzleWidth = 7.0;
    info.seed = params.w;

    float seed = params.w;
    if (params.z > 0.5) {
        float radius = min(size.x, size.y) * 0.5;
        float2 center = size * 0.5;
        float dx = local.x - center.x;
        float bottomY = center.y + sqrt(max(radius * radius - dx * dx, 0.0));
        info.distance = bottomY - local.y;
        info.footMask = 1.0 - smoothstep(radius - 1.5, radius + 5.0, abs(dx));

        float nozzleX = center.x;
        float width = max(7.0, radius * 0.30);
        info.nozzleMask = splashGaussian(local.x - nozzleX, width) * info.footMask;
        info.nozzleX = nozzleX;
        info.bottomY = center.y + radius;
        info.nozzleWidth = width;
        info.seed = seed + 1.37;
        return info;
    }

    float radius = min(params.x, min(size.x, size.y) * 0.5);
    float bottomY = splashRoundedRectBottomY(local.x, size, radius);
    info.distance = bottomY - local.y;
    float sideSoftness = min(max(size.y * 0.16, 5.0), 18.0);
    info.footMask = smoothstep(-4.0, sideSoftness, local.x)
        * (1.0 - smoothstep(size.x - sideSoftness, size.x + 4.0, local.x));

    float width = max(7.0, min(size.y * 0.34, size.x * 0.070));
    float nozzles = 0.0;
    float selectedX = size.x * 0.5;
    float selectedSeed = seed + 3.0;
    for (uint slot = 0; slot < splashGlassNozzleSlotsPerTarget; slot++) {
        float slotF = float(slot);
        float slot01 = splashGlassNozzleSlotsPerTarget > 1
            ? slotF / float(splashGlassNozzleSlotsPerTarget - 1)
            : 0.5;
        float selectedSeedCandidate = seed + 3.0 + slotF;
        float jitter = (splashHash(float2(selectedSeedCandidate, 16.9)) - 0.5) * 0.032;
        float x = clamp(mix(0.12, 0.88, slot01) + jitter, 0.08, 0.92) * size.x;
        float slotEnergy = mix(0.76, 1.0, splashHash(float2(selectedSeedCandidate, 21.0)));
        float slotWidth = width * mix(0.72, 1.04, splashHash(float2(selectedSeedCandidate, 31.0)));
        float slotMask = splashGaussian(local.x - x, slotWidth) * slotEnergy;
        nozzles = max(nozzles, slotMask);
        if (slotMask >= nozzles) {
            selectedX = x;
            selectedSeed = selectedSeedCandidate;
        }
    }
    info.nozzleMask = nozzles * info.footMask;
    info.nozzleX = selectedX;
    info.bottomY = bottomY;
    info.nozzleWidth = width;
    info.seed = selectedSeed;
    return info;
}

struct GlassSurfaceTargetInfo {
    float mask;
    float glassMask;
    float spillMask;
    float bottomRim;
};

struct GlassNozzleInfo {
    float enabled;
    float2 sourcePoint;
    float width;
    float seed;
    float2 normal;
    float curvature;
};

inline GlassSurfaceTargetInfo splashGlassSurfaceTargetInfo(
    float2 overlayPoint,
    const device GlassHitTarget *hitTargets,
    uint hitTargetCount
) {
    GlassSurfaceTargetInfo info;
    info.mask = 0.0;
    info.glassMask = 0.0;
    info.spillMask = 0.0;
    info.bottomRim = 0.0;

    for (uint i = 0; i < hitTargetCount; i++) {
        GlassHitTarget target = hitTargets[i];
        float4 targetRect = float4(target.rect);
        float4 targetParams = float4(target.params);
        float2 origin = targetRect.xy;
        float2 size = targetRect.zw;
        if (size.x <= 0.0 || size.y <= 0.0) continue;

        float2 local = overlayPoint - origin;
        float distance = splashGlassTargetDistance(local, size, targetParams);
        float glassMask = 1.0 - smoothstep(0.0, 2.75, distance);
        GlassTargetBottomInfo bottom = splashGlassTargetBottomInfo(local, size, targetParams);
        float bottomDistance = bottom.distance;
        float belowDepth = max(-bottomDistance, 0.0);
        float belowGlass = smoothstep(0.0, 5.0, belowDepth);
        float spillMask = bottom.nozzleMask * belowGlass;
        float bottomBand = (1.0 - smoothstep(2.0, 22.0, bottomDistance))
            * smoothstep(-3.0, 3.0, bottomDistance);

        info.glassMask = max(info.glassMask, glassMask);
        info.spillMask = max(info.spillMask, spillMask);
        info.mask = max(info.mask, max(glassMask, spillMask));
        info.bottomRim = max(info.bottomRim, bottomBand * bottom.footMask * glassMask);
    }

    return info;
}

inline GlassNozzleInfo splashGlassTargetNozzleInfo(GlassHitTarget target, uint slot) {
    GlassNozzleInfo info;
    info.enabled = 0.0;
    info.sourcePoint = float2(0.0);
    info.width = 7.0;
    info.seed = 0.0;
    info.normal = float2(0.0, 1.0);
    info.curvature = 0.0;

    float4 targetRect = float4(target.rect);
    float4 params = float4(target.params);
    float2 origin = targetRect.xy;
    float2 size = targetRect.zw;
    if (size.x <= 0.0 || size.y <= 0.0) {
        return info;
    }

    float seed = params.w;
    if (params.z > 0.5) {
        float radius = min(size.x, size.y) * 0.5;
        float2 center = size * 0.5;
        float slotF = float(min(slot, uint(splashGlassNozzleSlotsPerTarget - 1)));
        float slot01 = splashGlassNozzleSlotsPerTarget > 1
            ? slotF / float(splashGlassNozzleSlotsPerTarget - 1)
            : 0.5;
        float jitter = (splashHash(float2(seed + slotF * 3.17, 9.4)) - 0.5) * 0.10;
        float arc = mix(-0.58, 0.58, slot01) + jitter;
        float2 radial = normalize(float2(sin(arc), cos(arc)));
        float edgeWeight = smoothstep(0.0, 0.20, slot01)
            * (1.0 - smoothstep(0.80, 1.0, slot01));
        float slotEnergy = splashHash(float2(seed + slotF * 5.31, 21.0));
        info.enabled = mix(0.52, 1.0, slotEnergy) * mix(0.82, 1.0, edgeWeight);
        info.width = max(5.5, radius * mix(0.17, 0.32, edgeWeight) * mix(0.74, 1.26, slotEnergy));
        info.sourcePoint = origin + center + radial * radius;
        info.seed = seed + 1.37 + slotF * 0.91;
        info.normal = radial;
        info.curvature = 1.0 / max(radius, 1.0);
        return info;
    }

    float radius = min(params.x, min(size.x, size.y) * 0.5);
    float width = max(7.0, min(size.y * 0.34, size.x * 0.070));
    float slotF = float(min(slot, uint(splashGlassNozzleSlotsPerTarget - 1)));
    float slot01 = splashGlassNozzleSlotsPerTarget > 1
        ? slotF / float(splashGlassNozzleSlotsPerTarget - 1)
        : 0.5;
    float selectedSeed = seed + 3.0 + slotF;
    float jitter = (splashHash(float2(selectedSeed, 16.9)) - 0.5) * 0.032;
    float x = clamp(mix(0.12, 0.88, slot01) + jitter, 0.08, 0.92) * size.x;

    float bottomY = splashRoundedRectBottomY(x, size, radius);
    float2 surfaceLocal = float2(x, bottomY);
    float2 surfaceNormal = splashGlassTargetNormal(surfaceLocal, size, params);
    float curvedPart = radius > 0.001
        ? max(1.0 - smoothstep(radius - 0.75, radius + 0.75, x),
              smoothstep(size.x - radius - 0.75, size.x - radius + 0.75, x))
        : 0.0;
    float slotEnergy = splashHash(float2(selectedSeed, 21.0));
    info.sourcePoint = origin + float2(x, bottomY);
    info.seed = selectedSeed;
    info.normal = surfaceNormal;
    info.curvature = curvedPart / max(radius, 1.0);
    float flatRim = 1.0 - smoothstep(0.001, 0.024, info.curvature);
    float centerBias = 1.0 - abs(slot01 * 2.0 - 1.0);
    info.enabled = mix(0.68, 1.0, slotEnergy) * mix(0.88, 1.0, centerBias) * mix(0.92, 1.08, flatRim);
    info.width = width * mix(0.82, 1.34, slotEnergy) * mix(1.0, 1.18, flatRim);
    return info;
}

// MARK: - Glass Impact Events

// A droplet that hits glass writes a short-lived impact blob into the surface
// simulation; persistent falling drips are produced later from that film.
inline void splashSpawnGlassDroplet(
    Droplet source,
    float2 overlayPosition,
    float2 sourceVelocity,
    float2 impactNormal,
    float seed,
    float radiusScale,
    float2 positionOffset,
    float2 velocityBias,
    float lifetimeScale,
    float opacityScale,
    device GlassDroplet *glassDroplets,
    device atomic_uint *glassCursor,
    uint glassCapacity
) {
    if (glassCapacity == 0) return;

    uint slot = atomic_fetch_add_explicit(glassCursor, 1, memory_order_relaxed);
    if (slot >= glassCapacity) return;

    float sizeSeed = splashHash(float2(seed * 17.0 + 3.0, overlayPosition.x * 0.071));
    float speedSeed = splashHash(float2(seed * 29.0 + 7.0, overlayPosition.y * 0.053));

    GlassDroplet gd;
    gd.position = packed_float2(overlayPosition + positionOffset);
    float2 tangent = normalize(float2(-impactNormal.y, impactNormal.x));
    float tangentSpeed = dot(sourceVelocity, tangent);
    float2 surfaceVelocity = tangent * tangentSpeed * 0.018;
    surfaceVelocity += float2((sizeSeed - 0.5) * 5.0, mix(2.0, 13.0, speedSeed));
    gd.velocity = packed_float2(surfaceVelocity + velocityBias);
    float4 sourceColor = float4(source.color);
    float sourceLuma = dot(sourceColor.rgb, float3(0.299, 0.587, 0.114));
    float3 paintColor = clamp(mix(float3(sourceLuma), sourceColor.rgb, 1.28), 0.0, 1.0);
    gd.color = packed_float4(float4(paintColor, opacityScale));
    float mainDrop = radiusScale >= 0.75 ? 1.0 : 0.0;
    float radiusRoll = pow(sizeSeed, mix(0.82, 1.65, mainDrop));
    float occasionalLarge = smoothstep(0.82, 1.0, sizeSeed) * mainDrop;
    float radiusVariation = mix(0.50, 1.34, radiusRoll) + occasionalLarge * 0.42;
    float minRadius = mix(1.20, 3.8, mainDrop);
    float radiusBoost = mix(0.92, 1.14, mainDrop);
    gd.radius = clamp(source.baseSize * radiusVariation * radiusScale * radiusBoost,
                      minRadius,
                      mix(7.0, 18.0, mainDrop));
    gd.age = 0.0;
    gd.lifetime = max(0.38, mix(2.0, 3.45, speedSeed) * lifetimeScale);
    gd.seed = seed;
    gd.stretch = mix(0.92, 1.22, speedSeed);
    gd.active = 1.0;
    gd.impact = mix(0.55, 1.0, sizeSeed) * saturate(opacityScale + radiusScale * 0.25);
    gd.pad = 0.0;

    glassDroplets[slot] = gd;
}

// MARK: - Compute: Update Droplets

// Flying splash particles either fade out or seed paint mass on matching glass
// targets. Hit probability is delayed per droplet to avoid synchronized impacts.
kernel void splashUpdateDroplet(
    device Droplet *droplets                  [[buffer(0)]],
    const device float  &timeStep             [[buffer(1)]],
    const device uint   &dropletCount         [[buffer(2)]],
    const device float2 &itemOrigin           [[buffer(3)]],
    const device GlassHitTarget *hitTargets   [[buffer(4)]],
    const device uint   &hitTargetCount       [[buffer(5)]],
    device GlassDroplet *glassDroplets        [[buffer(6)]],
    device atomic_uint  *glassCursor          [[buffer(7)]],
    const device uint   &glassCapacity        [[buffer(8)]],
    device atomic_uint  *glassCells           [[buffer(9)]],
    uint gid                                  [[thread_position_in_grid]]
) {
    if (gid >= dropletCount) return;

    Droplet d = droplets[gid];
    uint motionPhase = d.phase & splashPhaseMask;

    if (motionPhase == splashPhaseFlying) {
        float2 vel = float2(d.velocity);
        float2 pos = float2(d.position);
        float2 prevOverlayPosition = itemOrigin + pos;

        vel.y += 800.0 * timeStep;

        float drag = 1.0 - d.dragFactor * timeStep;
        drag = max(drag, 0.0);
        vel *= drag;

        pos += vel * timeStep;

        d.velocity = packed_float2(vel);
        d.position = packed_float2(pos);
        d.flightAge = min(d.flightAge + timeStep, 2.0);

        if ((d.phase & splashPhaseGlassChecked) == 0 && hitTargetCount > 0) {
            float2 overlayPosition = itemOrigin + pos;
            float flightAge = d.flightAge;
            float2 travel = overlayPosition - prevOverlayPosition;
            float travelLen = length(travel);
            float2 travelDir = travelLen > 0.001 ? travel / travelLen : (length(vel) > 0.001 ? normalize(vel) : float2(0.0, 1.0));

            for (uint i = 0; i < hitTargetCount; i++) {
                GlassHitTarget target = hitTargets[i];
                float4 targetRect = float4(target.rect);
                float4 targetParams = float4(target.params);
                float2 origin = targetRect.xy;
                float2 size = targetRect.zw;
                if (size.x <= 0.0 || size.y <= 0.0) continue;

                float2 local = overlayPosition - origin;
                float hitDistance = splashGlassTargetDistance(local, size, targetParams);
                float hitSlop = max(3.0, d.baseSize * 0.62);
                if (hitDistance > hitSlop) continue;

                float insideMask = 1.0 - smoothstep(0.0, hitSlop, max(hitDistance, 0.0));
                float2 impactLocal = splashClampToGlassTarget(local, size, targetParams);
                float2 surfaceNormal = splashGlassTargetNormal(impactLocal, size, targetParams);

                float attempt = floor(flightAge * 52.0 + float(gid) * 0.07);
                float seed = splashHash(float2(
                    float(gid) * 12.9898 + attempt,
                    dot(overlayPosition, float2(0.031, 0.047)) + flightAge * 0.37
                ));
                float speedBias = smoothstep(45.0, 180.0, length(vel));
                float sizeBias = smoothstep(3.8, 13.5, d.baseSize);
                float delaySeed = splashHash(float2(float(gid) * 3.17, d.baseSize * 0.41));
                float gateStart = mix(0.045, 0.26, delaySeed);
                float gateEnd = gateStart + mix(0.16, 0.42, splashHash(float2(delaySeed * 19.0, 4.0)));
                float flightGate = smoothstep(gateStart, gateEnd, flightAge);
                float probability = targetParams.y
                    * sizeBias
                    * mix(0.62, 1.42, speedBias)
                    * insideMask
                    * flightGate
                    * 3.25;
                probability = clamp(probability, 0.0, 0.64);

                if (sizeBias > 0.05 && seed < probability) {
                    float2 impactPoint = origin + impactLocal;
                    float2 spawnPosition = impactPoint;
                    spawnPosition = origin + splashClampToGlassTarget(spawnPosition - origin, size, targetParams);
                    float2 cellUVFromImpact = clamp((spawnPosition - origin) / max(size, float2(1.0)), 0.0, 0.999);
                    uint cellX = min(uint(cellUVFromImpact.x * float(splashGlassCellCols)), splashGlassCellCols - 1);
                    uint cellY = min(uint(cellUVFromImpact.y * float(splashGlassCellRows)), splashGlassCellRows - 1);
                    uint cellIndex = i * splashGlassCellsPerTarget + cellY * splashGlassCellCols + cellX;
                    uint previousHits = atomic_fetch_add_explicit(
                        &glassCells[cellIndex],
                        1,
                        memory_order_relaxed
                    );
                    if (previousHits >= 1) break;

                    float2 spawnJitter = float2(
                        splashHash(float2(seed * 43.0 + 2.0, float(cellIndex))),
                        splashHash(float2(seed * 59.0 + 3.0, float(cellIndex)))
                    ) - 0.5;
                    spawnPosition += spawnJitter * max(d.baseSize * 0.42, 1.8);
                    spawnPosition = origin + splashClampToGlassTarget(spawnPosition - origin, size, targetParams);

                    splashSpawnGlassDroplet(
                        d,
                        spawnPosition,
                        vel,
                        surfaceNormal,
                        seed,
                        1.0,
                        float2(0.0),
                        float2(0.0),
                        1.0,
                        1.0,
                        glassDroplets,
                        glassCursor,
                        glassCapacity
                    );

                    float2 sideAxis = normalize(float2(-travelDir.y, travelDir.x));
                    uint microCount = seed > 0.96 ? 1 : 0;
                    for (uint m = 0; m < microCount; m++) {
                        float mSeed = splashHash(float2(seed * 71.0 + float(m) * 5.31, float(gid) * 0.11));
                        float mSeed2 = splashHash(float2(seed * 97.0 + float(m) * 3.17, float(cellIndex) + 0.41));
                        float sideSign = (mSeed < 0.5) ? -1.0 : 1.0;
                        float2 side = sideAxis * sideSign;
                        float2 offset = side * mix(1.8, 5.8, mSeed2) + float2(0.0, mix(0.8, 3.6, mSeed));
                        float2 microPosition = origin + splashClampToGlassTarget(spawnPosition + offset - origin, size, targetParams);
                        float2 sideKick = side * mix(12.0, 38.0, mSeed2);
                        float2 liftKick = float2(0.0, mix(3.0, 12.0, mSeed));

                        splashSpawnGlassDroplet(
                            d,
                            microPosition,
                            vel,
                            surfaceNormal,
                            splashHash(float2(seed * 113.0, float(m) + 0.29)),
                            mix(0.18, 0.34, mSeed2),
                            float2(0.0),
                            sideKick + liftKick,
                            mix(0.42, 0.70, mSeed),
                            mix(0.34, 0.58, mSeed2),
                            glassDroplets,
                            glassCursor,
                            glassCapacity
                        );
                    }
                    d.position = packed_float2(spawnPosition - itemOrigin);
                    d.velocity = packed_float2(vel * -0.06);
                    d.phase = ((d.phase & ~splashPhaseMask) | splashPhaseFading | splashPhaseGlassChecked);
                    d.lifetime = min(d.lifetime, 0.075);
                }
                break;
            }
        }

        d.lifetime -= timeStep;
        if (d.lifetime <= 0.0) {
            d.phase = (d.phase & ~splashPhaseMask) | splashPhaseFading;
            d.lifetime = 0.15;
        }
    } else {
        d.lifetime -= timeStep;
        if (d.lifetime <= 0.0) {
            d.position = packed_float2(-1000.0, -1000.0);
            d.lifetime = -1.0;
        }
    }

    droplets[gid] = d;
}

// MARK: - Compute: Glass Surface Film

// Texture-space film stores premultiplied paint color in RGB and paint mass in
// A. Velocity advection, surface tension, adhesion, and drying keep it glassy.
kernel void splashSimulateGlassSurface(
    texture2d<float, access::sample> surfaceIn       [[texture(0)]],
    texture2d<float, access::sample> velocityIn      [[texture(1)]],
    texture2d<float, access::sample> impactIn        [[texture(2)]],
    texture2d<float, access::sample> impactVelocity  [[texture(3)]],
    texture2d<float, access::write> surfaceOut       [[texture(4)]],
    texture2d<float, access::write> velocityOut      [[texture(5)]],
    const device float &timeStep                     [[buffer(0)]],
    const device float2 &containerSize               [[buffer(1)]],
    const device GlassHitTarget *hitTargets          [[buffer(2)]],
    const device uint &hitTargetCount                [[buffer(3)]],
    uint2 gid                                        [[thread_position_in_grid]]
) {
    uint width = surfaceOut.get_width();
    uint height = surfaceOut.get_height();
    if (gid.x >= width || gid.y >= height) return;

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float dt = min(max(timeStep, 0.001), 0.05);
    float2 textureSize = float2(float(width), float(height));
    float2 pixel = float2(float(gid.x), float(gid.y));
    float2 uv = (pixel + 0.5) / textureSize;
    float2 texel = 1.0 / textureSize;
    float2 overlayPoint = uv * containerSize;
    GlassSurfaceTargetInfo targetInfo = splashGlassSurfaceTargetInfo(
        overlayPoint,
        hitTargets,
        hitTargetCount
    );
    float targetMask = targetInfo.mask;
    float glassRegion = targetInfo.glassMask;
    float spillRegion = targetInfo.spillMask * (1.0 - glassRegion);
    if (spillRegion > 0.001) {
        surfaceOut.write(float4(0.0), gid);
        velocityOut.write(float4(0.0), gid);
        return;
    }
    if (targetMask <= 0.001 && hitTargetCount > 0) {
        surfaceOut.write(float4(0.0), gid);
        velocityOut.write(float4(0.0), gid);
        return;
    }

    float4 centerState = surfaceIn.sample(linearSampler, uv);
    float2 centerVelocity = velocityIn.sample(linearSampler, uv).xy;
    float centerMass = centerState.a;
    float heavyMass = smoothstep(0.18, 0.66, centerMass);
    float beadMass = smoothstep(0.085, 0.30, centerMass);
    float laneWarp = (splashNoise(float2(pixel.y * 0.018, 8.1)) - 0.5) * 21.0
        + (splashNoise(float2(pixel.y * 0.052, 4.2)) - 0.5) * 6.0;
    float laneNoise = splashNoise(float2((pixel.x + laneWarp) * 0.050, pixel.y * 0.018));
    float laneBreak = splashNoise(float2(pixel.x * 0.017, pixel.y * 0.070));
    float lane = smoothstep(0.70, 0.96, laneNoise + beadMass * 0.10)
        * smoothstep(0.26, 0.78, laneBreak + beadMass * 0.12);
    float laneLeft = splashNoise(float2((pixel.x - 4.0 + laneWarp) * 0.050, pixel.y * 0.018));
    float laneRight = splashNoise(float2((pixel.x + 4.0 + laneWarp) * 0.050, pixel.y * 0.018));
    float laneSlope = laneRight - laneLeft;
    float mobility = smoothstep(0.070, 0.32, centerMass);
    float pinNoise = splashNoise(pixel * 0.173 + float2(3.1, 7.7));
    float adhesion = mix(1.62, 0.60, saturate(centerMass * 1.55 + lane * 0.20))
        * mix(0.82, 1.26, pinNoise);

    float gravityPull = mix(5.0, 46.0, heavyMass) * mobility;
    gravityPull += lane * beadMass * 7.0;
    centerVelocity.y += gravityPull / max(adhesion, 0.25) * dt;
    centerVelocity.x += (splashNoise(pixel * 0.087 + centerMass * 11.0) - 0.5)
        * mobility * dt * mix(4.0, 10.0, lane);
    centerVelocity.x += laneSlope * lane * beadMass * dt * 18.0;
    centerVelocity.x *= 1.0 - min(dt * lane * 3.6, 0.28);

    float damping = mix(6.4, 0.82, saturate(mobility + heavyMass * 0.55));
    damping *= mix(1.12, 0.72, lane);
    centerVelocity *= max(0.0, 1.0 - damping * dt);
    float maxSpeed = mix(12.0, 134.0, saturate(centerMass * 1.45 + heavyMass * 0.42 + lane * 0.10));
    centerVelocity = clamp(centerVelocity, float2(-maxSpeed), float2(maxSpeed));

    float2 backUV = uv - centerVelocity * dt / max(containerSize, float2(1.0));
    float4 advected = surfaceIn.sample(linearSampler, backUV);
    float4 advectedVelocity = velocityIn.sample(linearSampler, backUV);
    float2 velocity = advectedVelocity.xy;

    float4 leftState = surfaceIn.sample(linearSampler, backUV - float2(texel.x, 0.0));
    float4 rightState = surfaceIn.sample(linearSampler, backUV + float2(texel.x, 0.0));
    float4 upState = surfaceIn.sample(linearSampler, backUV - float2(0.0, texel.y));
    float4 downState = surfaceIn.sample(linearSampler, backUV + float2(0.0, texel.y));
    float4 nwState = surfaceIn.sample(linearSampler, backUV - texel);
    float4 neState = surfaceIn.sample(linearSampler, backUV + float2(texel.x, -texel.y));
    float4 swState = surfaceIn.sample(linearSampler, backUV + float2(-texel.x, texel.y));
    float4 seState = surfaceIn.sample(linearSampler, backUV + texel);

    float4 crossAverage = (leftState + rightState + upState + downState) * 0.25;
    float4 diagonalAverage = (nwState + neState + swState + seState) * 0.25;
    float4 verticalAverage = (upState + downState) * 0.5;
    float4 tensionTarget = crossAverage * 0.66 + diagonalAverage * 0.22 + advected * 0.12;
    float neighborhoodMass = max(max(max(leftState.a, rightState.a), max(upState.a, downState.a)),
                                max(max(nwState.a, neState.a), max(swState.a, seState.a)));
    neighborhoodMass = max(neighborhoodMass, advected.a);
    float tensionRegion = glassRegion;
    float wetNeighborhood = smoothstep(0.032, 0.18, neighborhoodMass) * tensionRegion;
    float pathPull = smoothstep(0.045, 0.22, downState.a) * smoothstep(0.035, 0.18, advected.a);
    float rivulet = lane * wetNeighborhood * glassRegion * smoothstep(0.12, 0.38, max(advected.a, downState.a));

    // Weighted diffusion keeps local volume stable while surface tension
    // rounds peaks and fills necks between nearby masses.
    float tension = saturate(dt * mix(1.05, 3.85, saturate(neighborhoodMass * 1.25)) * wetNeighborhood);
    float4 surface = mix(advected, tensionTarget, tension);
    surface = mix(surface, verticalAverage, saturate(dt * 0.10 * rivulet));

    float impactMass = impactIn.sample(linearSampler, uv).a * glassRegion;
    if (impactMass > 0.0001) {
        float4 impactState = impactIn.sample(linearSampler, uv);
        float4 impactVelocityState = impactVelocity.sample(linearSampler, uv);
        float2 incomingVelocity = impactVelocityState.xy / max(impactVelocityState.a, 0.001);
        float previousMass = surface.a;
        surface.rgb += impactState.rgb * 0.88;
        surface.a += impactState.a * 0.88;
        float impulseMass = impactState.a * 0.68;
        velocity = (velocity * previousMass + incomingVelocity * impulseMass) / max(surface.a, 0.001);
        velocity.y += impactState.a * 18.0;
    }

    float2 heightGradient = float2(rightState.a - leftState.a, downState.a - upState.a);
    velocity += heightGradient * (-14.0 * dt * wetNeighborhood);
    velocity.y += (pathPull * 12.0 + rivulet * 7.0 + heavyMass * 16.0) * dt;
    velocity.x *= 1.0 - min(dt * (pathPull + rivulet) * 2.4, 0.30);

    float2 leftVelocity = velocityIn.sample(linearSampler, backUV - float2(texel.x, 0.0)).xy;
    float2 rightVelocity = velocityIn.sample(linearSampler, backUV + float2(texel.x, 0.0)).xy;
    float2 upVelocity = velocityIn.sample(linearSampler, backUV - float2(0.0, texel.y)).xy;
    float2 downVelocity = velocityIn.sample(linearSampler, backUV + float2(0.0, texel.y)).xy;
    float2 averageVelocity = (leftVelocity + rightVelocity + upVelocity + downVelocity) * 0.25;
    velocity = mix(velocity, averageVelocity, saturate(dt * 2.8 * wetNeighborhood));
    velocity = mix(velocity, float2(velocity.x * 0.58, max(velocity.y, downVelocity.y)), saturate(dt * 2.1 * rivulet));
    velocity *= max(0.0, 1.0 - dt * mix(5.1, 0.70, smoothstep(0.04, 0.34, surface.a)));

    float bottomRim = targetInfo.bottomRim;
    float rimRelease = smoothstep(0.38, 0.78, surface.a);
    float rimHold = bottomRim * (1.0 - rimRelease);
    velocity.y *= 1.0 - min(rimHold * dt * 6.4, 0.42);
    velocity.y = mix(velocity.y, max(velocity.y, 52.0 + surface.a * 74.0), bottomRim * rimRelease);
    velocity.x *= 1.0 - min(bottomRim * dt * 5.8, 0.42);

    float thinFilm = 1.0 - smoothstep(0.050, 0.20, surface.a);
    float dryRate = mix(0.038, 0.92, thinFilm);
    dryRate += rivulet * (1.0 - heavyMass) * 0.14;
    dryRate += glassRegion * (1.0 - smoothstep(0.070, 0.24, surface.a)) * 0.44;
    float decay = max(0.0, 1.0 - dryRate * dt);
    surface *= decay;

    surface *= targetMask;
    velocity *= targetMask;

    if (surface.a < 0.018) {
        surface = float4(0.0);
        velocity = float2(0.0);
    } else {
        float colorScale = min(surface.a, 3.2) / max(surface.a, 0.001);
        surface.rgb *= colorScale;
        surface.a = min(surface.a, 3.2);
    }

    surfaceOut.write(surface, gid);
    velocityOut.write(float4(velocity, 0.0, surface.a), gid);
}

// MARK: - Compute: Glass Event Reset

kernel void splashClearGlassEvents(
    device GlassDroplet *glassDroplets [[buffer(0)]],
    device atomic_uint *glassCursor    [[buffer(1)]],
    const device uint &glassCapacity   [[buffer(2)]],
    uint gid                           [[thread_position_in_grid]]
) {
    if (gid == 0) {
        atomic_store_explicit(glassCursor, 0, memory_order_relaxed);
    }
    if (gid >= glassCapacity) return;

    GlassDroplet gd = glassDroplets[gid];
    gd.active = 0.0;
    glassDroplets[gid] = gd;
}

// MARK: - Compute: Glass SPH Drips

// A small persistent SPH pool hangs from glass outlets, merges nearby particles,
// and detaches them when gravity/load overcomes adhesion.
kernel void splashUpdateGlassSPHParticles(
    const device GlassSPHParticle *particlesIn       [[buffer(0)]],
    device GlassSPHParticle *particlesOut            [[buffer(1)]],
    const device float &timeStep                     [[buffer(2)]],
    const device float2 &containerSize               [[buffer(3)]],
    const device GlassHitTarget *hitTargets          [[buffer(4)]],
    const device uint &hitTargetCount                [[buffer(5)]],
    const device uint &particleCapacity              [[buffer(6)]],
    texture2d<float, access::sample> surfaceTex      [[texture(0)]],
    texture2d<float, access::sample> velocityTex     [[texture(1)]],
    uint gid                                         [[thread_position_in_grid]]
) {
    if (gid >= particleCapacity) return;

    GlassSPHParticle p = particlesIn[gid];
    float dt = min(max(timeStep, 0.001), 0.05);
    uint particlesPerTarget = splashGlassNozzleSlotsPerTarget * splashSPHParticlesPerNozzle;
    uint targetIndex = gid / particlesPerTarget;
    uint targetLocal = gid - targetIndex * particlesPerTarget;
    uint nozzleSlot = targetLocal / splashSPHParticlesPerNozzle;
    uint particleSlot = targetLocal - nozzleSlot * splashSPHParticlesPerNozzle;

    if (targetIndex >= hitTargetCount || hitTargetCount == 0) {
        p.active = 0.0;
        p.state = splashSPHStateEmpty;
        p.mass = 0.0;
        p.age = 0.0;
        particlesOut[gid] = p;
        return;
    }

    GlassHitTarget target = hitTargets[targetIndex];
    float4 targetRect = float4(target.rect);
    float4 targetParams = float4(target.params);
    float2 targetOrigin = targetRect.xy;
    float2 targetSize = targetRect.zw;
    GlassNozzleInfo nozzle = splashGlassTargetNozzleInfo(target, nozzleSlot);
    if (nozzle.enabled <= 0.001) {
        p.active = 0.0;
        p.state = splashSPHStateEmpty;
        p.mass = 0.0;
        p.age = 0.0;
        particlesOut[gid] = p;
        return;
    }

    float2 surfaceNormal = nozzle.normal;
    if (length(surfaceNormal) <= 0.001) {
        surfaceNormal = float2(0.0, 1.0);
    }
    surfaceNormal = normalize(surfaceNormal);
    float2 surfaceTangent = float2(-surfaceNormal.y, surfaceNormal.x);

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 texel = 1.0 / float2(surfaceTex.get_width(), surfaceTex.get_height());
    float2 sourceUV = clamp(nozzle.sourcePoint / max(containerSize, float2(1.0)),
                            float2(0.0), float2(1.0));

    // Sample a small stencil just inside the glass rim so outlet feed comes
    // from attached film, not from pixels that already spilled below the glass.
    float flatRimFeed = 1.0 - smoothstep(0.001, 0.024, nozzle.curvature);
    float2 sourceInside = surfaceNormal * texel * mix(1.8, 2.5, flatRimFeed);
    float2 sourceDeep = surfaceNormal * texel * mix(3.1, 5.2, flatRimFeed);
    float2 sourceSide = surfaceTangent * nozzle.width / max(containerSize, float2(1.0))
        * mix(1.0, 2.35, flatRimFeed);
    float4 source0 = surfaceTex.sample(linearSampler, sourceUV - sourceInside);
    float4 sourceL1 = surfaceTex.sample(linearSampler, sourceUV - sourceInside - sourceSide * 0.55);
    float4 sourceR1 = surfaceTex.sample(linearSampler, sourceUV - sourceInside + sourceSide * 0.55);
    float4 sourceL2 = surfaceTex.sample(linearSampler, sourceUV - sourceInside - sourceSide * 1.25);
    float4 sourceR2 = surfaceTex.sample(linearSampler, sourceUV - sourceInside + sourceSide * 1.25);
    float4 sourceD0 = surfaceTex.sample(linearSampler, sourceUV - sourceDeep);
    float4 sourceDL = surfaceTex.sample(linearSampler, sourceUV - sourceDeep - sourceSide * 0.95);
    float4 sourceDR = surfaceTex.sample(linearSampler, sourceUV - sourceDeep + sourceSide * 0.95);
    float4 sourceState = source0 * 0.22
        + (sourceL1 + sourceR1) * 0.14
        + (sourceL2 + sourceR2) * 0.075
        + sourceD0 * 0.17
        + (sourceDL + sourceDR) * 0.09;
    float sourcePeak = max(max(max(source0.a, sourceL1.a), max(sourceR1.a, sourceL2.a)),
                           max(max(sourceR2.a, sourceD0.a), max(sourceDL.a, sourceDR.a)));
    float4 sourceVelocityState = velocityTex.sample(linearSampler, sourceUV - sourceInside) * 0.42
        + velocityTex.sample(linearSampler, sourceUV - sourceInside - sourceSide * 0.55) * 0.18
        + velocityTex.sample(linearSampler, sourceUV - sourceInside + sourceSide * 0.55) * 0.18
        + velocityTex.sample(linearSampler, sourceUV - sourceDeep) * 0.22;

    float capsuleRimFeed = 1.0 - smoothstep(0.45, 0.55, targetParams.z);
    float capsuleReservoirGeometry = capsuleRimFeed * mix(0.62, 1.0, flatRimFeed);
    float4 rimReservoirState = float4(0.0);
    float4 rimReservoirVelocity = float4(0.0);
    float rimReservoirWeight = 0.0;
    float rimReservoirPeak = 0.0;
    float rimReservoirPaintedPeak = 0.0;

    // Capsule bottoms are broad and mostly flat; a shared rim reservoir keeps
    // all slots fed instead of letting one local sample monopolize the drip.
    if (capsuleReservoirGeometry > 0.001) {
        float radius = min(targetParams.x, min(targetSize.x, targetSize.y) * 0.5);
        float nozzle01 = clamp((nozzle.sourcePoint.x - targetOrigin.x) / max(targetSize.x, 1.0), 0.0, 1.0);
        for (uint rimTap = 0; rimTap < 7; rimTap++) {
            float tap01 = mix(0.14, 0.86, (float(rimTap) + 0.5) / 7.0);
            float tapX = tap01 * targetSize.x;
            float tapY = splashRoundedRectBottomY(tapX, targetSize, radius);
            float2 tapLocal = float2(tapX, tapY);
            float2 tapNormal = splashGlassTargetNormal(tapLocal, targetSize, targetParams);
            if (length(tapNormal) <= 0.001) {
                tapNormal = float2(0.0, 1.0);
            }
            tapNormal = normalize(tapNormal);
            float2 tapTangent = float2(-tapNormal.y, tapNormal.x);
            float2 tapUV = clamp((targetOrigin + tapLocal) / max(containerSize, float2(1.0)),
                                 float2(0.0), float2(1.0));
            float2 tapInside = tapNormal * texel * 3.4;
            float2 tapSide = tapTangent * nozzle.width * 0.88 / max(containerSize, float2(1.0));
            float4 tapState = surfaceTex.sample(linearSampler, tapUV - tapInside) * 0.58
                + surfaceTex.sample(linearSampler, tapUV - tapInside - tapSide) * 0.21
                + surfaceTex.sample(linearSampler, tapUV - tapInside + tapSide) * 0.21;
            float4 tapVelocity = velocityTex.sample(linearSampler, tapUV - tapInside);
            float nearSlot = exp(-pow((tap01 - nozzle01) / 0.34, 2.0));
            float tapWeight = mix(0.44, 1.0, nearSlot);
            rimReservoirState += tapState * tapWeight;
            rimReservoirVelocity += tapVelocity * tapWeight;
            rimReservoirWeight += tapWeight;
            rimReservoirPeak = max(rimReservoirPeak, tapState.a);
            rimReservoirPaintedPeak = max(rimReservoirPaintedPeak, splashPaintedSurfaceMask(tapState));
        }
        rimReservoirState /= max(rimReservoirWeight, 0.001);
        rimReservoirVelocity /= max(rimReservoirWeight, 0.001);
    }

    float sampledSourceMass = max(sourceState.a, 0.0);
    float rimReservoirMass = max(max(rimReservoirState.a, 0.0), rimReservoirPeak * 0.58);
    float rimReservoirPainted = max(splashPaintedSurfaceMask(rimReservoirState),
                                    rimReservoirPaintedPeak * smoothstep(0.018, 0.12, rimReservoirPeak));
    float rimReservoirWet = capsuleReservoirGeometry
        * smoothstep(0.014, 0.12, rimReservoirMass)
        * rimReservoirPainted;
    float reservoirBlend = rimReservoirWet * (1.0 - smoothstep(0.055, 0.22, sampledSourceMass));
    sourceState = mix(sourceState, rimReservoirState, reservoirBlend * 0.82);
    sourceVelocityState = mix(sourceVelocityState, rimReservoirVelocity, reservoirBlend * 0.58);

    sampledSourceMass = max(sourceState.a, 0.0);
    float feedMass = mix(sampledSourceMass, max(sampledSourceMass, sourcePeak * 0.76), flatRimFeed);
    feedMass = max(feedMass, rimReservoirMass * rimReservoirWet * 1.05);
    float sourceMass = max(sampledSourceMass, feedMass * flatRimFeed * 0.68);
    float paintedSource = max(splashPaintedSurfaceMask(sourceState), rimReservoirWet);
    float localFeed = smoothstep(mix(0.075, 0.042, flatRimFeed),
                                 mix(0.46, 0.32, flatRimFeed),
                                 feedMass) * paintedSource * nozzle.enabled;
    float reservoirSlotGain = mix(0.72, 1.18, splashHash(float2(nozzle.seed, 91.0)));
    float reservoirFeed = smoothstep(0.014, 0.13, rimReservoirMass)
        * rimReservoirWet
        * nozzle.enabled
        * reservoirSlotGain;
    float feed = saturate(max(localFeed, reservoirFeed) * mix(1.0, 1.18, capsuleRimFeed));
    float3 sourceColor = clamp(sourceState.rgb / max(sampledSourceMass, 0.001), 0.0, 1.0);
    float2 sourceVelocity = sourceVelocityState.xy;

    float seed = nozzle.seed + float(gid) * 0.173 + float(particleSlot) * 0.619;
    float nozzleProfile = splashHash(float2(nozzle.seed, 41.0));

    // Profiles make outlets behave differently: sticky beads, thin strands,
    // heavier drops, or faster releases, all deterministic per source.
    float stickyProfile = 1.0 - smoothstep(0.18, 0.46, nozzleProfile);
    float thinProfile = smoothstep(0.18, 0.48, nozzleProfile)
        * (1.0 - smoothstep(0.52, 0.78, nozzleProfile));
    float heavyProfile = smoothstep(0.62, 0.96, nozzleProfile);
    float fastProfile = smoothstep(0.36, 0.66, splashHash(float2(nozzle.seed, 73.0)))
        * (1.0 - heavyProfile * 0.45);
    float slot01 = splashSPHParticlesPerNozzle > 1
        ? float(particleSlot) / float(splashSPHParticlesPerNozzle - 1)
        : 0.0;
    float particleJitter = splashHash(float2(seed, 13.7));
    float lane = (fract(slot01 * 3.999 + particleJitter * 0.37) - 0.5) * 2.0;
    float rowBase = floor(slot01 * 3.999) / 3.0;
    float row = clamp(mix(rowBase, particleJitter, 0.32 + thinProfile * 0.22), 0.0, 1.0);
    float contactParticle = particleSlot < 3 ? 1.0 : 0.0;

    if (p.active < 0.5 || p.state < 0.5) {
        p.age += dt;
        p.pad += dt;
        p.seed = seed;
        p.state = splashSPHStateEmpty;
        p.active = 0.0;

        float attempt = floor(p.pad * mix(14.0, 24.0, feed) + seed * 2.7);
        float spawnRoll = splashHash(float2(seed * 11.0 + attempt, float(gid) * 0.071));
        float feedProfile = mix(0.72, 1.42, heavyProfile)
            * mix(1.0, 1.34, thinProfile)
            * mix(1.0, 0.78, stickyProfile);
        float spawnRate = feed * dt * mix(6.0, 18.5, row) * mix(1.35, 0.70, contactParticle) * feedProfile;
        if (feed <= 0.030 || spawnRoll > min(spawnRate, 0.48)) {
            particlesOut[gid] = p;
            return;
        }

        // Empty slots spawn in staggered lanes around the same outlet, giving a
        // single source several organic strands without increasing CPU work.
        float seedA = splashHash(float2(seed, 19.0 + attempt));
        float seedB = splashHash(float2(seed, 31.0 + attempt));
        float laneWidth = nozzle.width * mix(0.12, 0.74, seedA) * mix(0.72, 1.34, thinProfile);
        laneWidth *= mix(1.0, 1.45, capsuleRimFeed);
        float outletWander = (splashHash(float2(nozzle.seed + attempt * 0.173, seedA * 11.0)) - 0.5)
            * targetSize.x
            * 0.026
            * capsuleRimFeed;
        float lateral = lane * laneWidth
            + (splashHash(float2(seed, attempt + 47.0)) - 0.5) * nozzle.width * mix(0.22, 0.46, capsuleRimFeed)
            + outletWander;
        float normalOffset = mix(0.55, 3.2, row) + seedB * 1.4;
        float2 anchor = nozzle.sourcePoint + surfaceTangent * lateral;
        p.anchor = packed_float2(anchor);
        p.position = packed_float2(anchor + surfaceNormal * normalOffset);
        p.velocity = packed_float2(
            sourceVelocity * mix(0.030, 0.105, row)
            + surfaceTangent * (seedA - 0.5) * mix(2.0, 26.0, row) * mix(0.62, 1.35, thinProfile)
            + surfaceNormal * mix(2.0, 24.0, seedB) * mix(0.48, 1.15, row) * mix(0.82, 1.20, fastProfile)
        );
        p.color = packed_float4(float4(sourceColor, 1.0));
        p.mass = mix(0.052, 0.21, seedB)
            * mix(0.46, 1.36, row)
            * max(feed, 0.28)
            * mix(0.74, 1.44, heavyProfile)
            * mix(1.0, 0.62, thinProfile);
        p.radius = mix(1.35, 5.2, seedA)
            * mix(0.60, 1.34, row)
            * mix(0.72, 1.28, heavyProfile)
            * mix(1.0, 0.64, thinProfile);
        p.density = p.mass;
        p.pressure = 0.0;
        p.age = 0.0;
        p.lifetime = mix(0.86, 1.95, seedB) * mix(0.78, 1.28, heavyProfile) * mix(1.0, 0.72, fastProfile);
        p.active = 1.0;
        p.anchorStrength = mix(6.8, 0.92, row)
            * mix(1.32, 0.68, contactParticle)
            * mix(0.64, 1.62, stickyProfile)
            * mix(1.0, 0.68, fastProfile);
        p.state = splashSPHStateAttached;
        p.pad = 0.0;
        p.surfaceNormal = packed_float2(surfaceNormal);
        p.surfaceCurvature = nozzle.curvature;
        p.profile = nozzleProfile;
        particlesOut[gid] = p;
        return;
    }

    float2 pos = float2(p.position);
    float2 vel = float2(p.velocity);
    float3 color = clamp(float4(p.color).rgb, 0.0, 1.0);
    bool attached = p.state < 1.5;
    float2 particleNormal = float2(p.surfaceNormal);
    if (length(particleNormal) <= 0.001) {
        particleNormal = surfaceNormal;
    }
    particleNormal = normalize(particleNormal);
    float2 particleTangent = float2(-particleNormal.y, particleNormal.x);
    float profile = p.profile;
    float pSticky = 1.0 - smoothstep(0.18, 0.46, profile);
    float pThin = smoothstep(0.18, 0.48, profile) * (1.0 - smoothstep(0.52, 0.78, profile));
    float pHeavy = smoothstep(0.62, 0.96, profile);
    float pFast = smoothstep(0.36, 0.66, splashHash(float2(nozzle.seed, 73.0))) * (1.0 - pHeavy * 0.45);

    // Compact O(n^2) SPH is acceptable here because the pool is tiny and only
    // exists while paint splash/glass overlays are active.
    float density = p.mass * 0.86;
    float support = max(9.5, p.radius * 3.8);
    for (uint i = 0; i < particleCapacity; i++) {
        GlassSPHParticle q = particlesIn[i];
        if (q.active < 0.5) continue;

        float2 delta = pos - float2(q.position);
        float dist = length(delta);
        float h = max(support, (p.radius + q.radius) * 2.55);
        if (dist >= h) continue;

        float x = 1.0 - dist / max(h, 0.001);
        float w = x * x * x;
        density += q.mass * w * 1.48;
    }

    float restDensity = mix(0.22, 0.48, saturate(p.mass * 2.4));
    float pressure = max(density - restDensity, 0.0) * 92.0;
    float2 accel = float2(0.0, mix(520.0, 330.0, saturate(p.anchorStrength / 6.0)))
        * mix(1.0, 1.16, pHeavy)
        * mix(1.0, 0.88, pSticky);

    for (uint i = 0; i < particleCapacity; i++) {
        if (i == gid) continue;
        GlassSPHParticle q = particlesIn[i];
        if (q.active < 0.5) continue;

        float2 qPos = float2(q.position);
        float2 delta = pos - qPos;
        float dist = length(delta);
        float h = max(10.5, (p.radius + q.radius) * 2.75);
        if (dist <= 0.001 || dist >= h) continue;

        float2 dir = delta / dist;
        float x = 1.0 - dist / h;
        float w = x * x;
        float qPressure = max(q.pressure, max(q.density - restDensity, 0.0) * 82.0);
        float pressureTerm = (pressure + qPressure) * 0.018 * w;
        float cohesionTerm = mix(20.0, 7.0, saturate(dist / h)) * w;
        float2 visc = (float2(q.velocity) - vel) * (2.6 * w);

        accel += dir * pressureTerm;
        accel -= dir * cohesionTerm;
        accel += visc;
    }

    if (attached) {
        // Attached particles are tethered to the captured glass normal/curvature
        // until accumulated mass, age, and velocity exceed their release budget.
        float2 anchor = float2(p.anchor);
        float2 toAnchor = anchor - pos;
        float anchorDistance = length(toAnchor);
        float contactWidth = max(nozzle.width * mix(0.45, 0.88, pThin), 4.8);
        float contactFalloff = exp(-anchorDistance * anchorDistance / max(contactWidth * contactWidth, 0.001));
        float adhesion = p.anchorStrength
            * mix(0.54, 1.30, feed)
            * mix(0.70, 1.62, pSticky)
            * mix(1.0, 0.76, pFast)
            * (0.31 + contactFalloff);
        accel += toAnchor * adhesion * 6.4;
        accel += sourceVelocity * feed * 0.20;
        accel += particleTangent * dot(float2(0.0, 1.0), particleTangent) * mix(18.0, 54.0, pThin + pHeavy * 0.45);

        float tangentVelocity = dot(vel, particleTangent);
        vel -= particleTangent * tangentVelocity * min(dt * adhesion * mix(0.20, 0.50, pSticky), 0.34);
        vel *= max(0.0, 1.0 - dt * mix(0.52, 3.6, contactFalloff) * mix(0.82, 1.30, pSticky));

        float rimXForSurface = dot(pos - anchor, particleTangent);
        float surfaceCurve = -min(0.5 * max(p.surfaceCurvature, 0.0) * rimXForSurface * rimXForSurface,
                                  max(p.radius * 1.20, 1.0));
        float signedSurface = dot(pos - anchor, particleNormal) - surfaceCurve;
        if (signedSurface < 0.0) {
            pos -= particleNormal * signedSurface;
            float vn = dot(vel, particleNormal);
            if (vn < 0.0) {
                vel -= particleNormal * vn;
            }
        }

        color = mix(color, sourceColor, saturate(feed * dt * 4.0));
        float feedGain = feed * dt * mix(0.016, 0.104, row) * (0.45 + sourceMass)
            * mix(0.62, 1.46, pHeavy)
            * mix(1.0, 0.58, pSticky)
            * mix(1.0, 0.72, pThin);
        p.mass = min(0.82, p.mass + feedGain);
        float desiredRadius = mix(1.55, 6.8, saturate(p.mass * 1.55))
            * mix(0.64, 1.34, row)
            * mix(0.78, 1.24, pHeavy)
            * mix(1.0, 0.66, pThin);
        p.radius = mix(p.radius, desiredRadius, saturate(dt * 3.8));

        float load = anchorDistance * 0.018
            + p.mass * mix(0.18, 1.62, row) * mix(0.72, 1.46, pHeavy)
            + max(vel.y, 0.0) * 0.0012;
        float release = mix(0.52, 1.18, contactParticle)
            + feed * mix(0.16, 0.36, pSticky)
            + p.anchorStrength * mix(0.026, 0.050, pSticky)
            + pHeavy * 0.18
            - pFast * 0.22
            - pThin * 0.10;
        float releaseAge = mix(0.16, 0.38, pSticky) * mix(1.0, 0.70, pFast);
        if (particleSlot >= 3 && p.age > releaseAge && load > release) {
            p.state = splashSPHStateDetached;
            p.anchorStrength = 0.0;
            p.lifetime = mix(1.05, 1.65, splashHash(float2(seed, p.age + 5.1)));
            vel += particleNormal * mix(12.0, 58.0, saturate(load - release));
        }
    } else {
        p.mass *= max(0.0, 1.0 - dt * mix(0.052, 0.102, pThin + pFast * 0.5));
        p.radius *= max(0.0, 1.0 - dt * mix(0.022, 0.045, pThin));
    }

    vel += accel * dt;
    vel *= max(0.0, 1.0 - dt * mix(0.42, 1.35, saturate(density)));
    vel = clamp(vel, float2(-210.0), float2(280.0, 520.0));
    pos += vel * dt;

    p.age += dt;
    if (!attached) {
        p.lifetime -= dt;
    }

    float kill = 0.0;
    kill = max(kill, pos.y - containerSize.y - 42.0);
    kill = max(kill, 0.018 - p.mass);
    kill = max(kill, -p.lifetime);
    if (kill > 0.0) {
        p.active = 0.0;
        p.state = splashSPHStateEmpty;
        p.mass = 0.0;
        p.age = 0.0;
        p.pad = 0.0;
        particlesOut[gid] = p;
        return;
    }

    p.position = packed_float2(pos);
    p.velocity = packed_float2(vel);
    p.color = packed_float4(float4(color, 1.0));
    p.density = density;
    p.pressure = pressure;
    particlesOut[gid] = p;
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

constant float blobScale = 2.5;

// MARK: - Vertex Shader

// Expands each droplet into a rotated screen-space sprite that pass 1 can turn
// into an energy field for metaball compositing.
vertex VertexOut splashVertex(
    const device float2   &containerSize [[buffer(0)]],
    const device float2   &itemOrigin    [[buffer(1)]],
    const device float2   &itemSize      [[buffer(2)]],
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

    float w = d.baseSize * blobScale;
    float h = d.baseSize * blobScale;

    float cosR = cos(d.rotation);
    float sinR = sin(d.rotation);

    float2 local = (quadVertex - 0.5) * float2(w, h);
    float2 rotated = float2(
        local.x * cosR - local.y * sinR,
        local.x * sinR + local.y * cosR
    );

    float2 screenPos = itemOrigin + float2(d.position) + rotated;

    float ndcX = screenPos.x / containerSize.x * 2.0 - 1.0;
    float ndcY = 1.0 - screenPos.y / containerSize.y * 2.0;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);

    out.color = float4(d.color);

    out.srcUV = float2(d.srcUV);
    out.patchExtent = float2(w, h) / itemSize;

    if ((d.phase & splashPhaseMask) == splashPhaseFading) {
        out.alpha = max(0.0, d.lifetime / 0.15);
    } else {
        out.alpha = 1.0;
    }

    return out;
}

// MARK: - Pass 1: Blob Accumulation

// Accumulates soft droplet energy and premultiplied color; overlapping sprites
// become one liquid blob in the composite pass.
fragment half4 splashBlobFragment(VertexOut in [[stage_in]]) {
    float2 centered = in.uv - 0.5;
    float dist2 = dot(centered, centered) * 4.0;

    float energy = exp(-dist2 * 5.0);
    if (energy < 0.001) discard_fragment();

    half e = half(energy * in.alpha * in.color.a);
    return half4(half3(in.color.rgb) * e, e);
}

// MARK: - Fullscreen Composite Geometry

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

// MARK: - Pass 1b: Glass Impact Surface

// Converts impact events into surface/velocity textures used by the glass film
// simulation; this is separate from persistent SPH drips.
struct GlassDropletVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 velocity;
    float age;
    float lifetime;
    float seed;
    float stretch;
    float impact;
};

vertex GlassDropletVertexOut splashGlassDropletVertex(
    const device float2 &containerSize [[buffer(0)]],
    const device GlassDroplet *glassDroplets [[buffer(1)]],
    unsigned int vid [[vertex_id]],
    unsigned int iid [[instance_id]]
) {
    GlassDropletVertexOut out;
    GlassDroplet gd = glassDroplets[iid];

    if (gd.active < 0.5) {
        out.position = float4(-10.0, -10.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.color = float4(0.0);
        out.velocity = float2(0.0);
        out.age = 0.0;
        out.lifetime = 1.0;
        out.seed = 0.0;
        out.stretch = 1.0;
        out.impact = 0.0;
        return out;
    }

    float2 q = quadVertices[vid];
    float radius = gd.radius;
    float2 velocity = float2(gd.velocity);
    float speedStretch = saturate(length(velocity) / 180.0);
    float stretch = clamp(gd.stretch + speedStretch * 0.45, 1.0, 2.2);
    float width = radius * (3.55 + gd.impact * 0.35);
    float height = radius * (3.45 + stretch * 0.78);
    float2 local = (q - 0.5) * float2(width, height);

    float lean = clamp(velocity.x / 160.0, -0.18, 0.18);
    local.x += local.y * lean;
    local.y += height * 0.035;

    float2 screenPos = float2(gd.position) + local;
    float ndcX = screenPos.x / containerSize.x * 2.0 - 1.0;
    float ndcY = 1.0 - screenPos.y / containerSize.y * 2.0;

    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.uv = q;
    out.color = float4(gd.color);
    out.velocity = velocity;
    out.age = gd.age;
    out.lifetime = gd.lifetime;
    out.seed = gd.seed;
    out.stretch = stretch;
    out.impact = gd.impact;
    return out;
}

inline float splashCapsuleDistance(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 0.0001));
    return length(pa - ba * h) - r;
}

inline float splashSegmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 0.0001));
    return length(pa - ba * h);
}

struct GlassImpactFragmentOut {
    half4 surface [[color(0)]];
    half4 velocity [[color(1)]];
};

fragment GlassImpactFragmentOut splashGlassDropletFragment(GlassDropletVertexOut in [[stage_in]]) {
    float2 p = in.uv;
    float2 center = float2(0.5);
    float wobble = (splashNoise(float2(in.seed * 21.0, 2.7)) - 0.5) * 0.030;
    center.x += wobble;

    float edgeFade = smoothstep(0.018, 0.070, p.y)
        * (1.0 - smoothstep(0.925, 0.995, p.y))
        * smoothstep(0.018, 0.070, p.x)
        * (1.0 - smoothstep(0.925, 0.995, p.x));

    float2 velocity = in.velocity;
    float2 fallDirection = normalize(float2(velocity.x * 0.18, max(abs(velocity.y), 24.0)));
    float stretch01 = saturate((in.stretch - 1.0) / 1.2);
    float2 coreP = (p - center) * float2(1.0 + stretch01 * 0.10, 1.05 - stretch01 * 0.10);
    float core = exp(-dot(coreP, coreP) * mix(12.5, 8.7, stretch01));

    float2 smearStart = center + fallDirection * 0.035;
    float2 smearEnd = center + fallDirection * mix(0.115, 0.190, stretch01);
    float smearDistance = splashCapsuleDistance(p, smearStart, smearEnd, mix(0.060, 0.088, in.impact));
    float smear = (1.0 - smoothstep(0.0, 0.095, smearDistance)) * mix(0.22, 0.40, stretch01);

    float crownNoise = splashNoise((p + in.seed) * 34.0) * 0.035;
    float field = max(core, smear) + crownNoise * smoothstep(0.18, 0.58, core);
    field = smoothstep(0.120, 0.82, field) * edgeFade;
    if (field <= 0.012) discard_fragment();

    float impactScale = mix(0.48, 0.88, saturate(in.impact));
    float mass = field * in.color.a * impactScale;
    float3 paintColor = clamp(in.color.rgb, 0.0, 1.0);
    float2 initialVelocity = float2(velocity.x * 0.52, max(velocity.y, 8.0) * 0.42 + 24.0 * in.impact);

    GlassImpactFragmentOut out;
    out.surface = half4(half3(paintColor * mass), half(mass));
    out.velocity = half4(
        half(initialVelocity.x * mass),
        half(initialVelocity.y * mass),
        half(0.0),
        half(mass)
    );
    return out;
}

// MARK: - Pass 1c: Glass SPH Metaballs

struct GlassSPHParticleVertexOut {
    float4 position [[position]];
    float2 uv;
    float2 overlayPoint;
    float2 center;
    float2 anchor;
    float4 color;
    float2 velocity;
    float radius;
    float mass;
    float state;
    float age;
    float anchorStrength;
    float2 surfaceNormal;
    float surfaceCurvature;
    float profile;
};

vertex GlassSPHParticleVertexOut splashGlassSPHParticleVertex(
    const device float2 &containerSize [[buffer(0)]],
    const device GlassSPHParticle *particles [[buffer(1)]],
    const device float &visibleFade [[buffer(2)]],
    unsigned int vid [[vertex_id]],
    unsigned int iid [[instance_id]]
) {
    GlassSPHParticleVertexOut out;
    GlassSPHParticle p = particles[iid];
    out.uv = float2(0.0);
    out.color = float4(p.color);
    out.velocity = float2(p.velocity);
    out.radius = p.radius;
    out.mass = p.mass;
    out.state = p.state;
    out.age = p.age;
    out.anchorStrength = p.anchorStrength;
    out.surfaceNormal = float2(p.surfaceNormal);
    out.surfaceCurvature = p.surfaceCurvature;
    out.profile = p.profile;

    if (p.active < 0.5 || p.mass <= 0.012 || visibleFade <= 0.010) {
        out.position = float4(-10.0, -10.0, 0.0, 1.0);
        return out;
    }

    float2 q = quadVertices[vid];
    float2 center = float2(p.position);
    float2 anchor = float2(p.anchor);
    float radius = max(p.radius, 1.0);
    bool attached = p.state < 1.5;
    float contact = attached ? saturate(p.anchorStrength / 6.0) : 0.0;
    float fallStretch = attached ? 0.0 : saturate(max(float2(p.velocity).y, 0.0) / 520.0);
    float2 minPoint = attached ? min(anchor, center) : center;
    float2 maxPoint = attached ? max(anchor, center) : center;
    float tetherLen = length(center - anchor);
    float padX = radius * mix(3.4, 4.8, contact) + min(tetherLen * 0.20, radius * 2.4) + 5.0;
    float padTop = radius * mix(2.2, 1.6, contact) + 4.0;
    float padBottom = radius * (3.2 + fallStretch * 2.0) + 7.0;
    float2 minCorner = float2(minPoint.x - padX, minPoint.y - padTop);
    float2 maxCorner = float2(maxPoint.x + padX, maxPoint.y + padBottom);
    float2 screenPos = mix(minCorner, maxCorner, q);
    float ndcX = screenPos.x / containerSize.x * 2.0 - 1.0;
    float ndcY = 1.0 - screenPos.y / containerSize.y * 2.0;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.uv = q;
    out.overlayPoint = screenPos;
    out.center = center;
    out.anchor = anchor;
    return out;
}

fragment half4 splashGlassSPHParticleFragment(
    GlassSPHParticleVertexOut in [[stage_in]],
    const device float &visibleFade [[buffer(0)]]
) {
    float alphaBase = visibleFade * smoothstep(0.012, 0.12, in.mass);
    if (alphaBase <= 0.010) discard_fragment();

    float2 p = in.overlayPoint;
    float2 center = in.center;
    float2 anchor = in.anchor;
    float contact = in.state < 1.5 ? saturate(in.anchorStrength / 6.0) : 0.0;
    bool attached = in.state < 1.5;
    float fallStretch = in.state < 1.5 ? 0.0 : saturate(max(in.velocity.y, 0.0) / 520.0);
    float radius = max(in.radius, 0.001);
    float2 surfaceNormal = in.surfaceNormal;
    if (length(surfaceNormal) <= 0.001) {
        surfaceNormal = float2(0.0, 1.0);
    }
    surfaceNormal = normalize(surfaceNormal);
    float2 surfaceTangent = float2(-surfaceNormal.y, surfaceNormal.x);
    float profile = in.profile;
    float sticky = 1.0 - smoothstep(0.18, 0.46, profile);
    float thin = smoothstep(0.18, 0.48, profile) * (1.0 - smoothstep(0.52, 0.78, profile));
    float heavy = smoothstep(0.62, 0.96, profile);
    float2 tether = center - anchor;
    float tetherLen = length(tether);
    float2 axis = tetherLen > 0.40 ? tether / tetherLen : float2(0.0, 1.0);
    if (!attached && length(in.velocity) > 4.0) {
        axis = normalize(float2(in.velocity.x * 0.20, max(abs(in.velocity.y), 24.0)));
    }
    float2 side = float2(-axis.y, axis.x);

    float2 relCenter = p - center;
    float bodyX = dot(relCenter, side) + dot(relCenter, axis) * clamp(in.velocity.x / 260.0, -0.16, 0.16);
    float bodyY = dot(relCenter, axis);
    float pearY = bodyY / radius;
    float shoulder = smoothstep(-1.05, -0.18, pearY);
    float belly = exp(-pow((pearY - 0.18) / 0.72, 2.0));
    float bodyRx = radius * (0.55 + shoulder * 0.32 + belly * 0.18)
        * mix(1.0, 0.78, fallStretch)
        * mix(0.62, 1.18, heavy)
        * mix(1.0, 0.68, thin);
    float bodyRy = radius * (1.02 + fallStretch * 0.72)
        * mix(0.82, 1.26, heavy)
        * mix(1.16, 0.84, sticky);
    float2 bodyP = float2(bodyX / max(bodyRx, 0.001), bodyY / max(bodyRy, 0.001));
    float bodyDensity = exp(-dot(bodyP, bodyP) * 1.62);

    // Attached drips render as a pear body plus neck and meniscus, so they read
    // as liquid stuck to the glass instead of ellipses floating below it.
    float neckDensity = 0.0;
    float meniscusDensity = 0.0;
    if (attached) {
        float2 pa = p - anchor;
        float h = saturate(dot(pa, tether) / max(dot(tether, tether), 0.0001));
        float2 segmentPoint = anchor + tether * h;
        float segmentDistance = length(p - segmentPoint);
        float neckRadius = radius * mix(0.68, 0.22, smoothstep(0.22, 0.86, tetherLen / max(radius * 4.0, 0.001)));
        neckRadius *= mix(1.10, 0.74, contact)
            * mix(0.55, 1.18, sticky)
            * mix(0.62, 1.0, thin);
        float neckCore = exp(-pow(segmentDistance / max(neckRadius, 0.001), 2.0) * 1.16);
        float neckTaper = mix(0.98, mix(0.20, 0.48, sticky), smoothstep(0.18, 0.92, h));
        neckDensity = neckCore * neckTaper * smoothstep(0.05, 0.36, tetherLen / max(radius, 0.001));

        float2 relAnchor = p - anchor;
        float rimX = dot(relAnchor, surfaceTangent);
        float rimY = dot(relAnchor, surfaceNormal);
        float surfaceCurve = -min(0.5 * max(in.surfaceCurvature, 0.0) * rimX * rimX,
                                  max(radius * 1.35, 1.0));
        float surfaceY = rimY - surfaceCurve;
        float filmWidth = radius * mix(1.36, 3.20, contact) * mix(0.64, 1.42, thin + sticky * 0.35);
        float filmDepth = radius * mix(0.18, 0.58, contact) * mix(0.72, 1.34, sticky + heavy * 0.30);
        float film = exp(-pow(rimX / max(filmWidth, 0.001), 2.0) * 0.92)
            * exp(-pow(max(surfaceY, 0.0) / max(filmDepth, 0.001), 2.0) * 1.18)
            * smoothstep(-0.9, 0.75, surfaceY);
        float rootBead = exp(-(
            pow(rimX / max(filmWidth * 0.42, 0.001), 2.0)
            + pow((max(surfaceY, 0.0) - filmDepth * 0.48) / max(filmDepth * 0.78, 0.001), 2.0)
        ) * 1.10);
        meniscusDensity = film * mix(0.34, 0.92, contact) * mix(0.78, 1.30, sticky + thin * 0.25)
            + rootBead * mix(0.12, 0.36, contact) * mix(0.80, 1.26, heavy + sticky * 0.35);
    }

    float density = max(bodyDensity, max(neckDensity * 0.86, meniscusDensity));
    density += neckDensity * 0.28 + meniscusDensity * 0.22;

    float edgeNoise = splashNoise(float2(in.age * 7.0 + in.mass * 11.0,
                                         dot(p, float2(0.041, 0.057))));
    density *= 0.96 + edgeNoise * 0.070;
    if (density <= 0.006) discard_fragment();

    float energy = density * in.mass * mix(2.0, 2.65, contact) * alphaBase;
    float3 color = clamp(in.color.rgb, 0.0, 1.0);
    return half4(half3(color * energy), half(energy));
}

fragment half4 splashSPHCompositeFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> blobTex [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, filter::linear);
    float4 blob = blobTex.sample(s, in.uv);
    float energy = blob.a;
    if (energy < 0.035) discard_fragment();

    float2 pixelCoord = in.uv * float2(blobTex.get_width(), blobTex.get_height());
    float n = splashNoise(pixelCoord * 0.045) * 0.040
            + splashNoise(pixelCoord * 0.125) * 0.030;

    float threshold = 0.18;
    float edge = smoothstep(threshold - 0.045 + n, threshold + 0.035 + n, energy);
    if (edge < 0.010) discard_fragment();

    // Resolve accumulated SPH energy into liquid color/alpha with a pseudo
    // normal highlight; the particle pass stays additive and cheap.
    float3 baseColor = clamp(blob.rgb / max(energy, 0.001), 0.0, 1.0);
    float2 texelSize = 1.0 / float2(blobTex.get_width(), blobTex.get_height());
    float eL = blobTex.sample(s, in.uv + float2(-texelSize.x, 0.0)).a;
    float eR = blobTex.sample(s, in.uv + float2( texelSize.x, 0.0)).a;
    float eU = blobTex.sample(s, in.uv + float2(0.0, -texelSize.y)).a;
    float eD = blobTex.sample(s, in.uv + float2(0.0,  texelSize.y)).a;

    float3 normal = normalize(float3((eL - eR) * 2.4, (eU - eD) * 2.7, 0.18));
    float3 lightDir = normalize(float3(-0.28, -0.58, 1.0));
    float diffuse = max(dot(normal, lightDir), 0.0) * 0.18 + 0.82;
    float3 halfVec = normalize(lightDir + float3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(normal, halfVec), 0.0), 42.0)
        * smoothstep(threshold, threshold + 0.34, energy);

    float depth = smoothstep(threshold, threshold + 0.45, energy);
    float alpha = edge * (0.54 + depth * 0.44);
    float3 color = baseColor * diffuse * (0.88 + depth * 0.18)
        + mix(float3(0.94, 0.98, 1.0), baseColor, 0.24) * spec * 0.36;

    return half4(half3(clamp(color, 0.0, 1.0)), half(alpha));
}

// MARK: - Pass 2: Metaball Composite

// Thresholds the splash energy field into liquid color/alpha and reconstructs a
// cheap pseudo-normal for specular volume.
fragment half4 splashCompositeFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> blobTex [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, filter::linear);
    float4 blob = blobTex.sample(s, in.uv);

    float energy = blob.a;
    if (energy < 0.05) discard_fragment();

    float2 pixelCoord = in.uv * float2(blobTex.get_width(), blobTex.get_height());
    float n = splashNoise(pixelCoord * 0.04) * 0.06
            + splashNoise(pixelCoord * 0.12) * 0.04;

    float threshold = 0.4;
    float edge = smoothstep(threshold - 0.06 + n, threshold + 0.02 + n, energy);
    if (edge < 0.01) discard_fragment();

    float3 baseColor = blob.rgb / max(energy, 0.001);

    float2 texelSize = 1.0 / float2(blobTex.get_width(), blobTex.get_height());
    float eL = blobTex.sample(s, in.uv + float2(-texelSize.x, 0.0)).a;
    float eR = blobTex.sample(s, in.uv + float2( texelSize.x, 0.0)).a;
    float eU = blobTex.sample(s, in.uv + float2(0.0, -texelSize.y)).a;
    float eD = blobTex.sample(s, in.uv + float2(0.0,  texelSize.y)).a;

    float3 normal = normalize(float3((eL - eR) * 2.0, (eU - eD) * 2.0, 0.15));

    float3 lightDir = normalize(float3(0.3, -0.5, 1.0));
    float diffuse = max(dot(normal, lightDir), 0.0) * 0.2 + 0.8;
    float3 halfVec = normalize(lightDir + float3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(normal, halfVec), 0.0), 32.0);

    float3 finalColor = baseColor * diffuse + spec * 0.3;

    float depth = smoothstep(threshold, threshold + 0.3, energy);
    finalColor *= 0.88 + 0.12 * depth;

    float alphaFromEnergy = smoothstep(threshold, threshold + 0.4, energy);
    float alphaNoise = splashNoise(pixelCoord * 0.06) * 0.15;
    float finalAlpha = edge * (0.65 + 0.35 * alphaFromEnergy + alphaNoise);

    return half4(half3(finalColor), half(finalAlpha));
}
