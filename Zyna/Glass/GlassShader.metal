//
//  GlassShader.metal
//  Zyna
//
//  Created by Dmitry Markovskiy on 22.03.2026.
//
//  Apple-style liquid glass effect.
//  Ported from LiquidGlass (Telegram), single rounded rect.
//  Coordinate system: normalized drawable space [0,1], origin top-left.
//  Shape occupies a sub-region of the drawable (with padding for edge refraction).
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
    float cornerRadius;     // normalized by drawable height
    float isHDR;            // 1.0 for bgr10a2, 0.0 for bgra8
    float4 shapeRect;       // (x, y, w, h) normalized [0,1] — where glass sits in drawable
    float aspect;           // resolution.x / resolution.y
    float padding0;
    float padding1;
    float padding2;
};

// ─── Constants ───────────────────────────────────────────────────────

// Edge refraction (Apple Liquid Glass бортик)
constant float REFRACT_EDGE_STRENGTH = 50.0;
constant float REFRACT_INNER_STRENGTH = 30.0;
constant float REFRACT_DECAY = 5.0;

// Blur mix
constant float BLUR_MIX = 0.7;

// Border
constant float BORDER_WIDTH = 0.07;
constant float BORDER_BRIGHTNESS = 0.5;
constant float BORDER_COLOR_MIX = 0.4;

// ─── Utility ─────────────────────────────────────────────────────────

inline float sdRoundedRect(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
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

    // ── Coordinates ──
    // p = aspect-corrected position for SDF math
    float2 p = float2(uv.x * aspect, uv.y);

    // Shape rect within the drawable (with padding around it)
    float2 inputOrigin = u.shapeRect.xy;
    float2 inputSize = u.shapeRect.zw;
    float2 inputCenter = inputOrigin + inputSize * 0.5;
    float2 inputCenterP = float2(inputCenter.x * aspect, inputCenter.y);
    float2 inputHalfSize = float2(inputSize.x * aspect * 0.5, inputSize.y * 0.5);
    float inputCornerR = min(u.cornerRadius, inputHalfSize.y);

    float2 pInput = p - inputCenterP;
    float sdf = sdRoundedRect(pInput, inputHalfSize, inputCornerR);

    float scaleY = inputSize.y;

    // ── Mask ──
    float aaInner = -0.005 * scaleY;
    float aaOuter = 0.003 * scaleY;
    float mask = 1.0 - smoothstep(aaInner, aaOuter, sdf);
    if (mask < 0.001) discard_fragment();

    // ── Normal (SDF gradient via finite differences) ──
    float eps = 0.001 * scaleY;
    float sdfR = sdRoundedRect(pInput + float2(eps, 0), inputHalfSize, inputCornerR);
    float sdfU = sdRoundedRect(pInput + float2(0, eps), inputHalfSize, inputCornerR);
    float2 grad = float2(sdfR - sdf, sdfU - sdf);
    float gradLen = length(grad);
    float2 normal = gradLen > 0.00001 ? grad / gradLen : float2(0.0);

    // ── Edge refraction ──
    float distFromEdge = -sdf;
    float normDistFromEdge = saturate(distFromEdge / inputCornerR);

    // Exponential peak at edge, quadratic inner
    float edgeFactor = exp(-normDistFromEdge * REFRACT_DECAY);
    float innerFactor = (1.0 - normDistFromEdge);
    innerFactor = innerFactor * innerFactor;
    float totalRefract = REFRACT_EDGE_STRENGTH * edgeFactor + REFRACT_INNER_STRENGTH * innerFactor;

    // Normal in UV space (undo aspect correction)
    float2 refractNormalUV = float2(normal.x / aspect, normal.y);
    float rnLen = length(refractNormalUV);
    refractNormalUV = rnLen > 0.00001 ? refractNormalUV / rnLen : float2(0.0);

    // Refraction offset scaled by shape height (matches original Telegram formula)
    float formScale = inputSize.y;
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
        float2 glowUV = float2(mix(inputOrigin.x + 0.05 * inputSize.x,
                                    inputOrigin.x + inputSize.x * 0.95, t),
                                inputOrigin.y + inputSize.y * 0.5);
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
    float borderWidth = BORDER_WIDTH * inputCornerR;
    float borderMask = 1.0 - smoothstep(0.0, borderWidth, distFromEdge);

    // Directional lighting: upper-left = bright, lower-right = shadow
    float signProduct = normal.x * normal.y;
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
