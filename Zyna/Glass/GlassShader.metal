//
//  LiquidGlass.metal
//
//  Liquid glass effect — multi-shape glass + liquid pool.
//  Glass refraction: squircle bevel profile + Snell's law.
//  bezelWidth controls zone, glassThickness controls displacement strength.
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
    float  isHDR;           // 1.0 for bgr10a2, 0.0 for bgra8
    float  aspect;          // resolution.x / resolution.y
    // Shape 0: rounded rect (x, y, w, h) normalized [0,1]
    float4 shape0;
    float  shape0cornerR;   // normalized by drawable height
    float  bezelWidth;      // bevel zone in capture-frame UV (bevelPt / captureH)
    // Shape 1: circle (centerX, centerY, radius, 0) normalized
    float4 shape1;
    // Shape 2: circle (centerX, centerY, radius, 0) normalized
    float4 shape2;
    float  shapeCount;      // 1, 2, or 3
    float  glassThickness;  // displacement strength in capture-frame UV (thickPt / captureH)
    // Liquid pool
    float  liquidTop;
    float  liquidBottom;
    float  hasLiquid;
    float  time;
    float  waveEnergy;
    // Chrome bars
    float  barHeights[16];
    float  barCount;
    float4 barZone;
    float  barActive;
};

// ─── Glass refraction constants ─────────────────────────────────────

constant float SQUIRCLE_N       = 2.5;   // profile exponent (2=hemisphere, 3=steep, 2.5=balanced)
constant float IOR              = 4;   // index of refraction (glass 1.5)
constant float ETA              = 1.0 / IOR;
constant float REFRACT_SCALE    = 1.0;   // fine-tune multiplier on displacement

// ─── Glass appearance constants ─────────────────────────────────────

constant float CHROMA_SPREAD  = 0.02;   // chromatic aberration (0=none, 0.08=heavy)
constant float TINT_GRAY      = 0.45;   // luminance compression target
constant float TINT_STRENGTH  = 0.06;   // how much to compress toward gray (was 0.15)
constant float GLASS_TINT     = 1.0;    // overall darkening (1.0=none)

// ─── Border / rim constants ─────────────────────────────────────────

constant float BORDER_WIDTH      = 0.08;
constant float BORDER_BRIGHTNESS = 0.3;
constant float BORDER_COLOR_MIX  = 0.3;

// ─── Chrome constants ───────────────────────────────────────────────

constant float META_K            = 0.06;
constant float META_PUDDLE_H     = 0.014;
constant float CHROME_BASE       = 0.06;
constant float CHROME_REFLECT    = 0.80;
constant float CHROME_FRESNEL_POW = 2.5;
constant float CHROME_SPEC_POW   = 32.0;

// ─── SDF primitives ─────────────────────────────────────────────────

inline float sdRoundedRect(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

inline float sdCircle(float2 p, float r) {
    return length(p) - r;
}

inline float sdCapsuleV(float2 p, float2 c, float hh, float r) {
    float2 d = p - c;
    d.y = abs(d.y) - hh;
    d.y = max(d.y, 0.0);
    return length(d) - r;
}

// ─── Chrome metaball field ──────────────────────────────────────────

inline float chromeMetaballField(float2 p, float aspect, constant GlassUniforms& u) {
    if (u.barActive < 0.5) return 10000.0;

    int count = min(int(u.barCount), 16);
    float2 zoneOrigin = float2(u.barZone.x * aspect, u.barZone.y);
    float zoneW = u.barZone.z * aspect;
    float zoneH = u.barZone.w;
    float zoneBottom = zoneOrigin.y + zoneH;
    float t = u.time;

    float2 puddleCenter = float2(zoneOrigin.x + zoneW * 0.5, zoneBottom);
    float puddleBreath = 1.0 + sin(t * 2.0) * 0.05;
    float field = sdRoundedRect(p - puddleCenter,
        float2(zoneW * 0.52 * puddleBreath, META_PUDDLE_H), META_PUDDLE_H);

    float barSpacing = zoneW / float(count);
    float baseRadius = barSpacing * 0.38;
    float startX = zoneOrigin.x + barSpacing * 0.5;

    for (int i = 0; i < count; i++) {
        float h = u.barHeights[i] * zoneH;
        if (h < 0.003) continue;

        float cx = startX + float(i) * barSpacing;
        float phase = float(i) * 1.7 + t * 1.2;
        float sway = sin(phase) * 0.003 * h / zoneH;
        cx += sway;

        float hNorm = h / zoneH;
        float radius = baseRadius * (0.7 + 0.3 * hNorm);
        float halfH = max(h * 0.5 - radius, 0.0);
        float2 capCenter = float2(cx, zoneBottom - radius - halfH);
        float capSdf = sdCapsuleV(p, capCenter, halfH, radius);

        float tipRadius = radius * (0.8 + 0.4 * hNorm);
        float2 tipCenter = float2(cx + sway * 2.0, zoneBottom - h + tipRadius * 0.5);
        float tipSdf = sdCircle(p - tipCenter, tipRadius);

        float barField = smin(capSdf, tipSdf, META_K * 0.7);
        field = smin(field, barField, META_K);
    }
    return field;
}

// ─── Squircle refraction profile ────────────────────────────────────
//
//  h(x) = (1 - (1-x)^N)^(1/N)     x ∈ [0,1], 0=edge, 1=plateau
//
//  dh/dx = (1-x)^(N-1) · [1-(1-x)^N]^(1/N - 1)
//
//  This derivative is the surface slope. Steep at edge, flat at center.

inline float squircleSlope(float x, float N) {
    float xc = clamp(x, 0.001, 1.0);  // relaxed: Snell's law bounds output
    float u = 1.0 - xc;
    float uN = pow(u, N);
    float inner = 1.0 - uN;
    return pow(u, N - 1.0) * pow(max(inner, 1e-6), 1.0 / N - 1.0);
}

// ─── HDR decode ─────────────────────────────────────────────────────

inline float3 decodeHDR(float3 color, float isHDR) {
    return isHDR > 0.5 ? (color - 0.375) * 2.0 : color;
}

// ─── Vertex ─────────────────────────────────────────────────────────

vertex VertexOut glassVertex(uint vid [[vertex_id]]) {
    float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
    float2 uvs[4] = { {0,1}, {1,1}, {0,0}, {1,0} };
    VertexOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

// ─── Fragment ───────────────────────────────────────────────────────

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

    // ────────────────────────────────────────────────────────────────
    //  Shape SDFs
    // ────────────────────────────────────────────────────────────────

    // Shape 0: rounded rect
    float2 s0origin = u.shape0.xy;
    float2 s0size   = u.shape0.zw;
    float2 s0center = s0origin + s0size * 0.5;
    float2 s0centerP = float2(s0center.x * aspect, s0center.y);
    float2 s0half = float2(s0size.x * aspect * 0.5, s0size.y * 0.5);
    float  s0cornerR = min(u.shape0cornerR, s0half.y);
    float2 p0 = p - s0centerP;
    float  sdf0 = sdRoundedRect(p0, s0half, s0cornerR);

    // Shape 1: circle
    float sdf1 = 10000.0;
    float2 p1 = float2(0.0);
    float s1radius = 0.0;
    if (shapeCount >= 2) {
        float2 s1center = float2(u.shape1.x * aspect, u.shape1.y);
        s1radius = u.shape1.z;
        p1 = p - s1center;
        sdf1 = sdCircle(p1, s1radius);
    }

    // Shape 2: circle
    float sdf2 = 10000.0;
    float2 p2 = float2(0.0);
    float s2radius = 0.0;
    if (shapeCount >= 3) {
        float2 s2center = float2(u.shape2.x * aspect, u.shape2.y);
        s2radius = u.shape2.z;
        p2 = p - s2center;
        sdf2 = sdCircle(p2, s2radius);
    }

    // Chrome
    float chromeSdf = chromeMetaballField(p, aspect, u);

    // Combined SDF
    float sdf = min(sdf0, min(sdf1, sdf2));

    // ────────────────────────────────────────────────────────────────
    //  Masks
    // ────────────────────────────────────────────────────────────────

    float scaleY = s0size.y;
    float glassMask = 1.0 - smoothstep(-0.005 * scaleY, 0.003 * scaleY, sdf);
    float chromeMask = 1.0 - smoothstep(-0.002, 0.002, chromeSdf);

    // Liquid surface
    bool hasLiquid = u.hasLiquid > 0.5;
    float surfY = 10000.0;
    if (hasLiquid) {
        surfY = u.liquidTop + surfaceWave(uv.x, u.time, u.waveEnergy);
    }
    bool belowSurface = hasLiquid && uv.y > surfY;

    // Early discard
    float splashMargin = 0.4 * u.waveEnergy;
    if (glassMask < 0.001 && chromeMask < 0.001 &&
        !(hasLiquid && uv.y > (surfY - splashMargin)))
        discard_fragment();

    // ════════════════════════════════════════════════════════════════
    //  GLASS
    // ════════════════════════════════════════════════════════════════

    if (glassMask >= 0.001) {

        // ── 1. Find closest shape, get SDF + edge normal ──

        float2 edgeNormal;     // points outward from shape center
        float  localSdf;

        if (sdf1 < sdf0 && sdf1 < sdf2) {
            localSdf = sdf1;
            edgeNormal = length(p1) > 1e-5 ? normalize(p1) : float2(0.0);
        } else if (sdf2 < sdf0 && sdf2 < sdf1) {
            localSdf = sdf2;
            edgeNormal = length(p2) > 1e-5 ? normalize(p2) : float2(0.0);
        } else {
            localSdf = sdf0;
            float eps = 0.001;
            float gx = sdRoundedRect(p0 + float2(eps, 0), s0half, s0cornerR) - sdf0;
            float gy = sdRoundedRect(p0 + float2(0, eps), s0half, s0cornerR) - sdf0;
            float2 grad = float2(gx, gy);
            float glen = length(grad);
            edgeNormal = glen > 1e-5 ? grad / glen : float2(0.0);
        }

        float distFromEdge = -localSdf;  // positive inside shape

        // ── 2. Refraction via Snell's law ──
        //
        //  bezelWidth = fixed bevel zone (e.g. 12pt) in capture-frame UV.
        //  glassThickness = displacement strength (e.g. 40pt) in capture-frame UV.
        //  Beyond bevel: flat plateau, no refraction.

        float bw = u.bezelWidth;
        float normDist = saturate(distFromEdge / bw);  // 0=edge, 1=plateau

        // Surface slope from squircle profile derivative
        float slope = squircleSlope(normDist, SQUIRCLE_N);

        // Snell's law: slope → physically bounded lateral displacement [0, ~0.745]
        float s2     = slope * slope;
        float invL   = rsqrt(1.0 + s2);
        float cosI   = invL;
        float sinI   = slope * invL;
        float cosT   = sqrt(max(1.0 - ETA * ETA * sinI * sinI, 0.0));
        float T_lat  = sinI * (cosT - ETA * cosI);

        // Direction: SDF gradient → UV space (NOT normalized).
        // The 1/aspect factor compensates for non-square capture frame,
        // ensuring equal physical displacement on horizontal and vertical edges.
        float2 refractDir = float2(edgeNormal.x / aspect, edgeNormal.y);

        // offset = direction × deflection × glass_thickness × scale
        float2 offset = refractDir * T_lat * u.glassThickness * REFRACT_SCALE;

        // ── 3. Sample with chromatic aberration ──
        //  Apple model: blur FIRST (uniform frosted glass), then refract.
        //  Base = blurTex with refraction offset (frosted + displaced).
        //  On bevel, mix in clearTex for sharper refraction detail.

        float chromaAmt = slope * CHROMA_SPREAD;
        float2 offsetR = offset * (1.0 - chromaAmt);
        float2 offsetG = offset;
        float2 offsetB = offset * (1.0 + chromaAmt);

        float2 uvR = clamp(uv - offsetR, 0.0, 1.0);
        float2 uvG = clamp(uv - offsetG, 0.0, 1.0);
        float2 uvB = clamp(uv - offsetB, 0.0, 1.0);

        // Uniform frosted glass: blurTex everywhere (refracted on bevel)
        float3 col = float3(
            decodeHDR(blurTex.sample(samp, uvR).rgb, u.isHDR).r,
            decodeHDR(blurTex.sample(samp, uvG).rgb, u.isHDR).g,
            decodeHDR(blurTex.sample(samp, uvB).rgb, u.isHDR).b
        );

        // ── 4. Underwater overlay (during liquid splash) ──

        if (belowSurface && u.waveEnergy > 0.01) {
            float glassDepth = saturate((uv.y - surfY) / max(u.liquidBottom - surfY, 0.001));
            float fadeIn = smoothstep(0.0, 0.15, glassDepth) * u.waveEnergy;
            float absorption = exp(-glassDepth * 3.0);
            float3 deepBlur = decodeHDR(
                blurTex.sample(samp, float2(uv.x, min(uv.y + glassDepth * 0.08, 1.0))).rgb,
                u.isHDR);
            float3 underwaterCol = mix(deepBlur * 0.6, col, absorption * 0.6 + 0.1);
            col = mix(col, underwaterCol, fadeIn);
        }

        // ── 5. Tint — gentle luminance compression, preserve color ──

        float luma = dot(col, float3(0.299, 0.587, 0.114));
        float targetLuma = mix(luma, TINT_GRAY, TINT_STRENGTH);
        float3 chroma = (col - luma) * 0.92;
        col = clamp(float3(targetLuma) + chroma, 0.0, 1.0);

        // ── 6. Glass luminance boost — Apple glass amplifies background ──

        float preLuma = dot(col, float3(0.299, 0.587, 0.114));
        col += float3(0.0435) * (1.0 - smoothstep(0.0, 0.12, preLuma));  // lift dark areas only  0.0435
        col *= 1.15;          // uniform brightness lift
        float boostLuma = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(boostLuma), col, 1.08);  // slight saturation push

        // ── 7. Fresnel rim — thin bright edge ──

        float fresnelZone = saturate(distFromEdge / (bw * 0.15));
        float fresnel = pow(1.0 - fresnelZone, 4.0);
        float lightDir = saturate((-edgeNormal.x - edgeNormal.y) * 0.5 + 0.5);
        col += float3(1.0, 1.0, 1.02) * fresnel * mix(0.02, 0.08, lightDir);

        // ── 8. Inner shadow ──

        float shadowZone = smoothstep(0.0, bw * 0.12, distFromEdge);
        float shadowSide = saturate((edgeNormal.x + edgeNormal.y) * 0.5 + 0.5);
        col *= 1.0 - (1.0 - shadowZone) * shadowSide * 0.08;

        // ── 9. Border line ──

        float bInner = bw * 0.02;
        float bOuter = BORDER_WIDTH * bw;
        float borderMask = smoothstep(bInner, bInner + bOuter * 0.3, distFromEdge)
                         * (1.0 - smoothstep(bInner + bOuter * 0.3, bInner + bOuter, distFromEdge));
        float bBright = BORDER_BRIGHTNESS * mix(0.05, 0.5, lightDir);
        float refLuma = dot(col, float3(0.299, 0.587, 0.114));
        float3 borderCol = mix(float3(1.0), clamp(mix(float3(refLuma), col, 1.5), 0.0, 1.0),
                               BORDER_COLOR_MIX);
        col += borderCol * borderMask * bBright;

        // ── 10. Final tint ──

        col *= GLASS_TINT;

        return float4(clamp(col, 0.0, 1.0), glassMask);
    }

    // ════════════════════════════════════════════════════════════════
    //  CHROME METABALL
    // ════════════════════════════════════════════════════════════════

    if (chromeMask > 0.001) {
        float eps = 0.0015;
        float csR = chromeMetaballField(p + float2(eps, 0), aspect, u);
        float csU = chromeMetaballField(p + float2(0, eps), aspect, u);
        float2 grad = float2(csR - chromeSdf, csU - chromeSdf);
        float gradLen = length(grad);
        float2 normal = gradLen > 1e-5 ? grad / gradLen : float2(0.0, -1.0);

        float edgeDist = saturate(-chromeSdf / (META_K * 0.8));

        // Environment reflection
        float2 normalUV = float2(normal.x / aspect, normal.y);
        float2 reflUV = float2(uv.x + normalUV.x * 0.12, 1.0 - uv.y + normalUV.y * 0.12);
        float2 noiseP = p * 20.0 + u.time * 0.4;
        reflUV += float2(vnoise(noiseP) - 0.5, vnoise(noiseP + float2(50, 0)) - 0.5) * 0.025;
        reflUV = clamp(reflUV, 0.0, 1.0);
        float3 envColor = decodeHDR(clearTex.sample(samp, reflUV).rgb, u.isHDR);
        float envLuma = dot(envColor, float3(0.299, 0.587, 0.114));
        envColor = clamp(mix(float3(envLuma), envColor, 1.6), 0.0, 1.0);

        float fresnel = pow(1.0 - edgeDist, CHROME_FRESNEL_POW);

        float2 lightDir = normalize(float2(-0.5, -0.7));
        float spec = pow(saturate(dot(normal, lightDir)), CHROME_SPEC_POW);
        float2 fillDir = normalize(float2(0.4, -0.8));
        float fillSpec = pow(saturate(dot(normal, fillDir)), CHROME_SPEC_POW * 0.5) * 0.3;
        float rimSpec = pow(saturate(normal.y), 12.0) * 0.25;

        float3 col = float3(CHROME_BASE);
        col += envColor * CHROME_REFLECT * (0.3 + fresnel * 0.7);
        col += float3(0.80, 0.85, 1.0) * fresnel * 0.20;
        col += float3(1.0) * spec * 0.9;
        col += float3(0.9, 0.92, 1.0) * fillSpec;
        col += float3(0.6, 0.65, 0.8) * rimSpec;

        float rim = exp(chromeSdf * 200.0);
        col += float3(0.6, 0.65, 0.8) * rim * 0.5;

        float bottomShade = saturate(normal.y * 0.5 + 0.5);
        col *= 1.0 - bottomShade * 0.25;

        float hueShift = vnoise(p * 15.0 + u.time * 0.2) * 0.15;
        col.r += hueShift * 0.08;
        col.b -= hueShift * 0.05;

        return float4(clamp(col, 0.0, 1.0), chromeMask);
    }

    // ════════════════════════════════════════════════════════════════
    //  LIQUID POOL
    // ════════════════════════════════════════════════════════════════

    float energy = u.waveEnergy;
    float t = u.time;

    float splashDisp = 0.0;
    if (energy > 0.01) {
        splashDisp += sin(uv.x * 8.0 + t * 1.5) * 0.03;
        splashDisp += sin(uv.x * 5.0 - t * 0.9) * 0.02;
        splashDisp += (fbm(float2(uv.x * 6.0 + t * 0.4, t * 0.3)) - 0.5) * 0.04;
        splashDisp *= energy;
    }

    float refinedSurfY = surfY - splashDisp;
    if (uv.y < refinedSurfY) discard_fragment();

    float poolRange = max(u.liquidBottom - refinedSurfY, 0.001);
    float depth = saturate((uv.y - refinedSurfY) / poolRange);
    float depthSq = depth * depth;
    bool isSplashPeak = uv.y < surfY;

    // Idle: progressive blur
    float blurAmount = smoothstep(0.0, 0.25, depth);
    float3 idleClear = decodeHDR(clearTex.sample(samp, uv).rgb, u.isHDR);
    float3 idleBlur  = decodeHDR(blurTex.sample(samp, uv).rgb, u.isHDR);
    float3 idleCol   = mix(idleClear, idleBlur, blurAmount) * (1.0 - depth * 0.15);

    // Splash
    float3 splashCol = idleCol;
    if (energy > 0.01) {
        float2 refrUV = uv;
        float warpAmt = energy * (0.03 + depth * 0.05);
        float2 nc = float2(uv.x * 8.0 + t * 0.5, uv.y * 6.0 - t * 0.3);
        refrUV.x += (vnoise(nc) - 0.5) * warpAmt;
        refrUV.y += (vnoise(nc + float2(100, 0)) - 0.5) * warpAmt;
        refrUV.y -= (0.05 + depthSq * 0.06) * energy;
        refrUV = clamp(refrUV, 0.0, 1.0);

        float spread = depthSq * energy * 0.04;
        float3 content;
        content.r = decodeHDR(clearTex.sample(samp, refrUV + float2(spread, 0)).rgb, u.isHDR).r;
        content.g = decodeHDR(clearTex.sample(samp, refrUV).rgb, u.isHDR).g;
        content.b = decodeHDR(clearTex.sample(samp, refrUV - float2(spread, 0)).rgb, u.isHDR).b;

        content = mix(content, decodeHDR(blurTex.sample(samp, refrUV).rgb, u.isHDR),
                      saturate(depth * 1.2));

        float2 deepUV = float2(uv.x, min(uv.y + depth * 0.1, 1.0));
        float3 deepSample = decodeHDR(blurTex.sample(samp, deepUV).rgb, u.isHDR);
        float deepLuma = dot(deepSample, float3(0.299, 0.587, 0.114));
        float3 liqCol = clamp(mix(float3(deepLuma), deepSample, 1.3 + energy * 0.6), 0.0, 1.0);
        liqCol *= (1.0 - depth * 0.5);
        liqCol += float3(0.12) * causticBrightness(depth, uv, t, energy);

        splashCol = mix(liqCol, content, exp(-depth * 2.5));
    }

    float3 col = mix(idleCol, splashCol, energy);

    // Surface effects
    float surfDist = uv.y - refinedSurfY;
    float nearSurface = exp(-surfDist * 150.0);

    if (energy > 0.01 && nearSurface > 0.01) {
        float eps = 0.003;
        float wL = surfaceWave(uv.x - eps, t, energy);
        float wR = surfaceWave(uv.x + eps, t, energy);
        float slope = (wR - wL) / (2.0 * eps) + splashDisp * 8.0;

        float specular = pow(saturate(1.0 - abs(slope) * 6.0), 6.0);

        float2 reflectUV = clamp(float2(uv.x + slope * 0.02, refinedSurfY - surfDist * 0.5), 0.0, 1.0);
        float3 reflected = decodeHDR(clearTex.sample(samp, reflectUV).rgb, u.isHDR);
        float fresnel = pow(1.0 - saturate(surfDist * 60.0), 3.0);

        col = mix(col, reflected, fresnel * 0.6 * energy);
        col += float3(0.9, 0.9, 0.95) * specular * nearSurface * energy;
        col += float3(0.85, 0.85, 0.9) * exp(-surfDist * 200.0) * 0.8 * energy;
    }

    // Alpha
    float alpha;
    if (isSplashPeak && energy > 0.01) {
        float thinness = saturate((surfY - uv.y) / max(splashMargin, 0.001));
        alpha = (1.0 - thinness * 0.4) * 0.85 * energy;

        float huePhase = uv.x * 10.0 + uv.y * 6.0 + t * 1.5 + splashDisp * 15.0;
        float3 hueShift = float3(
            sin(huePhase) * 0.5 + 0.5,
            sin(huePhase + 2.094) * 0.5 + 0.5,
            sin(huePhase + 4.189) * 0.5 + 0.5);

        float baseLuma = dot(col, float3(0.299, 0.587, 0.114)) + 0.1;
        col = mix(col, hueShift * baseLuma, thinness * energy * 0.45);
        col = mix(float3(dot(col, float3(0.299, 0.587, 0.114))), col, 1.5);
        col += float3(0.08) * thinness * nearSurface;
    } else {
        float st = smoothstep(0.0, 0.1, surfDist);
        alpha = mix(st * 0.98, smoothstep(0.0, 0.003, surfDist), energy);
    }

    return float4(clamp(col, 0.0, 1.0), alpha);
}
