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
    float4 previousLinkState;
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

inline float2 rotate2(float2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
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

inline float chainLinkSDF(
    float2 p,
    float2 center,
    float2 halfSize,
    float cornerRadius,
    float thickness,
    float angle
) {
    float2 local = rotate2(p - center, -angle);
    float outer = sdRoundedRect(local, halfSize, cornerRadius);
    float2 innerHalfSize = max(halfSize - float2(thickness, thickness), float2(thickness));
    float inner = sdRoundedRect(local, innerHalfSize, max(cornerRadius - thickness, thickness * 0.45));
    return max(outer, -inner);
}

inline float chainLinkDash(float2 p, float2 center, float2 halfSize, float angle, float time, float seed) {
    float2 local = rotate2(p - center, -angle) / max(halfSize, float2(0.0001));
    float angleAround = atan2(local.y, local.x);
    float phase = fract((angleAround + M_PI_F) / (2.0 * M_PI_F) * 10.0 - time * 0.16 + seed);
    return smoothstep(0.04, 0.11, phase) * (1.0 - smoothstep(0.48, 0.56, phase));
}

inline float chainLinkSheen(float2 p, float2 center, float2 halfSize, float angle, float time) {
    float2 local = rotate2(p - center, -angle) / max(halfSize, float2(0.0001));
    float sweep = dot(local, normalize(float2(-0.72, -0.42))) + 0.18 * sin(time * 0.58);
    float edgeFavor = smoothstep(0.12, 0.86, length(local));
    return gaussianCentered(sweep, -0.14, 0.16) * edgeFavor;
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

inline float2 ghostPathEnergy(CurveSample curve, float time, float seed) {
    float line = gaussian(curve.distance, 0.0065);
    float aura = gaussian(curve.distance, 0.026);
    float dashPhase = fract(curve.t * 12.5 - 0.06);
    float dash = smoothstep(0.025, 0.085, dashPhase)
        * (1.0 - smoothstep(0.43, 0.50, dashPhase));
    float gate = smoothstep(0.025, 0.13, curve.t) * (1.0 - smoothstep(0.88, 0.99, curve.t));

    float cycle = fract(time * 0.34 + seed);
    float attempt = sin(cycle * M_PI_F);
    float reach = 0.09 + 0.52 * pow(max(attempt, 0.0), 0.86);
    float packet = gaussianCentered(curve.t, reach, 0.030 + 0.016 * attempt)
        * gaussian(curve.distance, 0.010);
    float sourcePulse = gaussianCentered(curve.t, 0.055, 0.052)
        * gaussian(curve.distance, 0.014)
        * (0.36 + 0.64 * (1.0 - attempt));
    float wakeStart = max(0.03, reach - 0.20);
    float wake = smoothstep(0.025, reach, curve.t)
        * (1.0 - smoothstep(wakeStart, reach, curve.t))
        * gaussian(curve.distance, 0.012)
        * 0.36
        * attempt;

    float dashedPath = (line * 0.38 + aura * 0.075) * dash * gate;
    float pull = (packet * 1.32 + sourcePulse * 0.46 + wake) * gate;
    return float2(dashedPath, pull);
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
    float transitionProgress = clamp(u.appearance.z, 0.0, 1.0);
    float transition = transitionProgress * transitionProgress * (3.0 - 2.0 * transitionProgress);
    float px = 1.0 / max(resolution.y, 1.0);
    float2 axis = float2(aspect, 1.0);

    float2 groupCenter = float2(0.285, 0.52);
    float2 spaceCenter = float2(0.715, 0.52);
    float radius = 0.148;

    float4 state = mix(u.previousLinkState, u.linkState, transition);
    float4 stateDelta = u.linkState - u.previousLinkState;
    float hasSpaceSide = state.x;
    float hasRoomSide = state.y;
    float canEditSpaceSide = state.z;
    float canEditRoomSide = state.w;
    float readySpaceSide = (1.0 - hasSpaceSide) * canEditSpaceSide;
    float readyRoomSide = (1.0 - hasRoomSide) * canEditRoomSide;
    float fullyLinked = hasSpaceSide * hasRoomSide;
    float anyLink = max(hasSpaceSide, hasRoomSide);
    float editableMissing = max(readySpaceSide, readyRoomSide);

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
    float transitionEnvelope = sin(transitionProgress * M_PI_F);
    float spaceChanging = abs(stateDelta.x);
    float roomChanging = abs(stateDelta.y);
    float spaceAdding = step(0.0, stateDelta.x);
    float roomAdding = step(0.0, stateDelta.y);
    float spaceFrontT = mix(1.0 - transition, transition, spaceAdding);
    float roomFrontT = mix(1.0 - transition, transition, roomAdding);
    float spaceTransitionWave = gaussianCentered(spaceToGroup.t, spaceFrontT, 0.044)
        * gaussian(spaceToGroup.distance, 0.013)
        * spaceChanging
        * transitionEnvelope;
    float roomTransitionWave = gaussianCentered(groupToSpace.t, roomFrontT, 0.044)
        * gaussian(groupToSpace.distance, 0.013)
        * roomChanging
        * transitionEnvelope;

    color += spaceColor * spaceFlow;
    color += roomColor * roomFlow;
    color += (spaceColor + roomColor) * bridgeBloom * 0.5;
    color += linkedColor * fullyLinked * linkedPulse * (
        gaussian(spaceToGroup.distance, 0.017) + gaussian(groupToSpace.distance, 0.017)
    ) * 0.45;
    color += spaceColor * spaceTransitionWave * (1.10 + 0.35 * spaceAdding);
    color += roomColor * roomTransitionWave * (1.10 + 0.35 * roomAdding);
    alpha += max(
        max(max(spaceFlow, roomFlow), bridgeBloom),
        max(spaceTransitionWave, roomTransitionWave) * 0.95
    );

    float2 ghostSpace = ghostPathEnergy(spaceToGroup, time, 0.19) * readySpaceSide;
    float2 ghostRoom = ghostPathEnergy(groupToSpace, time, 0.61) * readyRoomSide;
    float ghostSpaceEnergy = ghostSpace.x * 0.55 + ghostSpace.y * 1.35;
    float ghostRoomEnergy = ghostRoom.x * 0.55 + ghostRoom.y * 1.35;
    color += spaceColor * ghostSpaceEnergy;
    color += roomColor * ghostRoomEnergy;
    alpha += max(ghostSpaceEnergy, ghostRoomEnergy) * 0.82;

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
    float2 shadowOffset = float2(0.0, 0.020);
    float groupShadowSDF = length(groupLocal - shadowOffset) - radius * 1.02;
    float spaceShadowSDF = sdRoundedRect(
        spaceLocal - shadowOffset,
        spaceHalfSize * 1.03,
        spaceCornerRadius * 1.15
    );
    float groupShadow = 1.0 - smoothstep(-0.018, 0.062, groupShadowSDF);
    float spaceShadow = 1.0 - smoothstep(-0.018, 0.062, spaceShadowSDF);
    float shadow = max(groupShadow, spaceShadow);
    float3 shadowColor = darkMode > 0.5 ? float3(0.0, 0.0, 0.0) : float3(0.04, 0.055, 0.085);
    color += shadowColor * shadow * (darkMode > 0.5 ? 0.18 : 0.12);
    alpha += shadow * (darkMode > 0.5 ? 0.18 : 0.12);

    float groupLift = gaussianCentered(groupSDF, 20.0 * px, 17.0 * px);
    float spaceLift = gaussianCentered(spaceSDF, 20.0 * px, 17.0 * px);
    color += (roomColor * groupLift + spaceColor * spaceLift) * (0.08 + 0.09 * editableMissing);
    alpha += max(groupLift, spaceLift) * (0.07 + 0.06 * editableMissing);

    float2 nexusCenter = float2(0.5 * aspect, 0.52);
    float2 nexusLocal = p - nexusCenter;
    float nexusDistance = length(nexusLocal);
    float nodePulse = 0.62 + 0.38 * sin(time * 2.2 + anyLink * 1.7);
    float centerCharge = transitionEnvelope * max(spaceChanging, roomChanging);
    float oneSided = max(anyLink - fullyLinked, 0.0);
    float linkAngle = -0.72;
    float2 linkAxis = normalize(float2(cos(linkAngle), sin(linkAngle)));
    float2 linkNormal = float2(-linkAxis.y, linkAxis.x);
    float linkClosure = clamp(fullyLinked + anyLink * 0.44 + editableMissing * 0.36, 0.0, 1.0);
    float linkSeparation = 0.018 * (1.0 - linkClosure);
    float2 linkHalfSize = float2(0.056, 0.029);
    float linkCornerRadius = linkHalfSize.y;
    float linkThickness = 0.011;
    float2 roomLinkCenter = nexusCenter - linkAxis * (0.031 + linkSeparation);
    float2 spaceLinkCenter = nexusCenter + linkAxis * (0.031 + linkSeparation);
    float roomLinkSDF = chainLinkSDF(
        p,
        roomLinkCenter,
        linkHalfSize,
        linkCornerRadius,
        linkThickness,
        linkAngle
    );
    float spaceLinkSDF = chainLinkSDF(
        p,
        spaceLinkCenter,
        linkHalfSize,
        linkCornerRadius,
        linkThickness,
        linkAngle
    );
    float roomLinkCore = 1.0 - smoothstep(-1.0 * px, 2.2 * px, roomLinkSDF);
    float spaceLinkCore = 1.0 - smoothstep(-1.0 * px, 2.2 * px, spaceLinkSDF);
    float roomLinkGlow = gaussian(roomLinkSDF, 0.018);
    float spaceLinkGlow = gaussian(spaceLinkSDF, 0.018);
    float roomLinkDash = chainLinkDash(p, roomLinkCenter, linkHalfSize, linkAngle, time, 0.18);
    float spaceLinkDash = chainLinkDash(p, spaceLinkCenter, linkHalfSize, linkAngle, time, 0.57);
    float roomLinkSheen = chainLinkSheen(p, roomLinkCenter, linkHalfSize, linkAngle, time);
    float spaceLinkSheen = chainLinkSheen(p, spaceLinkCenter, linkHalfSize, linkAngle, time + 0.43);
    float linkIntersection = roomLinkCore * spaceLinkCore;
    float crossingRelief = linkIntersection * fullyLinked;
    float axisCoord = dot(nexusLocal, linkAxis);
    float crossingCoord = dot(nexusLocal, linkNormal);
    float gapWindow = gaussian(axisCoord, 0.050) * fullyLinked;
    float roomGap = gaussianCentered(crossingCoord, 0.018, 0.012) * gapWindow;
    float spaceGap = gaussianCentered(crossingCoord, -0.018, 0.012) * gapWindow;
    float roomCut = clamp(roomGap * 1.45, 0.0, 1.0);
    float spaceCut = clamp(spaceGap * 1.45, 0.0, 1.0);
    float roomKeep = 1.0 - roomCut;
    float spaceKeep = 1.0 - spaceCut;
    roomLinkCore *= roomKeep;
    spaceLinkCore *= spaceKeep;
    roomLinkGlow *= 1.0 - roomCut * 0.98;
    spaceLinkGlow *= 1.0 - spaceCut * 0.98;
    roomLinkSheen *= roomKeep;
    spaceLinkSheen *= spaceKeep;

    float roomLinkActive = hasRoomSide;
    float spaceLinkActive = hasSpaceSide;
    float roomLinkGhost = (1.0 - hasRoomSide) * (readyRoomSide + (1.0 - canEditRoomSide) * 0.20);
    float spaceLinkGhost = (1.0 - hasSpaceSide) * (readySpaceSide + (1.0 - canEditSpaceSide) * 0.20);
    float roomGhostCore = roomLinkCore * roomLinkDash * roomLinkGhost;
    float spaceGhostCore = spaceLinkCore * spaceLinkDash * spaceLinkGhost;
    float roomActiveCore = roomLinkCore * roomLinkActive;
    float spaceActiveCore = spaceLinkCore * spaceLinkActive;
    float roomAttemptGlow = roomLinkGlow * roomLinkGhost * (0.18 + 0.18 * nodePulse);
    float spaceAttemptGlow = spaceLinkGlow * spaceLinkGhost * (0.18 + 0.18 * nodePulse);
    float roomSolidGlow = roomLinkGlow * roomLinkActive * (0.19 + 0.12 * linkedPulse);
    float spaceSolidGlow = spaceLinkGlow * spaceLinkActive * (0.19 + 0.12 * linkedPulse);
    float roomVisibleCore = roomActiveCore;
    float spaceVisibleCore = spaceActiveCore;
    float roomVisibleGlow = roomSolidGlow;
    float spaceVisibleGlow = spaceSolidGlow;
    float weaveShadow = max(roomCut, spaceCut) * gapWindow;
    float centerSpark = gaussian(nexusDistance, 0.021) * (fullyLinked * 0.14 + centerCharge * 0.70 + oneSided * 0.24);
    float disconnectedGap = gaussian(abs(dot(nexusLocal, linkAxis)), 0.010)
        * gaussian(dot(nexusLocal, float2(-linkAxis.y, linkAxis.x)), 0.022)
        * (1.0 - anyLink)
        * (0.25 + 0.35 * editableMissing);
    float3 nodeGlowColor = mix(float3(0.10, 0.12, 0.18), float3(0.76, 0.92, 1.0), 1.0 - darkMode);
    float nodeGlow = gaussian(nexusDistance, 0.086)
        * (0.07 + anyLink * 0.10 + editableMissing * 0.10 + fullyLinked * 0.11 + centerCharge * 0.18);

    color += nodeGlowColor * nodeGlow;
    color += roomColor * (roomVisibleGlow * 0.52 + roomVisibleCore * (0.58 + roomLinkSheen * 0.28));
    color += spaceColor * (spaceVisibleGlow * 0.52 + spaceVisibleCore * (0.58 + spaceLinkSheen * 0.28));
    color += metalLight * (roomVisibleCore * roomLinkSheen + spaceVisibleCore * spaceLinkSheen) * 0.12;
    color += roomColor * (roomGhostCore * (0.30 + 0.18 * nodePulse) + roomAttemptGlow);
    color += spaceColor * (spaceGhostCore * (0.30 + 0.18 * nodePulse) + spaceAttemptGlow);
    color += linkedColor * linkIntersection * fullyLinked * 0.035;
    color += linkedColor * centerSpark * 0.36;
    color -= nodeGlowColor * weaveShadow * 0.44;
    color += metalLight * crossingRelief * fullyLinked * 0.020;
    color -= nodeGlowColor * disconnectedGap * 0.20;
    alpha += max(
        max(nodeGlow, max(roomVisibleCore, spaceVisibleCore)),
        max(max(roomGhostCore, spaceGhostCore) * 0.74, centerSpark * 0.72)
    );
    alpha = max(alpha, weaveShadow * 0.48);

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
    color += (spaceColor + roomColor + linkedColor) * centerNexus * 0.055;
    alpha += centerNexus * 0.12;

    alpha = clamp(alpha, 0.0, 1.0);
    color = clamp(color, 0.0, 1.35);
    return float4(color, alpha);
}
