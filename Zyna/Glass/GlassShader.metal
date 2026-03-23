//
//  Liquid glass effect — multi-shape glass + liquid pool.
//  Glass shapes: up to 3 (rounded rect + circles).
//  Liquid pool: opaque with refraction, absorption, caustics.
//

#include <metal_stdlib>
#include "LiquidHelpers.h"
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
    float  screenResY;      // full screen height in pixels (for refraction scaling)
    // Liquid pool
    float  liquidTop;       // normalized Y of liquid surface (rest position)
    float  liquidBottom;    // 1.0 = screen bottom
    float  hasLiquid;       // 1.0 = pool active
    float  time;            // accumulated wave time (advances during scroll, stops in idle)
    float  waveEnergy;      // 0..1 — wave amplitude multiplier (decays after scroll stops)
};

// ─── Constants ───────────────────────────────────────────────────────

// Squircle refraction — models a physical glass dome with squircle cross-section
// h(x) = (1 - (1-x)^N)^(1/N), derivative gives refraction strength
constant float REFRACT_STRENGTH = 350.0;    // overall refraction magnitude
constant float SQUIRCLE_N = 2.5;            // squircle exponent (lower = wider slope distribution)

// Chromatic aberration on glass edges — per-channel displacement scale
constant float CHROMA_SPREAD = 0.08;        // max spread between R and B channels

constant float BLUR_MIX = 0.35;

// Glass tint — pulls colors toward mid-gray (Apple-style dynamic range compression)
constant float TINT_GRAY = 0.38;           // target gray level
constant float TINT_STRENGTH = 0.42;       // how much to pull toward gray

constant float GLASS_TINT = 0.42;              // car-window darkening (1.0 = no tint, 0.0 = black)

constant float GLASS_DISTORTION = 2.0;

constant float BORDER_WIDTH = 0.10;
constant float BORDER_BRIGHTNESS = 0.8;
constant float BORDER_COLOR_MIX = 0.4;

// ─── SDF ─────────────────────────────────────────────────────────────

inline float sdRoundedRect(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

inline float sdCircle(float2 p, float r) {
    return length(p) - r;
}

// ─── Squircle refraction profile ────────────────────────────────────
// Models glass dome height: h(x) = (1 - (1-x)^N)^(1/N)
// where x = normalized distance from edge (0=edge, 1=center)
// Returns the surface slope (derivative of h), which drives refraction strength.
// Slope is steepest at the edge and flattens toward center — like real thick glass.
inline float squircleSlope(float x, float N) {
    // x = normDistFromEdge: 0 at rim, 1 at deep center
    // Clamp away from 0 — the derivative is infinite at x=0 (vertical tangent)
    float xc = clamp(x, 0.02, 1.0);
    float inner = 1.0 - pow(1.0 - xc, N);
    // dh/dx = (1-x)^(N-1) * inner^(1/N - 1)
    float dh = pow(1.0 - xc, N - 1.0) * pow(max(inner, 0.001), 1.0 / N - 1.0);
    return min(dh, 8.0);  // cap to prevent blowup
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

    // ── Shape SDFs ──
    float2 s0origin = u.shape0.xy;
    float2 s0size = u.shape0.zw;
    float2 s0center = s0origin + s0size * 0.5;
    float2 s0centerP = float2(s0center.x * aspect, s0center.y);
    float2 s0half = float2(s0size.x * aspect * 0.5, s0size.y * 0.5);
    float s0cornerR = min(u.shape0cornerR, s0half.y);
    float2 p0 = p - s0centerP;
    float sdf0 = sdRoundedRect(p0, s0half, s0cornerR);

    float sdf1 = 10000.0;
    float2 p1 = float2(0.0);
    float s1radius = 0.0;
    if (shapeCount >= 2) {
        float2 s1center = float2(u.shape1.x * aspect, u.shape1.y);
        s1radius = u.shape1.z;
        p1 = p - s1center;
        sdf1 = sdCircle(p1, s1radius);
    }

    float sdf2 = 10000.0;
    float2 p2 = float2(0.0);
    float s2radius = 0.0;
    if (shapeCount >= 3) {
        float2 s2center = float2(u.shape2.x * aspect, u.shape2.y);
        s2radius = u.shape2.z;
        p2 = p - s2center;
        sdf2 = sdCircle(p2, s2radius);
    }

    float sdf = min(sdf0, min(sdf1, sdf2));
    float scaleY = s0size.y;

    // ── Glass mask ──
    float aaInner = -0.005 * scaleY;
    float aaOuter = 0.003 * scaleY;
    float glassMask = 1.0 - smoothstep(aaInner, aaOuter, sdf);

    // ── Liquid surface ──
    bool hasLiquid = u.hasLiquid > 0.5;
    float surfY = 10000.0;
    if (hasLiquid) {
        surfY = u.liquidTop + surfaceWave(uv.x, u.time, u.waveEnergy);
    }

    bool belowSurface = hasLiquid && uv.y > surfY;

    // Discard: outside glass and liquid (with splash margin)
    float splashMargin = 0.4 * u.waveEnergy;
    if (glassMask < 0.001 && !(hasLiquid && uv.y > (surfY - splashMargin))) discard_fragment();

    // ════════════════════════════════════════════════════════════════════
    //  Glass shapes
    // ════════════════════════════════════════════════════════════════════

    if (glassMask >= 0.001) {
        float2 localNormal;
        float localSdf;
        float localCornerR;
        float formScale;

        if (sdf1 < sdf0 && sdf1 < sdf2) {
            localSdf = sdf1;
            localCornerR = s1radius;
            formScale = u.shape1.z * 2.0;     // circle diameter
            localNormal = length(p1) > 0.00001 ? normalize(p1) : float2(0.0);
        } else if (sdf2 < sdf0 && sdf2 < sdf1) {
            localSdf = sdf2;
            localCornerR = s2radius;
            formScale = u.shape2.z * 2.0;     // circle diameter
            localNormal = length(p2) > 0.00001 ? normalize(p2) : float2(0.0);
        } else {
            localSdf = sdf0;
            localCornerR = s0cornerR;
            formScale = s0size.y;              // rect height
            float eps = 0.002;
            float sdfR = sdRoundedRect(p0 + float2(eps, 0), s0half, s0cornerR);
            float sdfU = sdRoundedRect(p0 + float2(0, eps), s0half, s0cornerR);
            float2 grad = float2(sdfR - sdf0, sdfU - sdf0);
            float gradLen = length(grad);
            localNormal = gradLen > 0.00001 ? grad / gradLen : float2(0.0);
        }

        float distFromEdge = -localSdf;
        float normDistFromEdge = saturate(distFromEdge / localCornerR);

        // ── Squircle refraction profile ──
        float slope = squircleSlope(normDistFromEdge, SQUIRCLE_N);
        float totalRefract = REFRACT_STRENGTH * slope;

        float2 refractNormalUV = float2(localNormal.x / aspect, localNormal.y);
        float rnLen = length(refractNormalUV);
        refractNormalUV = rnLen > 0.00001 ? refractNormalUV / rnLen : float2(0.0);

        // Scale by form size
        float2 baseOffset = refractNormalUV * totalRefract * formScale / u.screenResY;

        // Glass distortion — subtle hash noise for organic imperfection
        float2 pNoise = p * 80.0;
        float dn1 = fract(sin(dot(pNoise * 0.19, float2(127.1, 311.7))) * 43758.5453) - 0.5;
        float dn2 = fract(sin(dot(pNoise * 0.29, float2(269.5, 183.3))) * 43758.5453) - 0.5;
        float dn3 = fract(sin(dot(pNoise * 0.21, float2(419.2, 371.9))) * 43758.5453) - 0.5;
        float dn4 = fract(sin(dot(pNoise * 0.39, float2(523.7, 97.1))) * 43758.5453) - 0.5;
        float2 glassDistort = float2(
            dn1 * 0.6 + dn2 * 0.4,
            dn3 * 0.6 + dn4 * 0.4
        ) * GLASS_DISTORTION / u.resolution;

        // ── Chromatic aberration — per-channel refraction ──
        // Each channel gets a slightly different displacement, strongest at edges
        float chromaScale = slope * CHROMA_SPREAD;
        float2 offsetR = baseOffset * (1.0 - chromaScale) + glassDistort;
        float2 offsetG = baseOffset + glassDistort;
        float2 offsetB = baseOffset * (1.0 + chromaScale) + glassDistort;

        float2 uvR = clamp(uv - offsetR, 0.0, 1.0);
        float2 uvG = clamp(uv - offsetG, 0.0, 1.0);
        float2 uvB = clamp(uv - offsetB, 0.0, 1.0);

        float3 clearCol = float3(
            decodeHDR(clearTex.sample(samp, uvR).rgb, u.isHDR).r,
            decodeHDR(clearTex.sample(samp, uvG).rgb, u.isHDR).g,
            decodeHDR(clearTex.sample(samp, uvB).rgb, u.isHDR).b
        );
        float3 blurCol = float3(
            decodeHDR(blurTex.sample(samp, uvR).rgb, u.isHDR).r,
            decodeHDR(blurTex.sample(samp, uvG).rgb, u.isHDR).g,
            decodeHDR(blurTex.sample(samp, uvB).rgb, u.isHDR).b
        );
        float3 col = mix(clearCol, blurCol, BLUR_MIX);

        // Underwater effect: only during splash, fades in gradually
        if (belowSurface && u.waveEnergy > 0.01) {
            float glassDepth = saturate((uv.y - surfY) / max(u.liquidBottom - surfY, 0.001));
            float fadeIn = smoothstep(0.0, 0.15, glassDepth) * u.waveEnergy;
            float absorption = exp(-glassDepth * 3.0);
            float3 deepBlur = decodeHDR(blurTex.sample(samp, float2(uv.x, min(uv.y + glassDepth * 0.08, 1.0))).rgb, u.isHDR);
            float3 underwaterCol = mix(deepBlur * 0.6, col, absorption * 0.6 + 0.1);
            col = mix(col, underwaterCol, fadeIn);
        }

        // ── Apple-style tint — compress luminance, preserve color ──
        float preLuma = dot(col, float3(0.299, 0.587, 0.114));
        // Brighter pixels get compressed proportionally more — no hard threshold
        float brightExtra = preLuma * 0.28;
        float targetLuma = mix(preLuma, TINT_GRAY, TINT_STRENGTH + brightExtra);
        // Additive chroma: keep color deviation from gray, shift the baseline
        // Slightly desaturate chroma (~15%) so colors are just a touch grayer
        float3 chroma = (col - preLuma) * 0.70;
        col = clamp(float3(targetLuma) + chroma, 0.0, 1.0);

        // ── Global light glow — gentle ambient lift from bright areas ──
        float avgLuma = 0.0;
        for (int iy = 0; iy < 3; iy++) {
            float ty = (float(iy) + 0.5) / 3.0;
            for (int ix = 0; ix < 3; ix++) {
                float tx = (float(ix) + 0.5) / 3.0;
                float2 glowUV = float2(
                    mix(s0origin.x + 0.05 * s0size.x, s0origin.x + s0size.x * 0.95, tx),
                    mix(s0origin.y + 0.05 * s0size.y, s0origin.y + s0size.y * 0.95, ty)
                );
                float3 s = decodeHDR(blurTex.sample(samp, glowUV).rgb, u.isHDR);
                avgLuma += dot(s, float3(0.299, 0.587, 0.114));
            }
        }
        avgLuma /= 9.0;

        float glowAmount = smoothstep(0.15, 0.5, avgLuma);
        float localLuma = dot(col, float3(0.299, 0.587, 0.114));
        // Subtle brightness lift — much gentler than before
        col *= mix(1.0, 1.06, glowAmount);
        // Lift dark areas slightly when surroundings are bright
        float darknessFactor = 1.0 - smoothstep(0.0, 0.3, localLuma);
        col += float3(0.03) * glowAmount * darknessFactor;

        // ── Fresnel rim lighting — thin edge glow ──
        float fresnelDist = saturate(distFromEdge / (localCornerR * 0.15));
        float fresnel = pow(1.0 - fresnelDist, 4.0);
        // Directional: top-left lit, bottom-right shadowed
        float lightDir = saturate((-localNormal.x + -localNormal.y) * 0.5 + 0.5);
        float fresnelLit = fresnel * mix(0.03, 0.15, lightDir);
        col += float3(1.0, 1.0, 1.02) * fresnelLit;

        // ── Inner shadow — subtle darkening just inside the edge for depth ──
        float shadowZone = smoothstep(0.0, localCornerR * 0.1, distFromEdge);
        float shadowSide = saturate((localNormal.x + localNormal.y) * 0.5 + 0.5);
        col *= 1.0 - (1.0 - shadowZone) * shadowSide * 0.08;

        // ── Glass border — soft rim line ──
        float borderInner = localCornerR * 0.01;
        float borderOuter = BORDER_WIDTH * localCornerR;
        float borderMask = smoothstep(borderInner, borderInner + borderOuter * 0.3, distFromEdge)
                         * (1.0 - smoothstep(borderInner + borderOuter * 0.3, borderInner + borderOuter, distFromEdge));

        float borderBrightness = BORDER_BRIGHTNESS * mix(0.05, 0.5, lightDir);

        float refractLuma = dot(col, float3(0.299, 0.587, 0.114));
        float3 saturatedRefract = mix(float3(refractLuma), col, 1.5);
        saturatedRefract = clamp(saturatedRefract, 0.0, 1.0);
        float3 borderColor = mix(float3(1.0), saturatedRefract, BORDER_COLOR_MIX);

        col += borderColor * borderMask * borderBrightness;

        // Tint — like car window tint, darken everything uniformly
        col *= GLASS_TINT;

        return float4(clamp(col, 0.0, 1.0), glassMask);
    }

    // ════════════════════════════════════════════════════════════════════
    //  Liquid pool — procedural 2D waves
    // ════════════════════════════════════════════════════════════════════

    float energy = u.waveEnergy;
    float t = u.time;

    // Surface displacement: surfaceWave (sinusoidal) already in surfY
    // Add extra 2D sloshing when energy > 0
    float splashDisp = 0.0;
    if (energy > 0.01) {
        // Large sloshing wave — the main visible deformation
        splashDisp += sin(uv.x * 8.0 + t * 1.5) * 0.03;
        splashDisp += sin(uv.x * 5.0 - t * 0.9) * 0.02;
        // Noise-driven organic shape
        splashDisp += (fbm(float2(uv.x * 6.0 + t * 0.4, t * 0.3)) - 0.5) * 0.04;
        splashDisp *= energy;
    }

    float refinedSurfY = surfY - splashDisp;

    // Above even the splash → discard
    if (uv.y < refinedSurfY) discard_fragment();

    float poolRange = max(u.liquidBottom - refinedSurfY, 0.001);
    float depth = saturate((uv.y - refinedSurfY) / poolRange);
    float depthSq = depth * depth;
    bool isSplashPeak = uv.y < surfY;

    // ── Plain blur (idle state) ──
    float blurAmount = smoothstep(0.0, 0.25, depth);
    float3 idleClear = decodeHDR(clearTex.sample(samp, uv).rgb, u.isHDR);
    float3 idleBlur  = decodeHDR(blurTex.sample(samp, uv).rgb, u.isHDR);
    float3 idleCol   = mix(idleClear, idleBlur, blurAmount);
    idleCol *= 1.0 - depth * 0.15;

    // ── Liquid effects (splash state) ──
    float3 splashCol = idleCol;
    if (energy > 0.01) {
        // 2D refraction — warp UV based on noise, not column scanning
        float2 refrUV = uv;
        float warpAmt = energy * (0.015 + depth * 0.025);
        float2 noiseCoord = float2(uv.x * 8.0 + t * 0.5, uv.y * 6.0 - t * 0.3);
        refrUV.x += (vnoise(noiseCoord) - 0.5) * warpAmt;
        refrUV.y += (vnoise(noiseCoord + float2(100.0, 0.0)) - 0.5) * warpAmt;
        // Upward shift near surface — magnifying lens effect
        refrUV.y -= (0.03 + depthSq * 0.04) * energy;
        refrUV = clamp(refrUV, 0.0, 1.0);

        // Chromatic aberration
        float spread = depthSq * energy * 0.025;
        float3 content;
        content.r = decodeHDR(clearTex.sample(samp, refrUV + float2( spread, 0)).rgb, u.isHDR).r;
        content.g = decodeHDR(clearTex.sample(samp, refrUV).rgb, u.isHDR).g;
        content.b = decodeHDR(clearTex.sample(samp, refrUV - float2( spread, 0)).rgb, u.isHDR).b;

        float3 blurContent = decodeHDR(blurTex.sample(samp, refrUV).rgb, u.isHDR);
        content = mix(content, blurContent, saturate(depth * 1.5));

        // Liquid body
        float2 deepUV = float2(uv.x, min(uv.y + depth * 0.08, 1.0));
        float3 deepSample = decodeHDR(blurTex.sample(samp, deepUV).rgb, u.isHDR);
        float deepLuma = dot(deepSample, float3(0.299, 0.587, 0.114));
        float3 liqCol = mix(float3(deepLuma), deepSample, 1.2 + energy * 0.5);
        liqCol = clamp(liqCol, 0.0, 1.0);
        liqCol *= (1.0 - depth * 0.35);
        liqCol += float3(0.08) * causticBrightness(depth, uv, t, energy);

        float absorption = exp(-depth * 4.0);
        splashCol = mix(liqCol, content, absorption);
    }

    // ── Blend: idle=plain blur, active=liquid ──
    float3 col = mix(idleCol, splashCol, energy);

    // ── Surface effects ──
    float surfDist = uv.y - refinedSurfY;
    float nearSurface = exp(-surfDist * 150.0);

    if (energy > 0.01 && nearSurface > 0.01) {
        // Slope from surface wave + splash
        float eps = 0.003;
        float wL = surfaceWave(uv.x - eps, t, energy);
        float wR = surfaceWave(uv.x + eps, t, energy);
        float slope = (wR - wL) / (2.0 * eps) + splashDisp * 8.0;

        // Specular highlight along wave crests
        float specular = pow(saturate(1.0 - abs(slope) * 6.0), 6.0);

        // Reflection
        float2 reflectUV = clamp(float2(uv.x + slope * 0.02, refinedSurfY - surfDist * 0.5), 0.0, 1.0);
        float3 reflected = decodeHDR(clearTex.sample(samp, reflectUV).rgb, u.isHDR);
        float fresnel = pow(1.0 - saturate(surfDist * 60.0), 3.0);

        col = mix(col, reflected, fresnel * 0.4 * energy);
        col += float3(0.8, 0.8, 0.85) * specular * nearSurface * energy;

        // Bright edge line at surface
        float edgeLine = exp(-surfDist * 250.0);
        col += float3(0.7, 0.7, 0.75) * edgeLine * 0.6 * energy;
    }

    // ── Alpha ──
    float alpha;
    if (isSplashPeak && energy > 0.01) {
        float thinness = saturate((surfY - uv.y) / max(splashMargin, 0.001));
        alpha = (1.0 - thinness * 0.4) * 0.85 * energy;

        // Iridescent color shift at splash tips
        float huePhase = uv.x * 10.0 + uv.y * 6.0 + t * 1.5 + splashDisp * 15.0;
        float3 hueShift = float3(
            sin(huePhase) * 0.5 + 0.5,
            sin(huePhase + 2.094) * 0.5 + 0.5,
            sin(huePhase + 4.189) * 0.5 + 0.5
        );

        float baseLuma = dot(col, float3(0.299, 0.587, 0.114)) + 0.1;
        float iridStrength = thinness * energy * 0.45;
        col = mix(col, hueShift * baseLuma, iridStrength);
        float luma = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(luma), col, 1.5);
        col += float3(0.08) * thinness * nearSurface;
    } else {
        float st = smoothstep(0.0, 0.2, surfDist);
        float gradualFade = st * st * 0.97;
        float sharpFade = smoothstep(0.0, 0.005, surfDist);
        alpha = mix(gradualFade, sharpFade, energy);
    }

    return float4(clamp(col, 0.0, 1.0), alpha);
}
