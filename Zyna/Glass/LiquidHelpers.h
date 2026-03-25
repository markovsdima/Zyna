//
//  LiquidHelpers.h
//  Zyna
//
//  Procedural noise, surface waves, and caustics for liquid pool effect.
//

#ifndef LiquidHelpers_h
#define LiquidHelpers_h

#include <metal_stdlib>
using namespace metal;

// ─── Procedural noise ────────────────────────────────────────────────

inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

inline float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.0 + float2(100.0);
        a *= 0.5;
    }
    return v;
}

// ─── Surface wave ────────────────────────────────────────────────────

inline float surfaceWave(float x, float time, float energy) {
    if (energy < 0.001) return 0.0;
    float wave = sin(x * 3.0  + time * 1.2) * 0.035
               + sin(x * 7.0  - time * 1.8) * 0.020
               + sin(x * 13.0 + time * 2.5) * 0.010
               + (fbm(float2(x * 5.0, time * 0.6)) - 0.5) * 0.025;
    return energy * wave;
}

// ─── Caustics ────────────────────────────────────────────────────────

inline float caustic(float2 p, float time) {
    float2 p1 = p * 3.5 + float2(time * 0.25, time * 0.18);
    float2 p2 = p * 5.5 - float2(time * 0.15, time * 0.3);
    float c = abs(sin(p1.x + sin(p1.y * 1.3)))
            + abs(sin(p2.y + cos(p2.x * 1.1)));
    return pow(c * 0.5, 4.0);
}

inline float causticBrightness(float depth, float2 uv, float time, float energy) {
    float causticAnim = time * energy + time * 0.05;
    float c = caustic(uv * 8.0, causticAnim);
    float fade = exp(-depth * 5.0);
    return c * fade;
}

// ─── Smooth minimum ─────────────────────────────────────────────────
// Polynomial smooth-min for organic SDF merging (T-1000 liquid metal joints)

inline float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

#endif
