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

// GLASS PARAMS
// bevel 36
// thick 55
// IOR 1.5
// squN 6
// scale 1.1

// ─── Types ───────────────────────────────────────────────────────────

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlassVertex {
    float2 position;
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
    // Shape 3: scroll button circle — metaball with shape2 (mic)
    float4 shape3;
    float  scrollButtonVisible;  // 0 or 1
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
    // Tunable refraction parameters (set from CPU)
    float  ior;             // index of refraction (1.5=glass, 3-4=crystal)
    float  squircleN;       // profile exponent (2=hemisphere, 3=steep)
    float  refractScale;    // displacement multiplier
    // Adaptive material state (set from sampled backdrop luminance)
    float  adaptiveAppearance; // 0=dark material, 1=light material
    float  adaptiveContrast;   // 0=clear, 1=strong range compression
    // Optional GPU-side paint splash field, mapped from capture UV to overlay UV.
    float2 splashCaptureOrigin;
    float2 splashCaptureSize;
    float2 splashOverlayOrigin;
    float2 splashOverlaySize;
    float  splashActive;
    float  splashSurfaceIntensity;
    float  splashSurfaceAge;
};

struct BackdropCompositeUniforms {
    float2 captureOrigin;
    float2 captureSize;
    float2 overlayOrigin;
    float2 overlaySize;
    float  overlayAlpha;
};

// ─── Glass appearance constants ─────────────────────────────────────

constant float CHROMA_SPREAD  = 0.02;   // chromatic aberration (0=none, 0.08=heavy)
constant float TINT_GRAY      = 0.45;   // baseline luminance compression target
constant float TINT_STRENGTH  = 0.04;   // baseline compression before adaptive material
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

// Smooth minimum with sharpness control for metaball blending.
// k = blend radius, power = transition sharpness (higher = sharper near, softer far).
inline float sminSharp(float a, float b, float k, float power) {
    float h = max(k - abs(a - b), 0.0) / k;
    float blend = pow(h, power);
    return min(a, b) - blend * k * 0.25;
}

// ─── Metaball / light bridge constants ─────────────────────────────

constant float METABALL_BLEND_K    = 0.5;
constant float METABALL_SHARPNESS  = 3.0;
constant float BRIDGE_INTENSITY    = 0.4;
constant float BRIDGE_WIDTH_SCALE  = 0.12;
constant float3 BRIDGE_COLOR       = float3(0.7, 0.85, 1.0);

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

vertex VertexOut glassVertex(const device GlassVertex *vertices [[buffer(1)]],
                             uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0, 1);
    out.uv = vertices[vid].uv;
    return out;
}

// ─── Fragment ───────────────────────────────────────────────────────

constant sampler samp(filter::linear, address::clamp_to_edge);

struct SplashSurface {
    float energy;
    float trail;
    float edge;
    float2 normal;
    float3 color;
};

float glassSplashHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float glassSplashNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = glassSplashHash(i);
    float b = glassSplashHash(i + float2(1.0, 0.0));
    float c = glassSplashHash(i + float2(0.0, 1.0));
    float d = glassSplashHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

inline float2 glassSplashOverlayUV(float2 captureUV, constant GlassUniforms& u) {
    float2 windowPoint = u.splashCaptureOrigin + captureUV * u.splashCaptureSize;
    return (windowPoint - u.splashOverlayOrigin) / max(u.splashOverlaySize, float2(1.0));
}

inline float glassSplashRawEnergy(texture2d<float> blobTex, float2 uv) {
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        return 0.0;
    }
    return blobTex.sample(samp, uv).a;
}

inline float4 glassSplashRawSample(texture2d<float> blobTex, float2 uv) {
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        return float4(0.0);
    }
    return blobTex.sample(samp, uv);
}

inline float glassSplashHeightFromEnergy(float energy) {
    return 1.0 - exp(-max(energy, 0.0) * 0.64);
}

inline float glassSplashPaintedSurfaceMask(float4 state) {
    float mass = max(state.a, 0.0);
    if (mass <= 0.001) {
        return 0.0;
    }

    float paintMass = max(max(state.r, state.g), state.b);
    float paintRatio = paintMass / max(mass, 0.001);
    return smoothstep(0.006, 0.026, paintMass)
        * smoothstep(0.010, 0.055, paintRatio);
}

inline float glassSplashCoverageFromHeight(float height) {
    return smoothstep(0.055, 0.30, height);
}

inline float glassSplashPointCoverage(texture2d<float> blobTex, float2 uv) {
    return glassSplashCoverageFromHeight(
        glassSplashHeightFromEnergy(glassSplashRawEnergy(blobTex, uv))
    );
}

inline float glassSplashSoftHeight(texture2d<float> blobTex, float2 uv, float2 smoothStep) {
    float energy = glassSplashRawEnergy(blobTex, uv) * 0.46;
    energy += glassSplashRawEnergy(blobTex, uv - float2(smoothStep.x, 0.0)) * 0.135;
    energy += glassSplashRawEnergy(blobTex, uv + float2(smoothStep.x, 0.0)) * 0.135;
    energy += glassSplashRawEnergy(blobTex, uv - float2(0.0, smoothStep.y)) * 0.135;
    energy += glassSplashRawEnergy(blobTex, uv + float2(0.0, smoothStep.y)) * 0.135;
    return glassSplashHeightFromEnergy(energy);
}

inline float glassSplashSoftCoverage(texture2d<float> blobTex, float2 uv, float2 smoothStep) {
    return glassSplashCoverageFromHeight(glassSplashSoftHeight(blobTex, uv, smoothStep));
}

inline float glassSplashMergedCoverage(
    texture2d<float> blobTex,
    float2 uv,
    float2 smoothStep,
    float2 mergeStep
) {
    float center = glassSplashSoftCoverage(blobTex, uv, smoothStep);
    float l = glassSplashPointCoverage(blobTex, uv - float2(mergeStep.x, 0.0));
    float r = glassSplashPointCoverage(blobTex, uv + float2(mergeStep.x, 0.0));
    float u = glassSplashPointCoverage(blobTex, uv - float2(0.0, mergeStep.y));
    float d = glassSplashPointCoverage(blobTex, uv + float2(0.0, mergeStep.y));
    float nw = glassSplashPointCoverage(blobTex, uv - mergeStep);
    float ne = glassSplashPointCoverage(blobTex, uv + float2(mergeStep.x, -mergeStep.y));
    float sw = glassSplashPointCoverage(blobTex, uv + float2(-mergeStep.x, mergeStep.y));
    float se = glassSplashPointCoverage(blobTex, uv + mergeStep);

    float bridge = max(max(min(l, r), min(u, d)), max(min(nw, se), min(ne, sw)));
    float surround = (l + r + u + d) * 0.18 + (nw + ne + sw + se) * 0.07;
    float tension = saturate(max(bridge * 0.86, surround));
    return saturate(max(center, tension * (1.0 - center * 0.28)));
}

inline SplashSurface glassSampleSplashSurface(
    texture2d<float> blobTex,
    float2 captureUV,
    constant GlassUniforms& u
) {
    SplashSurface surface;
    surface.energy = 0.0;
    surface.trail = 0.0;
    surface.edge = 0.0;
    surface.normal = float2(0.0);
    surface.color = float3(0.0);

    if (u.splashActive < 0.5) {
        return surface;
    }

    float intensity = saturate(u.splashSurfaceIntensity);
    if (intensity <= 0.001) {
        return surface;
    }

    float2 uv = glassSplashOverlayUV(captureUV, u);
    float2 texel = 1.0 / float2(blobTex.get_width(), blobTex.get_height());
    float2 smoothStep = texel * 0.88;

    float4 rawSample = glassSplashRawSample(blobTex, uv) * 0.58;
    rawSample += glassSplashRawSample(blobTex, uv - float2(smoothStep.x, 0.0)) * 0.105;
    rawSample += glassSplashRawSample(blobTex, uv + float2(smoothStep.x, 0.0)) * 0.105;
    rawSample += glassSplashRawSample(blobTex, uv - float2(0.0, smoothStep.y)) * 0.105;
    rawSample += glassSplashRawSample(blobTex, uv + float2(0.0, smoothStep.y)) * 0.105;
    float paintedSource = glassSplashPaintedSurfaceMask(rawSample);
    if (paintedSource <= 0.001) {
        return surface;
    }

    float height = glassSplashHeightFromEnergy(rawSample.a);
    float visibleBody = smoothstep(0.030, 0.24, height);
    surface.energy = visibleBody * intensity * paintedSource;

    float hL = glassSplashSoftHeight(blobTex, uv - float2(smoothStep.x, 0.0), smoothStep);
    float hR = glassSplashSoftHeight(blobTex, uv + float2(smoothStep.x, 0.0), smoothStep);
    float hU = glassSplashSoftHeight(blobTex, uv - float2(0.0, smoothStep.y), smoothStep);
    float hD = glassSplashSoftHeight(blobTex, uv + float2(0.0, smoothStep.y), smoothStep);
    float2 grad = float2(hR - hL, hD - hU);
    float gradLen = length(grad);
    surface.normal = clamp(grad * 9.6, float2(-0.86), float2(0.86));

    float rimBand = smoothstep(0.052, 0.24, height) * (1.0 - smoothstep(0.68, 0.98, height));
    surface.edge = smoothstep(0.007, 0.058, gradLen) * rimBand * intensity * paintedSource;
    surface.trail = smoothstep(0.040, 0.16, height)
        * (1.0 - smoothstep(0.22, 0.58, height))
        * intensity
        * paintedSource;
    surface.edge = max(surface.edge, surface.trail * 0.10 * rimBand);
    surface.color = rawSample.rgb / max(rawSample.a, 0.001);

    return surface;
}

inline float4 glassSamplePaintSplashBlob(texture2d<float> blobTex, float2 uv) {
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        return float4(0.0);
    }

    float4 blob = blobTex.sample(samp, uv);
    float energy = blob.a;
    if (energy < 0.05) {
        return float4(0.0);
    }

    float2 pixelCoord = uv * float2(blobTex.get_width(), blobTex.get_height());
    float n = glassSplashNoise(pixelCoord * 0.04) * 0.06
            + glassSplashNoise(pixelCoord * 0.12) * 0.04;

    float threshold = 0.4;
    float edge = smoothstep(threshold - 0.06 + n, threshold + 0.02 + n, energy);
    if (edge < 0.01) {
        return float4(0.0);
    }

    float3 baseColor = blob.rgb / max(energy, 0.001);
    float2 texelSize = 1.0 / float2(blobTex.get_width(), blobTex.get_height());
    float eL = blobTex.sample(samp, uv + float2(-texelSize.x, 0.0)).a;
    float eR = blobTex.sample(samp, uv + float2( texelSize.x, 0.0)).a;
    float eU = blobTex.sample(samp, uv + float2(0.0, -texelSize.y)).a;
    float eD = blobTex.sample(samp, uv + float2(0.0,  texelSize.y)).a;

    float3 normal = normalize(float3((eL - eR) * 2.0, (eU - eD) * 2.0, 0.15));
    float3 lightDir = normalize(float3(0.3, -0.5, 1.0));
    float diffuse = max(dot(normal, lightDir), 0.0) * 0.2 + 0.8;
    float3 halfVec = normalize(lightDir + float3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(normal, halfVec), 0.0), 32.0);

    float3 finalColor = baseColor * diffuse + spec * 0.3;
    float alpha = edge * 0.95;
    return float4(finalColor, alpha);
}

fragment float4 glassBackdropCompositeFragment(
    VertexOut in [[stage_in]],
    constant BackdropCompositeUniforms& u [[buffer(0)]],
    texture2d<float> sourceTex [[texture(0)]],
    texture2d<float> splashBlobTex [[texture(1)]]
) {
    float2 uv = in.uv;
    float4 base = sourceTex.sample(samp, uv);

    float2 windowPoint = u.captureOrigin + uv * u.captureSize;
    float2 overlayUV = (windowPoint - u.overlayOrigin) / max(u.overlaySize, float2(1.0));
    float4 splash = glassSamplePaintSplashBlob(splashBlobTex, overlayUV);

    float alpha = saturate(splash.a * u.overlayAlpha);
    float3 color = mix(base.rgb, splash.rgb, alpha);
    return float4(color, max(base.a, alpha));
}

fragment float4 glassFragment(
    VertexOut in [[stage_in]],
    constant GlassUniforms& u [[buffer(0)]],
    texture2d<float> clearTex [[texture(0)]],
    texture2d<float> blurTex  [[texture(1)]],
    texture2d<float> splashBlobTex [[texture(2)]]
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

    // Shape 2: circle (mic)
    float sdf2 = 10000.0;
    float2 p2 = float2(0.0);
    float s2radius = 0.0;
    if (shapeCount >= 3) {
        float2 s2center = float2(u.shape2.x * aspect, u.shape2.y);
        s2radius = u.shape2.z;
        p2 = p - s2center;
        sdf2 = sdCircle(p2, s2radius);
    }

    // Shape 3: scroll button (circle) — metaball with shape2 (mic)
    float sdf3 = 10000.0;
    float2 p3 = float2(0.0);
    float s3radius = 0.0;
    if (u.scrollButtonVisible > 0.5) {
        float2 s3center = float2(u.shape3.x * aspect, u.shape3.y);
        s3radius = u.shape3.z;
        p3 = p - s3center;
        sdf3 = sdCircle(p3, s3radius);
    }

    // Chrome
    float chromeSdf = chromeMetaballField(p, aspect, u);

    // Combined SDF: mic + scroll blend via sminSharp, rest via min
    float sdfMicScroll;
    if (u.scrollButtonVisible > 0.5) {
        float blendK = METABALL_BLEND_K * s0size.y;
        sdfMicScroll = sminSharp(sdf2, sdf3, blendK, METABALL_SHARPNESS);
    } else {
        sdfMicScroll = sdf2;
    }
    float sdf = min(sdf0, min(sdf1, sdfMicScroll));

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

        if (sdf3 < sdf0 && sdf3 < sdf1 && sdf3 < sdf2) {
            localSdf = sdf3;
            edgeNormal = length(p3) > 1e-5 ? normalize(p3) : float2(0.0);
        } else if (sdf1 < sdf0 && sdf1 < sdf2 && sdf1 < sdf3) {
            localSdf = sdf1;
            edgeNormal = length(p1) > 1e-5 ? normalize(p1) : float2(0.0);
        } else if (sdf2 < sdf0 && sdf2 < sdf1 && sdf2 < sdf3) {
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
        float slope = squircleSlope(normDist, u.squircleN);

        // Snell's law: slope → physically bounded lateral displacement
        float eta    = 1.0 / u.ior;
        float s2     = slope * slope;
        float invL   = rsqrt(1.0 + s2);
        float cosI   = invL;
        float sinI   = slope * invL;
        float cosT   = sqrt(max(1.0 - eta * eta * sinI * sinI, 0.0));
        float T_lat  = sinI * (cosT - eta * cosI);

        // Direction: SDF gradient → UV space (NOT normalized).
        // The 1/aspect factor compensates for non-square capture frame,
        // ensuring equal physical displacement on horizontal and vertical edges.
        float2 refractDir = float2(edgeNormal.x / aspect, edgeNormal.y);

        // offset = direction × deflection × glass_thickness × scale
        float2 offset = refractDir * T_lat * u.glassThickness * u.refractScale;

        // ── 3. Sample with chromatic aberration ──
        //  Apple model: blur FIRST (uniform frosted glass), then refract.
        //  Base = blurTex with refraction offset (frosted + displaced).
        //  On bevel, mix in clearTex for sharper refraction detail.

        SplashSurface splashSurface = glassSampleSplashSurface(splashBlobTex, uv, u);
        float wetEnergy = saturate(max(splashSurface.energy, splashSurface.trail * 0.72));
        float dropThickness = pow(wetEnergy, 0.74);
        float wetRipple = (dropThickness * 0.82 + splashSurface.edge * 0.20)
            * smoothstep(0.0, 0.18, distFromEdge);
        offset += splashSurface.normal * wetRipple * u.glassThickness * 0.58;

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

        if (wetEnergy > 0.001) {
            float3 clearWet = decodeHDR(clearTex.sample(samp, uvG).rgb, u.isHDR);
            col = mix(col, clearWet, saturate(wetEnergy * 0.26 + splashSurface.trail * 0.10));

            float3 rawPaint = clamp(splashSurface.color, 0.0, 1.0);
            float paintLuma = dot(rawPaint, float3(0.299, 0.587, 0.114));
            float3 paintColor = clamp(mix(float3(paintLuma), rawPaint, 1.42), 0.0, 1.0);
            float body = saturate(splashSurface.energy * 0.95 + splashSurface.trail * 0.42);
            float absorption = saturate(body * 0.54 + splashSurface.edge * 0.035);
            float3 transmission = mix(float3(1.0), paintColor, 0.58);
            float3 coloredGlass = col * transmission + paintColor * (0.12 + body * 0.18);
            col = mix(col, coloredGlass, absorption);

            float surfaceClock = u.time + u.splashSurfaceAge;
            float surfaceNoise = glassSplashNoise(float2(uv.x * 130.0, uv.y * 42.0 + surfaceClock * 0.8));
            float thinStream = smoothstep(0.70, 1.0, surfaceNoise) * splashSurface.trail;
            float contactShadow = splashSurface.edge * 0.10 + thinStream * 0.045;
            col *= 1.0 - contactShadow;

            float3 dropNormal = normalize(float3(-splashSurface.normal.x * 0.62,
                                                 -splashSurface.normal.y * 0.88,
                                                  1.0));
            float3 dropLight = normalize(float3(-0.32, -0.62, 1.0));
            float primarySpec = pow(saturate(dot(dropNormal, dropLight)), 28.0)
                * splashSurface.edge * 0.82;
            float wetSheen = pow(saturate(dot(dropNormal, normalize(float3(0.20, -0.46, 1.0)))), 46.0)
                * wetEnergy * 0.08;
            col += mix(float3(0.90, 0.95, 1.0), paintColor, 0.10) * (primarySpec + wetSheen) * 0.42;
            col += paintColor * (thinStream * 0.10 + splashSurface.energy * 0.13 + splashSurface.edge * 0.08);
        }

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

        // ── 6. Adaptive material — smooth light/dark glass state ──
        //
        // GlassService samples the already-captured backdrop and sends a
        // temporally-smoothed state. Keep the math local to luma/chroma so
        // the material still picks up background color instead of becoming
        // a flat overlay.

        float appearance = saturate(u.adaptiveAppearance);
        float contrast = saturate(u.adaptiveContrast);
        float adaptiveTarget = mix(0.18, 0.82, appearance);
        float adaptiveStrength = mix(0.16, 0.38, contrast);

        luma = dot(col, float3(0.299, 0.587, 0.114));
        chroma = col - luma;
        float adaptiveLuma = mix(luma, adaptiveTarget, adaptiveStrength);
        float chromaKeep = mix(0.90, 0.68, contrast);
        col = clamp(float3(adaptiveLuma) + chroma * chromaKeep, 0.0, 1.0);

        // ── 7. Glass luminance boost — state-aware lift/dim ──

        float preLuma = dot(col, float3(0.299, 0.587, 0.114));
        col += float3(0.034) * appearance * (1.0 - smoothstep(0.0, 0.12, preLuma));
        col *= mix(0.92, 1.10, appearance);
        float boostLuma = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(boostLuma), col, 1.08);  // slight saturation push

        // ── 8. Fresnel rim — thin bright edge ──

        float fresnelZone = saturate(distFromEdge / (bw * 0.15));
        float fresnel = pow(1.0 - fresnelZone, 4.0);
        float lightDir = saturate((-edgeNormal.x - edgeNormal.y) * 0.5 + 0.5);
        col += float3(1.0, 1.0, 1.02) * fresnel * mix(0.02, 0.08, lightDir);

        if (wetEnergy > 0.001) {
            float rimWet = fresnel * wetEnergy + splashSurface.edge * 0.12;
            float3 rimPaint = clamp(splashSurface.color, 0.0, 1.0);
            col += mix(float3(0.75, 0.86, 1.0), rimPaint, 0.48) * rimWet * 0.10;
        }

        // ── 9. Inner shadow ──

        float shadowZone = smoothstep(0.0, bw * 0.12, distFromEdge);
        float shadowSide = saturate((edgeNormal.x + edgeNormal.y) * 0.5 + 0.5);
        col *= 1.0 - (1.0 - shadowZone) * shadowSide * 0.08;

        // ── 10. Border line ──

        float bInner = bw * 0.02;
        float bOuter = BORDER_WIDTH * bw;
        float borderMask = smoothstep(bInner, bInner + bOuter * 0.3, distFromEdge)
                         * (1.0 - smoothstep(bInner + bOuter * 0.3, bInner + bOuter, distFromEdge));
        float bBright = BORDER_BRIGHTNESS * mix(0.05, 0.5, lightDir);
        float refLuma = dot(col, float3(0.299, 0.587, 0.114));
        float3 borderCol = mix(float3(1.0), clamp(mix(float3(refLuma), col, 1.5), 0.0, 1.0),
                               BORDER_COLOR_MIX);
        col += borderCol * borderMask * bBright;

        // ── 11. Light bridge: mic ↔ scroll button ──

        if (u.scrollButtonVisible > 0.5) {
            float bridgeWidth = BRIDGE_WIDTH_SCALE * s0size.y;
            float scrollMicGap = sdf3 + sdf2;
            float bridgeZone = smoothstep(bridgeWidth, 0.0, scrollMicGap);
            float inBetween = smoothstep(-bridgeWidth * 0.5, 0.0, sdf3)
                            * smoothstep(-bridgeWidth * 0.5, 0.0, sdf2);
            float bridgeIntensity = bridgeZone * inBetween * BRIDGE_INTENSITY;
            col += BRIDGE_COLOR * bridgeIntensity;
        }

        // ── 12. Final tint ──

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
