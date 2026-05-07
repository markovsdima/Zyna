#ifndef GLASS_GLYPH_SHADER_H
#define GLASS_GLYPH_SHADER_H

// Included from GlassShader.metal after shared glass helpers.
// Depends on GlassUniforms, samp, sdRoundedRect, sminSharp, glassSplashNoise,
// and decodeHDR from the including translation unit.

inline float glassGlyphMask(texture2d<float> atlasTex, float2 local, float4 sourceRect) {
    if (local.x < 0.0 || local.y < 0.0 || local.x > 1.0 || local.y > 1.0) {
        return 0.0;
    }
    float2 atlasLocal = float2(local.x, 1.0 - local.y);
    float2 atlasUV = sourceRect.xy + atlasLocal * sourceRect.zw;
    return atlasTex.sample(samp, atlasUV).r;
}

inline float2 glassRotate2(float2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

inline float glassGlyphMicRelayRotation(float progress) {
    float q = saturate(progress);
    return smoothstep(0.04, 0.58, q) * 0.36;
}

inline float glassGlyphSendRelayRotation(float progress) {
    float q = saturate(progress);
    return (smoothstep(0.42, 0.98, q) - 1.0) * 0.36;
}

inline float2 glassGlyphLayerLocal(float2 local, float angle) {
    return 0.5 + glassRotate2(local - 0.5, angle);
}

inline float glassSegmentSDF(float2 p, float2 a, float2 b, float r) {
    float2 ab = b - a;
    float h = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-5));
    return length((p - a) - ab * h) - r;
}

inline float glassMicGlyphSDF(float2 p) {
    float body = sdRoundedRect(p - float2(0.0, 0.08), float2(0.145, 0.285), 0.145);
    float stem = glassSegmentSDF(p, float2(0.0, -0.18), float2(0.0, -0.34), 0.045);
    float foot = glassSegmentSDF(p, float2(-0.17, -0.36), float2(0.17, -0.36), 0.045);
    float handle = sminSharp(body, stem, 0.055, 2.8);
    return sminSharp(handle, foot, 0.045, 2.8);
}

inline float glassSendGlyphSDF(float2 p) {
    float stem = glassSegmentSDF(p, float2(0.0, -0.34), float2(0.0, 0.20), 0.052);
    float left = glassSegmentSDF(p, float2(0.0, 0.34), float2(-0.22, 0.12), 0.052);
    float right = glassSegmentSDF(p, float2(0.0, 0.34), float2(0.22, 0.12), 0.052);
    float head = sminSharp(left, right, 0.040, 3.0);
    return sminSharp(stem, head, 0.045, 3.0);
}

inline float glassGlyphProceduralMorphMask(float2 local, float progress, float aa) {
    if (local.x < -0.05 || local.y < -0.05 || local.x > 1.05 || local.y > 1.05) {
        return 0.0;
    }

    float q = smoothstep(0.0, 1.0, saturate(progress));
    float pulse = sin(q * 3.14159265);
    float2 p = float2(local.x - 0.5, 0.5 - local.y);
    float2 materialP = float2(
        p.x / mix(1.0, 0.94, pulse * 0.40),
        p.y / mix(1.0, 1.025, pulse * 0.24)
    );
    float drift = (q - 0.5) * pulse * 0.014;

    float micSdf = glassMicGlyphSDF(materialP + float2(0.0, drift));
    float sendSdf = glassSendGlyphSDF(materialP - float2(0.0, drift));
    float interpolated = mix(micSdf, sendSdf, q);
    float softUnion = sminSharp(micSdf, sendSdf, 0.10, 2.4);
    float body = mix(interpolated, softUnion + 0.014, pulse * 0.18) - pulse * 0.003;
    return 1.0 - smoothstep(-aa, aa, body);
}

inline float glassGlyphMorphMask(
    texture2d<float> atlasTex,
    float2 local,
    constant GlassUniforms& u,
    float micReveal,
    float sendReveal,
    float micScale,
    float sendScale,
    float swirl,
    float progress,
    float morphBlend,
    float aa
) {
    float2 centered = local - 0.5;
    float2 micCentered = glassRotate2(centered, glassGlyphMicRelayRotation(progress));
    float2 sendCentered = glassRotate2(centered, glassGlyphSendRelayRotation(progress));
    float2 micTangent = float2(-micCentered.y, micCentered.x);
    float2 sendTangent = float2(-sendCentered.y, sendCentered.x);
    float2 micLocal = 0.5 + (micCentered + micTangent * swirl) / max(micScale, 0.01);
    float2 sendLocal = 0.5 + (sendCentered - sendTangent * swirl) / max(sendScale, 0.01);
    float micMask = glassGlyphMask(atlasTex, micLocal, u.glyphSource0) * micReveal;
    float sendMask = glassGlyphMask(atlasTex, sendLocal, u.glyphSource1) * sendReveal;
    float atlasMask = max(micMask, sendMask);
    if (morphBlend <= 0.001) {
        return atlasMask;
    }
    float morphMask = glassGlyphProceduralMorphMask(
        glassGlyphLayerLocal(local, glassGlyphSendRelayRotation(progress)),
        progress,
        aa
    );
    return saturate(max(atlasMask, morphMask * morphBlend));
}

inline float3 glassCompositeGlyph(
    float3 baseColor,
    float2 uv,
    constant GlassUniforms& u,
    texture2d<float> glyphAtlasTex,
    texture2d<float> clearTex,
    texture2d<float> blurTex
) {
    if (u.glyphActive < 0.5 || u.glyphOpacity <= 0.001) {
        return baseColor;
    }

    float4 rect = u.glyphRect;
    float4 boundsRect = u.glyphEffectRect;
    if (boundsRect.z <= 0.0 || boundsRect.w <= 0.0) {
        boundsRect = rect;
    }
    if (rect.z <= 0.0 || rect.w <= 0.0 ||
        uv.x < boundsRect.x || uv.y < boundsRect.y ||
        uv.x > boundsRect.x + boundsRect.z || uv.y > boundsRect.y + boundsRect.w) {
        return baseColor;
    }

    float2 local = (uv - rect.xy) / rect.zw;
    float progress = smoothstep(0.0, 1.0, saturate(u.glyphProgress));
    float2 centered = local - 0.5;
    float activity = saturate(u.glyphActivity);

    float transitionPulse = sin(progress * 3.14159265);
    float motionPulse = transitionPulse * (0.45 + activity * 0.55);
    float micScale = 1.0;
    float sendScale = 1.0;
    float swirl = 0.0;
    float2 tangent = float2(-centered.y, centered.x);

    float2 screenStep = float2(1.0) / max(rect.zw * u.resolution, float2(24.0));
    float2 localStep = max(float2(1.0 / 160.0), screenStep * 1.35);
    float aa = max(max(localStep.x, localStep.y) * 0.65, 0.008);

    float2 micCentered = glassRotate2(centered, glassGlyphMicRelayRotation(progress));
    float2 sendCentered = glassRotate2(centered, glassGlyphSendRelayRotation(progress));
    float2 micTangent = float2(-micCentered.y, micCentered.x);
    float2 sendTangent = float2(-sendCentered.y, sendCentered.x);
    float2 micLocal = 0.5 + (micCentered + micTangent * swirl) / max(micScale, 0.01);
    float2 sendLocal = 0.5 + (sendCentered - sendTangent * swirl) / max(sendScale, 0.01);

    float micMask = glassGlyphMask(glyphAtlasTex, micLocal, u.glyphSource0);
    float sendMask = glassGlyphMask(glyphAtlasTex, sendLocal, u.glyphSource1);

    float micReveal = 1.0 - smoothstep(0.08, 0.62, progress);
    float sendReveal = smoothstep(0.38, 0.92, progress);
    if (progress < 0.01) {
        micReveal = 1.0;
        sendReveal = 0.0;
    } else if (progress > 0.99) {
        micReveal = 0.0;
        sendReveal = 1.0;
    }

    float micAlpha = micMask * micReveal;
    float sendAlpha = sendMask * sendReveal;
    float morphBlend = saturate(transitionPulse * 0.15);
    float morphMask = glassGlyphProceduralMorphMask(
        glassGlyphLayerLocal(local, glassGlyphSendRelayRotation(progress)),
        progress,
        aa
    );
    float atlasAlpha = max(micAlpha, sendAlpha);
    float alpha = saturate(max(atlasAlpha, morphMask * morphBlend) * u.glyphOpacity);
    if (alpha <= 0.001) {
        return baseColor;
    }

    float maskL = glassGlyphMorphMask(
        glyphAtlasTex, local - float2(localStep.x, 0.0), u,
        micReveal, sendReveal, micScale, sendScale, swirl, progress, morphBlend, aa);
    float maskR = glassGlyphMorphMask(
        glyphAtlasTex, local + float2(localStep.x, 0.0), u,
        micReveal, sendReveal, micScale, sendScale, swirl, progress, morphBlend, aa);
    float maskU = glassGlyphMorphMask(
        glyphAtlasTex, local - float2(0.0, localStep.y), u,
        micReveal, sendReveal, micScale, sendScale, swirl, progress, morphBlend, aa);
    float maskD = glassGlyphMorphMask(
        glyphAtlasTex, local + float2(0.0, localStep.y), u,
        micReveal, sendReveal, micScale, sendScale, swirl, progress, morphBlend, aa);

    float2 grad = float2(maskR - maskL, maskD - maskU);
    float edge = saturate(length(grad) * 2.4);
    float2 normal = length(grad) > 1e-5 ? normalize(grad) : float2(0.0, -1.0);

    float appearance = saturate(u.adaptiveAppearance);
    float lightMaterial = appearance;
    float neutralWhite = mix(0.95, 0.12, lightMaterial);
    float3 neutralColor = float3(neutralWhite);
    float3 sendColor = clamp(u.glyphSendColor.rgb, 0.0, 1.0);
    float sendInk = smoothstep(0.22, 0.88, progress);
    float3 glyphColor = mix(neutralColor, sendColor, sendInk);

    float2 lightDir = normalize(float2(-0.45, -0.78));
    float edgeLight = pow(saturate(dot(normal, lightDir)), 1.6) * edge;
    float edgeShadow = pow(saturate(dot(normal, -lightDir)), 1.25) * edge;

    float2 radial = length(centered) > 1e-5 ? normalize(centered) : float2(0.0);
    float cutoutDepth = alpha * (0.0015 + edge * mix(0.0036, 0.0054, lightMaterial)
        + motionPulse * 0.0010);
    float2 lensOffset = normal * cutoutDepth
        + radial * alpha * (1.0 - edge) * mix(0.0010, 0.0016, lightMaterial);
    lensOffset += tangent * motionPulse * alpha * mix(0.0005, 0.0008, lightMaterial);

    float2 uvR = clamp(uv - lensOffset * 1.45, 0.0, 1.0);
    float2 uvG = clamp(uv - lensOffset * 1.05, 0.0, 1.0);
    float2 uvB = clamp(uv - lensOffset * 0.68, 0.0, 1.0);
    float3 refrR = decodeHDR(blurTex.sample(samp, uvR).rgb, u.isHDR);
    float3 refrG = decodeHDR(blurTex.sample(samp, uvG).rgb, u.isHDR);
    float3 refrB = decodeHDR(blurTex.sample(samp, uvB).rgb, u.isHDR);
    float3 chromaGlass = float3(refrR.r, refrG.g, refrB.b);

    float2 sharpUV = clamp(uv - lensOffset * 1.85, 0.0, 1.0);
    float3 sharpGlass = decodeHDR(clearTex.sample(samp, sharpUV).rgb, u.isHDR);
    float3 lensGlass = mix(chromaGlass, sharpGlass, saturate(edge * 0.24 + alpha * 0.08));
    float lensAmount = saturate(alpha * (mix(0.22, 0.32, lightMaterial)
        + edge * mix(0.34, 0.46, lightMaterial)
        + motionPulse * 0.045));
    float3 color = mix(baseColor, lensGlass, lensAmount);

    // Pigment is treated as a thin capsule below the refractive surface:
    // backdrop texture still bleeds through, but the glyph keeps a hard
    // minimum readability profile on both light and dark material states.
    float lensLuma = dot(lensGlass, float3(0.299, 0.587, 0.114));
    float3 transmittedPigment = glyphColor * mix(0.82, 1.02, lensLuma)
                              + lensGlass * (0.055 + sendInk * 0.025);
    float3 pigment = mix(glyphColor, transmittedPigment, mix(0.42, 0.32, lightMaterial) + sendInk * 0.18);
    float capsuleAlpha = alpha * mix(0.72, 0.76, lightMaterial);
    capsuleAlpha = mix(capsuleAlpha, alpha * 0.86, sendInk);
    color = mix(color, pigment, capsuleAlpha);

    float shadowStrength = mix(0.15, 0.32, lightMaterial);
    color *= 1.0 - edgeShadow * shadowStrength * (0.65 + 0.35 * alpha);
    color *= 1.0 - edge * alpha * lightMaterial * 0.055;

    float causticNoise = glassSplashNoise(local * 18.0 + float2(u.time * 0.55, u.time * 0.32));
    float caustic = edge * alpha * (mix(0.045, 0.070, lightMaterial) + motionPulse * 0.025)
        * (0.65 + causticNoise * 0.35);
    float3 causticColor = mix(float3(0.92, 0.97, 1.0), sendColor, sendInk * 0.38);
    color += causticColor * caustic;

    color += float3(1.0, 1.0, 1.02) * edgeLight * mix(0.145, 0.185, lightMaterial);
    color += glyphColor * edgeLight * (0.060 + sendInk * 0.075);

    float innerPress = alpha * (1.0 - edge) * mix(0.020, 0.065, lightMaterial);
    color *= 1.0 - innerPress;

    float topSheen = alpha * smoothstep(0.82, 0.10, local.y) * 0.026 * (0.65 + motionPulse * 0.35);
    color += float3(1.0, 1.0, 1.02) * topSheen;
    return clamp(color, 0.0, 1.0);
}

#endif
