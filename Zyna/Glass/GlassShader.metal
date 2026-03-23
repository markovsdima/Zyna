//
//  GlassShader.metal
//  Zyna
//
//  Created by Dmitry Markovskiy on 22.03.2026.
//
//  Apple-style liquid glass effect — multi-shape support.
//  Supports up to 3 shapes: rounded rect + circles.
//  Per-shape normals via ownership detection.
//

#include <metal_stdlib>
using namespace metal;

// ─── Types ───────────────────────────────────────────────────────────

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlassUniforms {
    float2 resolution;      // drawable size in pixels
    float isHDR;            // 1.0 for bgr10a2, 0.0 for bgra8
    float aspect;           // resolution.x / resolution.y
    // Shape 0: rounded rect (x, y, w, h) normalized [0,1]
    float4 shape0;
    float  shape0cornerR;   // normalized by drawable height
    // Shape 1: circle (centerX, centerY, radius, 0) normalized
    float4 shape1;
    // Shape 2: circle (centerX, centerY, radius, 0) normalized
    float4 shape2;
    float  shapeCount;      // 1, 2, or 3
    float  padding0;
};

// ─── Constants ───────────────────────────────────────────────────────

constant float REFRACT_EDGE_STRENGTH = 50.0;
constant float REFRACT_INNER_STRENGTH = 30.0;
constant float REFRACT_DECAY = 5.0;

constant float BLUR_MIX = 0.7;

constant float BORDER_WIDTH = 0.07;
constant float BORDER_BRIGHTNESS = 0.5;
constant float BORDER_COLOR_MIX = 0.4;

// ─── SDF ─────────────────────────────────────────────────────────────

inline float sdRoundedRect(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

inline float sdCircle(float2 p, float r) {
    return length(p) - r;
}

inline float3 decodeHDR(float3 color, float isHDR) {
    if (isHDR > 0.5) {
        return (color - 0.375) * 2.0;
    }
    return color;
}

// ─── Vertex ──────────────────────────────────────────────────────────

vertex VertexOut glassVertex(uint vid [[vertex_id]]) {
    float2 pos[4] = {
        float2(-1, -1), float2(1, -1),
        float2(-1,  1), float2(1,  1)
    };
    float2 uvs[4] = {
        float2(0, 1), float2(1, 1),
        float2(0, 0), float2(1, 0)
    };
    VertexOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

// ─── Fragment ────────────────────────────────────────────────────────

constant sampler samp(filter::linear, address::clamp_to_edge);

fragment float4 glassFragment(
    VertexOut in [[stage_in]],
    constant GlassUniforms& u [[buffer(0)]],
    texture2d<float> clearTex [[texture(0)]],
    texture2d<float> blurTex  [[texture(1)]]
) {
    float2 uv = in.uv;
    float aspect = u.aspect;
    float2 p = float2(uv.x * aspect, uv.y);
    int shapeCount = int(u.shapeCount);

    // ── Shape 0: rounded rect ──
    float2 s0origin = u.shape0.xy;
    float2 s0size = u.shape0.zw;
    float2 s0center = s0origin + s0size * 0.5;
    float2 s0centerP = float2(s0center.x * aspect, s0center.y);
    float2 s0half = float2(s0size.x * aspect * 0.5, s0size.y * 0.5);
    float s0cornerR = min(u.shape0cornerR, s0half.y);
    float2 p0 = p - s0centerP;
    float sdf0 = sdRoundedRect(p0, s0half, s0cornerR);

    // ── Shape 1: circle ──
    float sdf1 = 10000.0;
    float2 p1 = float2(0.0);
    float s1radius = 0.0;
    if (shapeCount >= 2) {
        float2 s1center = float2(u.shape1.x * aspect, u.shape1.y);
        s1radius = u.shape1.z * aspect; // radius in aspect-corrected space
        p1 = p - s1center;
        sdf1 = sdCircle(p1, s1radius);
    }

    // ── Shape 2: circle ──
    float sdf2 = 10000.0;
    float2 p2 = float2(0.0);
    float s2radius = 0.0;
    if (shapeCount >= 3) {
        float2 s2center = float2(u.shape2.x * aspect, u.shape2.y);
        s2radius = u.shape2.z * aspect;
        p2 = p - s2center;
        sdf2 = sdCircle(p2, s2radius);
    }

    // ── Combined SDF ──
    float sdf = min(sdf0, min(sdf1, sdf2));

    float scaleY = s0size.y;

    // ── Mask ──
    float aaInner = -0.005 * scaleY;
    float aaOuter = 0.003 * scaleY;
    float mask = 1.0 - smoothstep(aaInner, aaOuter, sdf);
    if (mask < 0.001) discard_fragment();

    // ── Per-shape ownership: determine which shape owns this pixel ──
    // Use original SDFs for stable ownership
    float2 localNormal;
    float localSdf;
    float localCornerR;

    if (sdf1 < sdf0 && sdf1 < sdf2) {
        // Shape 1 (circle) owns this pixel
        localSdf = sdf1;
        localCornerR = s1radius;
        localNormal = length(p1) > 0.00001 ? normalize(p1) : float2(0.0);
    } else if (sdf2 < sdf0 && sdf2 < sdf1) {
        // Shape 2 (circle) owns this pixel
        localSdf = sdf2;
        localCornerR = s2radius;
        localNormal = length(p2) > 0.00001 ? normalize(p2) : float2(0.0);
    } else {
        // Shape 0 (rounded rect) owns this pixel
        localSdf = sdf0;
        localCornerR = s0cornerR;
        // Normal via finite differences
        float eps = 0.001 * scaleY;
        float sdfR = sdRoundedRect(p0 + float2(eps, 0), s0half, s0cornerR);
        float sdfU = sdRoundedRect(p0 + float2(0, eps), s0half, s0cornerR);
        float2 grad = float2(sdfR - sdf0, sdfU - sdf0);
        float gradLen = length(grad);
        localNormal = gradLen > 0.00001 ? grad / gradLen : float2(0.0);
    }

    // ── Edge refraction ──
    float distFromEdge = -localSdf;
    float normDistFromEdge = saturate(distFromEdge / localCornerR);

    float edgeFactor = exp(-normDistFromEdge * REFRACT_DECAY);
    float innerFactor = (1.0 - normDistFromEdge);
    innerFactor = innerFactor * innerFactor;
    float totalRefract = REFRACT_EDGE_STRENGTH * edgeFactor + REFRACT_INNER_STRENGTH * innerFactor;

    float2 refractNormalUV = float2(localNormal.x / aspect, localNormal.y);
    float rnLen = length(refractNormalUV);
    refractNormalUV = rnLen > 0.00001 ? refractNormalUV / rnLen : float2(0.0);

    float formScale = s0size.y;
    float2 refractOffset = refractNormalUV * totalRefract * formScale / u.resolution.y;

    float2 refractedUV = clamp(uv - refractOffset, 0.0, 1.0);

    // ── Sample ──
    float3 clearSample = decodeHDR(clearTex.sample(samp, refractedUV).rgb, u.isHDR);
    float3 blurSample = decodeHDR(blurTex.sample(samp, refractedUV).rgb, u.isHDR);
    float3 col = mix(clearSample, blurSample, BLUR_MIX);

    // ── Global light glow ──
    float avgLuma = 0.0;
    for (int i = 0; i < 5; i++) {
        float t = (float(i) + 0.5) / 5.0;
        float2 glowUV = float2(mix(s0origin.x + 0.05 * s0size.x,
                                    s0origin.x + s0size.x * 0.95, t),
                                s0origin.y + s0size.y * 0.5);
        float3 s = decodeHDR(blurTex.sample(samp, glowUV).rgb, u.isHDR);
        avgLuma += dot(s, float3(0.299, 0.587, 0.114));
    }
    avgLuma /= 5.0;

    float glowAmount = smoothstep(0.05, 0.35, avgLuma);
    float localLuma = dot(col, float3(0.299, 0.587, 0.114));
    col *= mix(1.0, 1.4, glowAmount);
    float darknessFactor = 1.0 - smoothstep(0.0, 0.3, localLuma);
    col += float3(0.15, 0.15, 0.17) * glowAmount * darknessFactor;

    // ── Brightness floor ──
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    float darkBoost = smoothstep(0.0, 0.15, luma);
    col = mix(col + float3(0.1, 0.1, 0.11), col, darkBoost);

    // ── Glass border ──
    float borderWidth = BORDER_WIDTH * localCornerR;
    float borderMask = 1.0 - smoothstep(0.0, borderWidth, distFromEdge);

    float signProduct = localNormal.x * localNormal.y;
    float lightFactor = sign(signProduct) * pow(abs(signProduct), 0.5);
    lightFactor = lightFactor * 0.5 + 0.5;
    lightFactor = clamp(lightFactor, 0.0, 1.0);

    float borderBrightness = BORDER_BRIGHTNESS * mix(0.02, 1.0, lightFactor);

    float refractLuma = dot(col, float3(0.299, 0.587, 0.114));
    float3 saturatedRefract = mix(float3(refractLuma), col, 1.5);
    saturatedRefract = clamp(saturatedRefract, 0.0, 1.0);
    float3 borderColor = mix(float3(1.0), saturatedRefract, BORDER_COLOR_MIX);

    col += borderColor * borderMask * borderBrightness;

    return float4(clamp(col, 0.0, 1.0), mask);
}
