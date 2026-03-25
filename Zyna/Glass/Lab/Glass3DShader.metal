//
//  3D Ray-traced glass — physically correct refraction through a glass volume.
//  Ray enters top surface, refracts (Snell's law), traverses glass, exits bottom surface.
//  Geometry defines the visual effect: lens = magnify, prism = rainbow, drop = caustics.
//
//  Experimental — separate from production GlassShader.metal.
//

#include <metal_stdlib>
using namespace metal;

// ─── Types ───────────────────────────────────────────────────────────

struct Glass3DVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Glass3DUniforms {
    float2 resolution;       // drawable size in pixels
    float  aspect;           // width / height

    // Glass shape rect (normalized 0..1 in capture coords)
    float4 shapeRect;        // x, y, w, h
    float  cornerRadius;     // normalized by height

    // 3D glass parameters
    float  ior;              // index of refraction (glass=1.5, water=1.33, diamond=2.42)
    float  thickness;        // glass thickness in normalized units
    float  curvatureTop;     // top surface curvature (-1=concave, 0=flat, 1=convex)
    float  curvatureBottom;  // bottom surface curvature
    float  edgeRound;        // how much the edges curve (0=sharp, 1=smooth dome)

    // Visual
    float  chromaticSpread;  // chromatic aberration (dispersion)
    float  tintStrength;     // glass tint amount
    float  tintGray;         // tint target gray
    float  fresnelPow;       // fresnel reflection exponent
    float  time;             // animation time
};

// ─── Constants ───────────────────────────────────────────────────────

constant float BORDER_WIDTH_3D = 0.06;
constant float BORDER_BRIGHTNESS_3D = 0.7;

// ─── SDF ─────────────────────────────────────────────────────────────

inline float sdRoundedRect3D(float2 p, float2 halfSize, float r) {
    float2 d = abs(p) - halfSize + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// ─── Glass surface height functions ──────────────────────────────────
// These define the 3D shape of the glass surfaces.
// Returns height above the base plane at a given point inside the glass shape.

// Normalized distance from edge: 0 = at edge, 1 = deep center
inline float normDistFromEdge(float sdf, float maxDist) {
    return clamp(-sdf / maxDist, 0.0, 1.0);
}

// Surface height profile — curvature controls the shape:
//   curvature > 0: convex (dome/lens, thicker in center)
//   curvature = 0: flat
//   curvature < 0: concave (bowl, thinner in center)
//   edgeRound: how smooth the edge transition is
inline float surfaceHeight(float normDist, float curvature, float edgeRound, float thickness) {
    // Edge profile: smooth ramp from 0 at edge to 1 at center
    float edge = smoothstep(0.0, edgeRound + 0.001, normDist);

    // Curvature profile: parabolic dome/bowl
    float profile = curvature * (1.0 - (1.0 - normDist) * (1.0 - normDist));

    return (edge + profile) * thickness * 0.5;
}

// Surface normal from height field (finite differences)
inline float3 surfaceNormal(
    float2 p, float2 halfSize, float cr,
    float curvature, float edgeRound, float thickness, float maxDist
) {
    float eps = 0.002;
    float sdf_c = sdRoundedRect3D(p, halfSize, cr);
    float sdf_x = sdRoundedRect3D(p + float2(eps, 0), halfSize, cr);
    float sdf_y = sdRoundedRect3D(p + float2(0, eps), halfSize, cr);

    float nd_c = normDistFromEdge(sdf_c, maxDist);
    float nd_x = normDistFromEdge(sdf_x, maxDist);
    float nd_y = normDistFromEdge(sdf_y, maxDist);

    float h_c = surfaceHeight(nd_c, curvature, edgeRound, thickness);
    float h_x = surfaceHeight(nd_x, curvature, edgeRound, thickness);
    float h_y = surfaceHeight(nd_y, curvature, edgeRound, thickness);

    float3 n = float3(-(h_x - h_c) / eps, -(h_y - h_c) / eps, 1.0);
    return normalize(n);
}

// ─── Vertex ──────────────────────────────────────────────────────────

vertex Glass3DVertexOut glass3DVertex(uint vid [[vertex_id]]) {
    float2 pos[4] = {
        float2(-1, -1), float2(1, -1),
        float2(-1,  1), float2(1,  1)
    };
    float2 uvs[4] = {
        float2(0, 1), float2(1, 1),
        float2(0, 0), float2(1, 0)
    };
    Glass3DVertexOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

// ─── Fragment ────────────────────────────────────────────────────────

constant sampler samp3D(filter::linear, address::clamp_to_edge);

fragment float4 glass3DFragment(
    Glass3DVertexOut in [[stage_in]],
    constant Glass3DUniforms& u [[buffer(0)]],
    texture2d<float> bgTex [[texture(0)]]
) {
    float2 uv = in.uv;
    float aspect = u.aspect;
    float2 p = float2(uv.x * aspect, uv.y);

    // Glass shape in aspect-corrected space
    float2 shapeOrigin = float2(u.shapeRect.x * aspect, u.shapeRect.y);
    float2 shapeSize = float2(u.shapeRect.z * aspect, u.shapeRect.w);
    float2 shapeCenter = shapeOrigin + shapeSize * 0.5;
    float2 halfSize = shapeSize * 0.5;
    float cr = u.cornerRadius;

    // SDF to glass edge
    float2 local = p - shapeCenter;
    float sdf = sdRoundedRect3D(local, halfSize, cr);

    // Outside glass — pass through
    if (sdf > 0.0) {
        return bgTex.sample(samp3D, uv);
    }

    // ── Inside glass — ray trace through volume ──

    float maxDist = min(halfSize.x, halfSize.y) * 0.5;
    float nd = normDistFromEdge(sdf, maxDist);

    // Top surface normal (where ray enters glass)
    float3 normalTop = surfaceNormal(
        local, halfSize, cr,
        u.curvatureTop, u.edgeRound, u.thickness, maxDist
    );

    // Bottom surface normal (where ray exits glass)
    float3 normalBottom = surfaceNormal(
        local, halfSize, cr,
        u.curvatureBottom, u.edgeRound, u.thickness, maxDist
    );
    normalBottom.z = -normalBottom.z; // bottom surface faces down

    // ── Ray trace ──
    // Incoming ray: straight down (orthographic camera)
    float3 rayDir = float3(0, 0, -1);

    // Refraction at entry (air → glass)
    float eta_enter = 1.0 / u.ior; // air-to-glass ratio
    float3 refractedEntry = refract(rayDir, normalTop, eta_enter);

    // If total internal reflection at entry — shouldn't happen but guard
    if (length(refractedEntry) < 0.001) {
        refractedEntry = rayDir;
    }

    // Traverse glass volume — ray travels through thickness
    float3 exitPoint = float3(local, 0) + refractedEntry * u.thickness;

    // Refraction at exit (glass → air)
    float eta_exit = u.ior; // glass-to-air ratio
    float3 refractedExit = refract(refractedEntry, normalBottom, eta_exit);

    // Total internal reflection at exit — use reflection instead
    if (length(refractedExit) < 0.001) {
        refractedExit = reflect(refractedEntry, normalBottom);
    }

    // Final UV offset from the two refractions
    float2 totalOffset = refractedExit.xy * u.thickness;

    // Scale by resolution for correct pixel displacement
    float refractionScale = u.resolution.y / 800.0; // normalize to reference size
    totalOffset *= refractionScale;

    // ── Chromatic aberration (dispersion) ──
    // Different IOR per wavelength: red < green < blue
    float spread = u.chromaticSpread;
    float2 uvR = uv + totalOffset * (1.0 - spread);
    float2 uvG = uv + totalOffset;
    float2 uvB = uv + totalOffset * (1.0 + spread);

    float r = bgTex.sample(samp3D, uvR).r;
    float g = bgTex.sample(samp3D, uvG).g;
    float b = bgTex.sample(samp3D, uvB).b;
    float3 color = float3(r, g, b);

    // ── Fresnel reflection ──
    float cosTheta = abs(dot(rayDir, normalTop));
    float fresnel = pow(1.0 - cosTheta, u.fresnelPow);
    // Mix in a highlight color (white) at glancing angles
    color = mix(color, float3(1.0), fresnel * 0.3);

    // ── Glass tint ──
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    float3 gray = float3(mix(lum, u.tintGray, 0.5));
    color = mix(color, gray, u.tintStrength * (1.0 - nd * 0.5));

    // ── Soft blur at edges (fake caustics gathering) ──
    float edgeFade = smoothstep(0.0, 0.15, nd);

    // ── Specular highlight from top surface ──
    float3 lightDir = normalize(float3(0.3, -0.5, 1.0));
    float3 halfVec = normalize(lightDir + float3(0, 0, 1));
    float spec = pow(max(dot(normalTop, halfVec), 0.0), 64.0);
    color += spec * 0.15 * edgeFade;

    // ── Edge border ──
    float border = smoothstep(0.0, BORDER_WIDTH_3D, nd);
    float borderGlow = (1.0 - border) * BORDER_BRIGHTNESS_3D;
    color += borderGlow;

    return float4(color, 1.0);
}
