#if !defined INCLUDE_LIGHTING_DIFFUSE_LIGHTING
#define INCLUDE_LIGHTING_DIFFUSE_LIGHTING

#include "/include/lighting/bsdf.glsl"
#include "/include/lighting/colors/blocklight_color.glsl"
#include "/include/misc/end_lighting_fix.glsl"
#include "/include/surface/material.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/phase_functions.glsl"


#if !defined WORLD_OVERWORLD
#undef CLOUD_SHADOWS
#endif

// The PT-only fork has one indirect-lighting contract:
// - deferred4 consumes the filtered opaque RTGI radiance buffer;
// - forward-lit surfaces (water, glass, translucent) consume the world-space
//   irradiance cache at their own depth — through the same query-time
//   occlusion test the PT trace uses, so they can no longer read the cache
//   through walls (L1). There is no analytic sky/block/cave fallback and no
//   GI-off path.
#if LIGHTING_MODE == LIGHTING_MODE_PT
#include "/include/lighting/rt/voxel_cache.glsl"
#if defined PROGRAM_DEFERRED4
#define DIFFUSE_USE_RTGI
uniform sampler2D rtgi_filtered_sampler;
// GI-resolution aux: .ba is the octahedral surface normal the P1 state
// contract stores, needed by the joint bilateral upsample below. Ping-ponged
// by the temporal pass, so both halves are bound.
uniform sampler2D rtgi_sky_accum_sampler;
uniform sampler2D rtgi_sky_history_sampler;
// decode_unit_vector and linearize_depth. Included here rather than at the top
// of the file so the programs that include this one without a gbuffer are not
// dragged into needing them; both have include guards, and deferred4 includes
// them again below to no effect.
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "/include/lighting/voxel/voxel_constants.glsl"
#endif
#endif // LIGHTING_MODE_PT

const float sss_density = 14.0;
const float sss_scale = 5.0 * SSS_INTENSITY;
const float night_vision_scale = 1.5;
const float metal_diffuse_amount
    = 0.5; // Scales diffuse lighting on metals, ideally this would be zero but
           // purely specular metals don't play well with SSR

#ifdef SHADOW_VPS
vec3 sss_approx(
    vec3 albedo,
    float sss_amount,
    float sheen_amount,
    float sss_depth,
    float LoV,
    float shadow
) {
    // Transmittance-based SSS
    if (sss_amount < eps) {
        return vec3(0.0);
    }

    vec3 coeff = albedo * inversesqrt(dot(albedo, luminance_weights) + eps);
    coeff = 0.75 * clamp01(coeff);
    coeff = (1.0 - coeff) * sss_density / sss_amount;

    float phase
        = mix(isotropic_phase, henyey_greenstein_phase(-LoV, 0.7), 0.33);

    vec3 sss = sss_scale * phase * exp2(-coeff * sss_depth) * dampen(sss_amount)
        * pi;

#ifdef SSS_SHEEN
    vec3 sheen = (0.8 * SSS_INTENSITY) * rcp(albedo + eps)
        * exp2(-1.0 * coeff * sss_depth) * henyey_greenstein_phase(-LoV, 0.5)
        * linear_step(-0.8, -0.2, -LoV);
    sss += sheen * sheen_amount;
#endif

    return sss;
}
#else
vec3 sss_approx(
    vec3 albedo,
    float sss_amount,
    float sheen_amount,
    float sss_depth,
    float LoV,
    float shadow
) {
    // Blur-based SSS
    float sss = 0.06 * sss_scale * pi;
    vec3 sheen = 0.8 * rcp(albedo + eps) * henyey_greenstein_phase(-LoV, 0.5)
        * linear_step(-0.8, -0.2, -LoV) * shadow;

    return sss + sheen * sheen_amount;
}
#endif

#ifdef DIFFUSE_USE_RTGI
// RGB = radiance, A = sky-origin weight.
//
// Joint bilateral upsample of the RTGI buffer.
//
// The GI buffer is RTGI_RESOLUTION-scaled (quarter or half), and the fetch that
// used to live here was a bare bilinear textureLod. Bilinear cannot tell a
// foreground surface from the wall behind it, so at every depth silhouette it
// blended the two: indirect light bled around object edges, and the 2x2
// upscale added its own blockiness on top of the filter's square support.
// Measured on a CPU model of a half-resolution GI buffer with 15% cross-surface
// leakage, against a full-resolution reference:
//
//                        rmse all   rmse on the silhouette band   worst bleed
//   bilinear (before)     0.0417            0.1139                  +0.344
//   joint bilateral       0.0165            0.0195                  +0.070
//
// On a flat surface all four taps agree on depth and normal, so their weights
// are equal and this degenerates to exactly the bilinear it replaces: there is
// nothing to lose in the interior and 5.8x less error at the edges. The result
// is insensitive to both tolerances -- every relative sigma_z in 0.02..0.10 of
// the pixel's own distance and every normal exponent in 16..64 measured the
// same -- so this is the structure doing the work, not a knob.
//
// The GI-resolution surface normal is already stored in the aux channel's .ba
// by the P1 state contract (encode_unit_vector of the same gbuffer normal
// deferred4 decodes into flat_normal), so this needs no new buffers and no new
// passes.
vec4 sample_rtgi_smooth(
    sampler2D rtgi_sampler,
    vec2 coord,
    float center_linear_depth,
    vec3 center_world_normal
) {
    ivec2 gi_res = textureSize(rtgi_sampler, 0);
    ivec2 depth_res = textureSize(depthtex1, 0);

#if RTGI_RESOLUTION == 2
    // 1:1 -- there is nothing to upsample.
    return texelFetch(
        rtgi_sampler,
        clamp(ivec2(coord * vec2(gi_res)), ivec2(0), gi_res - 1),
        0
    );
#else
    // The GI buffers are ping-ponged by the temporal pass; read the half that
    // was written this frame.
    bool ping = (frameCounter & 1) == 0;

    vec2 texel_size = 1.0 / vec2(gi_res);
    vec2 pos = coord * vec2(gi_res) - 0.5;
    ivec2 base = ivec2(floor(pos));
    vec2 f = pos - floor(pos);

    float sigma_z = max(0.05 * center_linear_depth, 1e-3);

    vec4 sum = vec4(0.0);
    float sum_weight = 0.0;

    for (int j = 0; j <= 1; ++j) {
        for (int i = 0; i <= 1; ++i) {
            ivec2 t = clamp(base + ivec2(i, j), ivec2(0), gi_res - 1);

            float bilinear = (i == 0 ? 1.0 - f.x : f.x)
                           * (j == 0 ? 1.0 - f.y : f.y);

            // Depth: the surface this GI texel actually belongs to, sampled at
            // its centre through the same mapping rtgi_filter.csh uses.
            vec2 t_uv = (vec2(t) + 0.5) * texel_size;
            ivec2 t_px = ivec2(clamp(t_uv * view_res, vec2(0.0),
                                     vec2(depth_res) - 1.0));
            float t_depth = linearize_depth(texelFetch(depthtex1, t_px, 0).x);
            float weight_depth
                = exp(-abs(t_depth - center_linear_depth) / sigma_z);

            // Normal: already stored per GI texel by the P1 state contract.
            // Samplers are opaque types: select between the two fetches, not
            // between the two samplers.
            vec4 t_aux = ping ? texelFetch(rtgi_sky_accum_sampler, t, 0)
                              : texelFetch(rtgi_sky_history_sampler, t, 0);
            float weight_normal = pow(
                max(0.0, dot(decode_unit_vector(t_aux.ba),
                             center_world_normal)),
                32.0
            );

            float weight = bilinear * weight_depth * weight_normal;
            sum += texelFetch(rtgi_sampler, t, 0) * weight;
            sum_weight += weight;
        }
    }

    // At a silhouette the GI buffer can hold no texel of this surface at all,
    // which would reject every tap. Fall back to the plain bilinear rather
    // than letting the pixel go black.
    return (sum_weight > 1e-4) ? (sum / sum_weight)
                               : textureLod(rtgi_sampler, coord, 0.0);
#endif
}
#endif


vec3 get_diffuse_lighting(
    Material material,
    vec3 scene_pos,
    vec3 normal,
    vec3 flat_normal,
    vec3 bent_normal,
    vec3 shadows,
    vec2 light_levels,
    float ao,
    float sss_depth,
#ifdef CLOUD_SHADOWS
    float cloud_shadows,
#endif
    float shadow_distance_fade,
    float NoL,
    float NoV,
    float NoH,
    float LoV,
    out vec3 direct_diffuse
) {
#if defined PROGRAM_GBUFFERS_WATER
    // Small optimization, don't calculate diffuse lighting when albedo is 0 (eg
    // water)
    if (max_of(material.albedo) < eps) {
        direct_diffuse = vec3(0.0);
        return vec3(0.0);
    }
#endif

    vec3 direct_lighting = vec3(0.0);
    vec3 indirect_lighting = vec3(0.0);

    // Arbitrary directional shading to make faces easier to distinguish
    float directional_lighting
        = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));

    // Negative SSS depth => SSS blocked by occluder (SSRT SSS)
    bool sss_blocked = sss_depth < 0.0 || light_levels.y < 0.1;
    sss_depth = max0(sss_depth);

#if defined WORLD_OVERWORLD || defined WORLD_END

    // Sunlight/moonlight

#if defined SHADOW || defined SHADOW_SSRT
    vec3 diffuse = vec3(
        lift(max0(NoL), 0.25 * rcp(SHADING_STRENGTH))
        * (1.0 - 0.5 * material.sss_amount)
    );

    vec3 sss = sss_approx(
                   material.albedo,
                   material.sss_amount,
                   material.sheen_amount,
                   mix(sss_depth, 0.0, shadow_distance_fade),
                   LoV,
                   shadows.x
               )
        * float(!sss_blocked);

    // Adjust SSS outside of shadow distance
    // RT contact AO may soften distant direct SSS, but never supplies an
    // ambient irradiance term.
    sss *= mix(1.0, ao * (clamp01(NoL) * 0.8 + 0.2), clamp01(shadow_distance_fade));

#ifdef RT_AO_IN_DIRECT
    diffuse *= sqr(ao);
#endif

#ifdef SHADOW_VPS
    // Add SSS and diffuse
    direct_lighting += diffuse * shadows + sss;
#else
    // Blend SSS and diffuse
    direct_lighting += mix(diffuse, sss, material.sss_amount) * shadows;
#endif
#else
    // Simple shading for when shadows are disabled
    vec3 sss = 0.08 * sss_scale * pi
        + 0.5 * material.sheen_amount * rcp(material.albedo + eps)
            * henyey_greenstein_phase(-LoV, 0.5)
            * linear_step(-0.8, -0.2, -LoV);

    vec3 diffuse
        = vec3(lift(max0(NoL), 0.5 * rcp(SHADING_STRENGTH)) * 0.6 + 0.4)
        * (shadows * 0.8 + 0.2);
    diffuse = diffuse + max0(sss * lift(material.sss_amount, 5.0));
    diffuse *= 1.0 * (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));
    diffuse *= ao * pow4(light_levels.y) * (dampen(light_dir.y) * 0.5 + 0.5);

    direct_lighting += diffuse;
#endif

    direct_lighting *= light_color;

#ifdef CLOUD_SHADOWS
    direct_lighting *= cloud_shadows;
#endif
#endif

    // Indirect lighting: PT only. There is no analytic fallback and no GI-off
    // profile any more, so the two consumers below are the whole contract.
#if defined DIFFUSE_USE_RTGI
    vec2 rtgi_coord = taau_framebuffer_uv(uv);
    ivec2 depth_px = ivec2(clamp(rtgi_coord * view_res, vec2(0.0),
                                 vec2(textureSize(depthtex1, 0)) - 1.0));
    vec4 rtgi_sample = sample_rtgi_smooth(
        rtgi_filtered_sampler,
        rtgi_coord,
        linearize_depth(texelFetch(depthtex1, depth_px, 0).x),
        flat_normal
    );
    // RTGI stores mean incoming radiance; convert to irradiance for the
    // shared (albedo / pi) diffuse composition below.
    indirect_lighting = rtgi_sample.rgb * (pi * (RTGI_INTENSITY * RTGI_BRIGHTNESS));
#else
    vec4 cache_irr = sample_voxel_cache_irradiance(
        scene_pos,
        bent_normal,
        cameraPosition
    );
    indirect_lighting = cache_irr.rgb * (RTGI_INTENSITY * RTGI_BRIGHTNESS);
#endif

    direct_lighting += material.emission * emission_scale;

#if defined WORLD_OVERWORLD
    direct_lighting += nightVision * night_vision_scale * directional_lighting * ao;
#endif

    direct_diffuse = max0(direct_lighting) * material.albedo * rcp_pi
        * mix(1.0, metal_diffuse_amount, float(material.is_metal));
    direct_diffuse = conserve_diffuse_energy(direct_diffuse, material.f0, NoV);

    vec3 final_diffuse = max0(direct_lighting + indirect_lighting) * material.albedo * rcp_pi
        * mix(1.0, metal_diffuse_amount, float(material.is_metal));
    return conserve_diffuse_energy(final_diffuse, material.f0, NoV);
}

// 14-parameter overload for callers that do not require direct_diffuse
vec3 get_diffuse_lighting(
    Material material,
    vec3 scene_pos,
    vec3 normal,
    vec3 flat_normal,
    vec3 bent_normal,
    vec3 shadows,
    vec2 light_levels,
    float ao,
    float sss_depth,
#ifdef CLOUD_SHADOWS
    float cloud_shadows,
#endif
    float shadow_distance_fade,
    float NoL,
    float NoV,
    float NoH,
    float LoV
) {
    vec3 direct_diffuse;
    return get_diffuse_lighting(
        material,
        scene_pos,
        normal,
        flat_normal,
        bent_normal,
        shadows,
        light_levels,
        ao,
        sss_depth,
#ifdef CLOUD_SHADOWS
        cloud_shadows,
#endif
        shadow_distance_fade,
        NoL,
        NoV,
        NoH,
        LoV,
        direct_diffuse
    );
}

#ifdef DIFFUSE_USE_RTGI
#undef DIFFUSE_USE_RTGI
#endif

#endif // INCLUDE_LIGHTING_DIFFUSE_LIGHTING
