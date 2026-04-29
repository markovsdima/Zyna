//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#include <metal_stdlib>
using namespace metal;

struct ChatPeekLensVertex {
    float2 position;
    float2 uv;
};

struct ChatPeekLensVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct ChatPeekLensUniforms {
    float2 resolution;
    float2 viewSize;
    float4 cardRect;
    float cornerRadius;
    float progress;
    float time;
    float impulse;
    float4 effectParams;
};

constant sampler lensSampler(filter::linear, address::clamp_to_edge);

vertex ChatPeekLensVertexOut chatPeekLensVertex(
    const device ChatPeekLensVertex *vertices [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    ChatPeekLensVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.uv = vertices[vid].uv;
    return out;
}

inline float sdRoundedRect(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

inline float2 roundedRectNormal(float2 p, float2 halfSize, float radius) {
    float2 signP = select(float2(1.0), float2(-1.0), p < 0.0);
    float2 ap = abs(p);
    float2 q = ap - halfSize + radius;
    float2 outside = max(q, 0.0);
    float outsideLen = length(outside);

    float2 n;
    if (q.x > 0.0 && q.y > 0.0) {
        n = outside / max(outsideLen, 0.0001);
    } else if (q.x > q.y) {
        n = float2(1.0, 0.0);
    } else {
        n = float2(0.0, 1.0);
    }
    return normalize(n * signP);
}

inline float gaussian(float x, float width) {
    float v = x / max(width, 0.0001);
    return exp(-v * v);
}

inline float gaussianCentered(float x, float center, float width) {
    float v = (x - center) / max(width, 0.0001);
    return exp(-v * v);
}

inline float angularGaussian(float angle, float center, float width) {
    float delta = atan2(sin(angle - center), cos(angle - center));
    return gaussian(delta, width);
}

inline float hash11(float value) {
    return fract(sin(value * 127.1) * 43758.5453123);
}

inline float particleLayerShaped(
    float theta,
    float outsidePx,
    float time,
    float seed,
    float cellCount,
    float speed,
    float radialStart,
    float radialSpan,
    float radialWidth,
    float angularScale
) {
    float stream = fract(theta + time * (0.010 + seed * 0.002));
    float cellPosition = stream * cellCount;
    float cell = floor(cellPosition);
    float local = fract(cellPosition);
    float rndA = hash11(cell + seed * 31.7);
    float rndB = hash11(cell + seed * 53.1);
    float rndC = hash11(cell + seed * 79.9);

    float center = 0.22 + rndA * 0.56;
    float angular = gaussian(local - center, (0.034 + rndB * 0.026) * angularScale);
    float travel = fract(time * speed + rndA + seed * 0.37);
    float radial = radialStart + travel * radialSpan + rndB * 8.0;
    float fade = smoothstep(0.02, 0.18, travel) * (1.0 - smoothstep(0.58, 1.0, travel));
    float active = smoothstep(0.34, 0.78, rndC);

    return angular * gaussianCentered(outsidePx, radial, radialWidth + rndB * 1.6) * fade * active;
}

inline float particleLayer(
    float theta,
    float outsidePx,
    float time,
    float seed,
    float cellCount,
    float speed,
    float radialStart,
    float radialSpan,
    float radialWidth
) {
    return particleLayerShaped(
        theta,
        outsidePx,
        time,
        seed,
        cellCount,
        speed,
        radialStart,
        radialSpan,
        radialWidth,
        1.0
    );
}

inline float3 sampleLensTexture(texture2d<float> texture, float2 uv) {
    return texture.sample(lensSampler, clamp(uv, 0.0, 1.0)).rgb;
}

fragment float4 chatPeekLensFragment(
    ChatPeekLensVertexOut in [[stage_in]],
    constant ChatPeekLensUniforms& u [[buffer(0)]],
    texture2d<float> sourceTexture [[texture(0)]]
) {
    float2 uv = in.uv;
    float aspect = u.viewSize.x / max(u.viewSize.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y);

    float2 cardOrigin = u.cardRect.xy;
    float2 cardSize = u.cardRect.zw;
    float2 cardCenter = cardOrigin + cardSize * 0.5;
    float2 cardCenterP = float2(cardCenter.x * aspect, cardCenter.y);
    float2 halfSize = float2(cardSize.x * aspect * 0.5, cardSize.y * 0.5);
    float cornerRadius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
    float2 local = p - cardCenterP;
    float sdf = sdRoundedRect(local, halfSize, cornerRadius);
    float2 normalP = roundedRectNormal(local, halfSize, cornerRadius);
    float2 normalUv = normalize(float2(normalP.x / aspect, normalP.y));
    float2 tangentUv = float2(-normalUv.y, normalUv.x);

    float px = 1.0 / max(u.resolution.y, 1.0);
    float progress = smoothstep(0.0, 1.0, u.progress);
    float distanceFromRim = abs(sdf);
    float outsideDistance = max(sdf, 0.0);

    float horizon = gaussian(distanceFromRim, 30.0 * px);
    float rim = gaussian(distanceFromRim, 52.0 * px);
    float lensRing = gaussianCentered(outsideDistance, 74.0 * px, 64.0 * px);
    float outerRing = gaussianCentered(outsideDistance, 142.0 * px, 72.0 * px);
    float release = gaussianCentered(outsideDistance, 178.0 * px, 62.0 * px);
    float influence = 1.0 - smoothstep(0.0, 260.0 * px, distanceFromRim);
    float angle = atan2(local.y, local.x);
    float impulse = u.impulse;
    float theta = fract(angle / (2.0 * M_PI_F) + 0.5);
    float outsidePx = outsideDistance / max(px, 0.00001);
    float outsideMask = smoothstep(2.0, 12.0, outsidePx) * (1.0 - smoothstep(190.0, 270.0, outsidePx));
    float particleCore =
        particleLayer(theta, outsidePx, u.time, 1.0, 92.0, 0.18, 4.0, 104.0, 1.6) * 1.02 +
        particleLayer(theta, outsidePx, u.time, 2.0, 68.0, 0.12, 10.0, 146.0, 2.1) * 0.76 +
        particleLayer(theta, outsidePx, u.time, 3.0, 118.0, 0.24, 2.0, 74.0, 1.1) * 0.66 +
        particleLayer(theta, outsidePx, u.time, 4.0, 44.0, 0.085, 20.0, 176.0, 2.6) * 0.54;
    float particleGlow =
        particleLayer(theta, outsidePx, u.time, 5.0, 62.0, 0.16, 0.0, 132.0, 4.8) * 0.50 +
        particleLayer(theta, outsidePx, u.time, 6.0, 38.0, 0.10, 18.0, 190.0, 7.0) * 0.34;
    float particles = (particleCore + particleGlow) * outsideMask * progress;
    float particleWarp =
        particleLayerShaped(theta, outsidePx, u.time, 1.0, 92.0, 0.18, 4.0, 104.0, 6.4, 7.5) * 0.90 +
        particleLayerShaped(theta, outsidePx, u.time, 2.0, 68.0, 0.12, 10.0, 146.0, 8.2, 8.5) * 0.72 +
        particleLayerShaped(theta, outsidePx, u.time, 3.0, 118.0, 0.24, 2.0, 74.0, 5.2, 6.5) * 0.58 +
        particleLayerShaped(theta, outsidePx, u.time, 4.0, 44.0, 0.085, 20.0, 176.0, 10.0, 9.0) * 0.48;
    float particleLens = clamp(particleCore * 0.65 + particleGlow * 0.20 + particleWarp * 1.30, 0.0, 2.35)
        * outsideMask;

    float normalPx =
        54.0 * horizon +
        34.0 * lensRing +
        18.0 * outerRing * impulse -
        12.0 * release +
        24.0 * particleLens;
    float tangentPx =
        6.0 * lensRing * sin(angle * 2.0 + u.time * 0.8) +
        3.5 * outerRing * sin(angle * 4.0 + 0.35) * impulse +
        38.0 * particleLens * sin(angle * 6.0 + outsidePx * 0.035 + u.time * 1.6);

    float2 offset =
        normalUv * normalPx * px * influence * progress +
        tangentUv * tangentPx * px * influence * progress;

    float chroma = 2.4 * px * (rim + lensRing * 0.6) * progress;
    float2 redUv = uv + offset + normalUv * chroma;
    float2 greenUv = uv + offset;
    float2 blueUv = uv + offset - normalUv * chroma;

    float3 color;
    color.r = sampleLensTexture(sourceTexture, redUv).r;
    color.g = sampleLensTexture(sourceTexture, greenUv).g;
    color.b = sampleLensTexture(sourceTexture, blueUv).b;

    float darkRimStrength = u.effectParams.x;
    float darkRim = (0.40 * horizon + 0.13 * lensRing + 0.05 * outerRing)
        * darkRimStrength
        * progress;
    color *= (1.0 - clamp(darkRim, 0.0, 0.68));

    float3 warmDisk = float3(1.0, 0.72, 0.34);
    float3 coldEdge = float3(0.46, 0.68, 1.0);

    float arcNoise =
        (0.50 + 0.50 * sin(angle * 5.3 + u.time * 0.18)) *
        (0.55 + 0.45 * sin(angle * 13.0 - u.time * 0.31)) +
        0.18 * sin(angle * 29.0 + 1.7);
    float brokenArc = smoothstep(0.23, 0.74, arcNoise);
    float heroTop = angularGaussian(angle, -1.52, 1.05);
    float heroBottom = angularGaussian(angle, 1.38, 0.76) * 0.28;
    float heroSide = angularGaussian(angle, -0.10, 0.42) * 0.16;
    float arcEnvelope = clamp(heroTop * 0.72 + heroBottom + heroSide, 0.0, 1.0);
    float chaoticArc = arcEnvelope * brokenArc;
    float softBand = gaussianCentered(outsideDistance, 70.0 * px, 13.0 * px) * chaoticArc;
    float wideBloom = gaussianCentered(outsideDistance, 88.0 * px, 31.0 * px) * chaoticArc;

    float horizontalDisk = pow(abs(cos(angle)), 2.55);
    float upperBend = pow(max(-sin(angle), 0.0), 0.46);
    float lowerBend = pow(max(sin(angle), 0.0), 0.64);
    float causticBias = 0.22 + horizontalDisk * 0.82 + upperBend * 0.46 + lowerBend * 0.18;
    float causticA = gaussianCentered(outsideDistance, 39.0 * px, 3.8 * px)
        * smoothstep(0.76, 1.0, sin(angle * 9.0 + u.time * 0.26 + 0.45));
    float causticB = gaussianCentered(outsideDistance, 61.0 * px, 3.0 * px)
        * smoothstep(0.78, 1.0, sin(angle * 14.0 - u.time * 0.34 - 1.8));
    float causticC = gaussianCentered(outsideDistance, 96.0 * px, 5.2 * px)
        * smoothstep(0.80, 1.0, sin(angle * 18.0 + u.time * 0.22 + 2.35));
    float causticD = gaussianCentered(outsideDistance, 137.0 * px, 7.0 * px)
        * smoothstep(0.84, 1.0, sin(angle * 23.0 - u.time * 0.18 - 0.65));
    float caustics = (causticA * 0.82 + causticB + causticC * 0.68 + causticD * 0.42)
        * causticBias
        * progress;

    float photonBreaks = smoothstep(0.79, 1.0, sin(angle * 12.0 + u.time * 0.19 + 0.6))
        + 0.42 * smoothstep(0.88, 1.0, sin(angle * 21.0 - u.time * 0.27 - 1.1));
    float photonRing = gaussianCentered(distanceFromRim, 14.0 * px, 3.5 * px)
        * clamp(photonBreaks, 0.0, 1.0)
        * progress;

    float3 arcColor = mix(warmDisk, coldEdge, smoothstep(0.16, 0.96, heroTop));
    color += arcColor * softBand * 0.24 * progress;
    color += warmDisk * wideBloom * 0.08 * progress;
    color += mix(warmDisk, coldEdge, smoothstep(-0.35, 0.85, sin(angle + 0.45)))
        * caustics
        * 0.25;
    color += float3(1.0, 0.91, 0.72) * photonRing * 0.18;

    float hue = u.time * 1.9 + angle * 2.6 + outsidePx * 0.021;
    float3 iridescent = 0.52 + 0.48 * cos(float3(0.0, 2.1, 4.2) + hue);
    float3 particleColor = mix(float3(1.0, 0.82, 0.54), iridescent, 0.64);
    color += particleColor * particles * 0.58;
    color += iridescent * pow(clamp(particles, 0.0, 1.0), 1.45) * 0.34;

    float sweep = gaussianCentered(
        fract((angle / (2.0 * M_PI_F)) + u.time * 0.42),
        0.5,
        0.045
    ) * lensRing * impulse;
    color += float3(1.0, 0.86, 0.56) * sweep * 0.18 * progress;

    float settleGlow = outerRing * impulse * 0.035 * progress;
    color += float3(0.72, 0.82, 1.0) * settleGlow;

    return float4(color, 1.0);
}
