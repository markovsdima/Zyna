//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#include <metal_stdlib>
using namespace metal;

struct RoomSpaceLinkHeroVertex {
    float2 position;
    float2 uv;
};

struct RoomSpaceLinkHeroVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct RoomSpaceLinkHeroUniforms {
    float4 resolutionTimeScale;
    float4 linkState;
    float4 appearance;
};

struct CurveSample {
    float distance;
    float t;
};

constant sampler avatarSampler(filter::linear, address::clamp_to_edge);

vertex RoomSpaceLinkHeroVertexOut roomSpaceLinkHeroVertex(
    const device RoomSpaceLinkHeroVertex *vertices [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    RoomSpaceLinkHeroVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.uv = vertices[vid].uv;
    return out;
}

inline float hash11(float value) {
    return fract(sin(value * 127.1) * 43758.5453123);
}

inline float gaussian(float x, float width) {
    float v = x / max(width, 0.0001);
    return exp(-v * v);
}

inline float gaussianCentered(float x, float center, float width) {
    return gaussian(x - center, width);
}

inline float sdRoundedRect(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

inline float segmentDistance(float2 p, float2 a, float2 b, thread float *segmentT) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 0.00001), 0.0, 1.0);
    *segmentT = t;
    return length(p - (a + ab * t));
}

inline CurveSample quadraticCurveDistance(float2 p, float2 a, float2 b, float2 c) {
    float bestDistance = 1000.0;
    float bestT = 0.0;
    float2 previous = a;

    for (int i = 1; i <= 44; i++) {
        float t1 = float(i) / 44.0;
        float inv = 1.0 - t1;
        float2 current = inv * inv * a + 2.0 * inv * t1 * b + t1 * t1 * c;
        float localT = 0.0;
        float d = segmentDistance(p, previous, current, &localT);
        if (d < bestDistance) {
            bestDistance = d;
            bestT = (float(i - 1) + localT) / 44.0;
        }
        previous = current;
    }

    CurveSample sample;
    sample.distance = bestDistance;
    sample.t = bestT;
    return sample;
}

inline float angularDifference(float angle, float center) {
    return atan2(sin(angle - center), cos(angle - center));
}

inline float metallicBand(float sdf, float radius, float angle, float time, float px) {
    float rim = gaussian(sdf, 2.4 * px);
    float outer = gaussianCentered(sdf, 7.0 * px, 5.2 * px);
    float inner = gaussianCentered(sdf, -6.0 * px, 4.8 * px);
    float sweep = 0.52 + 0.48 * sin(angle * 2.0 - time * 0.85);
    float glint = pow(max(0.0, sin(angle + time * 1.55)), 18.0);
    float broad = 0.5 + 0.5 * sin(angle * 3.0 + time * 0.33);
    return rim * (0.72 + 0.28 * sweep)
        + outer * (0.44 + 0.18 * broad)
        + inner * 0.28
        + glint * gaussianCentered(sdf, 2.0 * px, 4.0 * px) * radius;
}

inline float movingBeads(float t, float time, float speed, float density, float seed) {
    float lane = fract(t * density - time * speed + seed);
    float bead = gaussianCentered(lane, 0.20, 0.045)
        + gaussianCentered(lane, 0.58, 0.030) * 0.65;
    float gate = smoothstep(0.08, 0.22, t) * (1.0 - smoothstep(0.78, 0.98, t));
    return bead * gate;
}

inline float curveEnergy(CurveSample curve, float width, float time, float speed, float seed) {
    float core = gaussian(curve.distance, width);
    float aura = gaussian(curve.distance, width * 3.6) * 0.28;
    float bead = movingBeads(curve.t, time, speed, 5.6, seed);
    float wave = 0.64 + 0.36 * sin(curve.t * M_PI_F * 5.0 - time * speed * 5.0 + seed * 8.0);
    return core * (0.5 + bead * 1.35 + wave * 0.18) + aura;
}

inline float orbitEnergy(
    float2 local,
    float radius,
    float time,
    float facingAngle,
    float seed,
    float px
) {
    float d = length(local);
    float angle = atan2(local.y, local.x);
    float ring = gaussianCentered(d, radius + 14.0 * px, 7.5 * px);
    float outer = gaussianCentered(d, radius + 28.0 * px, 15.0 * px) * 0.25;
    float facing = gaussian(angularDifference(angle, facingAngle), 0.82);
    float orbit = sin(angle * 5.0 - time * 2.7 + seed * 3.0);
    float cometAngle = time * 1.45 + seed * 2.2;
    float comet = gaussian(angularDifference(angle, cometAngle), 0.18)
        * gaussianCentered(d, radius + 18.0 * px, 5.0 * px);
    return (ring * (0.38 + 0.42 * facing + 0.20 * orbit) + outer + comet * 1.35);
}

inline float roundedRectOrbitEnergy(
    float2 local,
    float2 halfSize,
    float cornerRadius,
    float time,
    float facingAngle,
    float seed,
    float px
) {
    float sdf = sdRoundedRect(local, halfSize, cornerRadius);
    float angle = atan2(local.y, local.x);
    float ring = gaussianCentered(sdf, 14.0 * px, 7.5 * px);
    float outer = gaussianCentered(sdf, 28.0 * px, 15.0 * px) * 0.25;
    float facing = gaussian(angularDifference(angle, facingAngle), 0.82);
    float orbit = sin(angle * 5.0 - time * 2.7 + seed * 3.0);
    float cometAngle = time * 1.45 + seed * 2.2;
    float comet = gaussian(angularDifference(angle, cometAngle), 0.18)
        * gaussianCentered(sdf, 18.0 * px, 5.0 * px);
    return ring * (0.38 + 0.42 * facing + 0.20 * orbit) + outer + comet * 1.35;
}

inline float4 sampleMedallion(
    texture2d<float> avatarTexture,
    float2 uv,
    float2 center,
    float radius,
    float2 axis,
    bool roundedSquare,
    float time,
    float px
) {
    float2 local = (uv - center) * axis;
    float sdf;
    float2 sampleUV;

    if (roundedSquare) {
        float2 halfSize = float2(radius * 0.93, radius * 0.93);
        sdf = sdRoundedRect(local, halfSize, radius * 0.10);
        sampleUV = local / (halfSize * 2.0) + 0.5;
    } else {
        sdf = length(local) - radius;
        sampleUV = local / (radius * 2.0) + 0.5;
    }

    float mask = 1.0 - smoothstep(-1.0 * px, 1.7 * px, sdf);
    float4 avatar = avatarTexture.sample(avatarSampler, clamp(sampleUV, 0.0, 1.0));
    float angle = atan2(local.y, local.x);
    float light = 0.92 + 0.10 * (local.y / max(radius, 0.001)) + 0.08 * sin(angle * 2.0 + time * 0.45);
    float3 color = avatar.rgb * light;

    float shade = smoothstep(radius * 0.80, radius * 0.08, length(local));
    color *= 0.86 + shade * 0.18;
    return float4(color, mask * avatar.a);
}

fragment float4 roomSpaceLinkHeroFragment(
    RoomSpaceLinkHeroVertexOut in [[stage_in]],
    constant RoomSpaceLinkHeroUniforms& u [[buffer(0)]],
    texture2d<float> groupTexture [[texture(0)]],
    texture2d<float> spaceTexture [[texture(1)]]
) {
    float2 uv = in.uv;
    float2 resolution = max(u.resolutionTimeScale.xy, float2(1.0));
    float aspect = resolution.x / max(resolution.y, 1.0);
    float time = u.appearance.y > 0.5 ? 0.0 : u.resolutionTimeScale.z;
    float darkMode = u.appearance.x;
    float px = 1.0 / max(resolution.y, 1.0);
    float2 axis = float2(aspect, 1.0);

    float2 groupCenter = float2(0.285, 0.52);
    float2 spaceCenter = float2(0.715, 0.52);
    float radius = 0.148;

    float hasSpaceSide = u.linkState.x;
    float hasRoomSide = u.linkState.y;
    float canEditSpaceSide = u.linkState.z;
    float canEditRoomSide = u.linkState.w;
    float readySpaceSide = (1.0 - hasSpaceSide) * canEditSpaceSide;
    float readyRoomSide = (1.0 - hasRoomSide) * canEditRoomSide;
    float fullyLinked = hasSpaceSide * hasRoomSide;

    float2 p = uv * axis;
    float2 group = groupCenter * axis;
    float2 space = spaceCenter * axis;
    float2 upperControl = float2(0.50 * aspect, 0.245);
    float2 lowerControl = float2(0.50 * aspect, 0.795);

    CurveSample spaceToGroup = quadraticCurveDistance(p, space, upperControl, group);
    CurveSample groupToSpace = quadraticCurveDistance(p, group, lowerControl, space);

    float3 spaceColor = float3(0.08, 0.88, 1.00);
    float3 roomColor = float3(0.80, 0.28, 1.00);
    float3 linkedColor = float3(0.68, 0.96, 1.00);
    float3 metalLight = darkMode > 0.5 ? float3(0.88, 0.93, 1.0) : float3(0.42, 0.46, 0.54);
    float3 metalDark = darkMode > 0.5 ? float3(0.12, 0.15, 0.20) : float3(0.82, 0.86, 0.92);

    float3 color = float3(0.0);
    float alpha = 0.0;

    float broadBackdrop = gaussian(spaceToGroup.distance, 0.060) * hasSpaceSide
        + gaussian(groupToSpace.distance, 0.060) * hasRoomSide;
    float radialVignette = 1.0 - smoothstep(0.34, 0.74, distance(uv, float2(0.5, 0.52)));
    float backdrop = max(broadBackdrop * 0.18, radialVignette * 0.10);
    color += mix(float3(0.08, 0.12, 0.20), float3(0.78, 0.88, 1.0), 1.0 - darkMode) * backdrop;
    alpha += backdrop;

    float linkedPulse = 0.70 + 0.30 * sin(time * 2.1);
    float spaceFlow = curveEnergy(spaceToGroup, 0.0085, time, 0.46, 0.13) * hasSpaceSide;
    float roomFlow = curveEnergy(groupToSpace, 0.0085, time, 0.54, 0.57) * hasRoomSide;
    float bridgeBloom = (gaussian(spaceToGroup.distance, 0.028) * hasSpaceSide
        + gaussian(groupToSpace.distance, 0.028) * hasRoomSide) * 0.22;

    color += spaceColor * spaceFlow;
    color += roomColor * roomFlow;
    color += (spaceColor + roomColor) * bridgeBloom * 0.5;
    color += linkedColor * fullyLinked * linkedPulse * (
        gaussian(spaceToGroup.distance, 0.017) + gaussian(groupToSpace.distance, 0.017)
    ) * 0.45;
    alpha += max(max(spaceFlow, roomFlow), bridgeBloom);

    float2 groupLocal = (uv - groupCenter) * axis;
    float2 spaceLocal = (uv - spaceCenter) * axis;
    float2 spaceHalfSize = float2(radius * 0.90, radius * 0.90);
    float spaceCornerRadius = radius * 0.20;
    float readyGroup = orbitEnergy(groupLocal, radius, time, 0.0, 0.3, px) * readyRoomSide;
    float readySpace = roundedRectOrbitEnergy(
        spaceLocal,
        spaceHalfSize,
        spaceCornerRadius,
        time,
        M_PI_F,
        0.7,
        px
    ) * readySpaceSide;
    float linkedGroupOrbit = orbitEnergy(groupLocal, radius, time, 0.0, 1.1, px) * fullyLinked * 0.55;
    float linkedSpaceOrbit = roundedRectOrbitEnergy(
        spaceLocal,
        spaceHalfSize,
        spaceCornerRadius,
        time,
        M_PI_F,
        1.5,
        px
    ) * fullyLinked * 0.55;

    color += roomColor * readyGroup;
    color += spaceColor * readySpace;
    color += (roomColor * 0.52 + linkedColor * 0.48) * linkedGroupOrbit;
    color += (spaceColor * 0.56 + linkedColor * 0.44) * linkedSpaceOrbit;
    alpha += max(max(readyGroup, readySpace), max(linkedGroupOrbit, linkedSpaceOrbit));

    float groupSDF = length(groupLocal) - radius;
    float spaceSDF = sdRoundedRect(spaceLocal, spaceHalfSize, spaceCornerRadius);
    float groupAngle = atan2(groupLocal.y, groupLocal.x);
    float spaceAngle = atan2(spaceLocal.y, spaceLocal.x);
    float groupMetal = metallicBand(groupSDF, 1.0, groupAngle, time, px);
    float spaceMetal = metallicBand(spaceSDF, 1.0, spaceAngle + 0.8, time, px);

    float3 groupMetalColor = mix(metalDark, metalLight, clamp(groupMetal * 0.8, 0.0, 1.0));
    float3 spaceMetalColor = mix(metalDark, metalLight, clamp(spaceMetal * 0.8, 0.0, 1.0));
    float groupMetalAlpha = min(groupMetal, 1.0);
    float spaceMetalAlpha = min(spaceMetal, 1.0);
    color = mix(color, groupMetalColor + roomColor * readyRoomSide * 0.25, groupMetalAlpha);
    color = mix(color, spaceMetalColor + spaceColor * readySpaceSide * 0.25, spaceMetalAlpha);
    alpha = max(alpha, max(groupMetalAlpha, spaceMetalAlpha));

    float4 groupAvatar = sampleMedallion(groupTexture, uv, groupCenter, radius - 7.0 * px, axis, false, time, px);
    float4 spaceAvatar = sampleMedallion(spaceTexture, uv, spaceCenter, radius - 9.0 * px, axis, true, time, px);
    color = mix(color, groupAvatar.rgb, groupAvatar.a);
    alpha = max(alpha, groupAvatar.a);
    color = mix(color, spaceAvatar.rgb, spaceAvatar.a);
    alpha = max(alpha, spaceAvatar.a);

    float centerNexus = gaussian(distance(uv * axis, float2(0.5 * aspect, 0.52)), 0.040)
        * max(fullyLinked, max(hasSpaceSide, hasRoomSide) * 0.45);
    color += (spaceColor + roomColor + linkedColor) * centerNexus * 0.16;
    alpha += centerNexus * 0.36;

    float grain = hash11(floor(uv.x * resolution.x * 0.33) + floor(uv.y * resolution.y * 0.33) * 91.7);
    color += (grain - 0.5) * 0.018 * alpha;

    alpha = clamp(alpha, 0.0, 1.0);
    color = clamp(color, 0.0, 1.35);
    return float4(color, alpha);
}
