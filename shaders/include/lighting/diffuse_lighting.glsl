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

// RT Mode has one indirect-lighting contract:
// - deferred4 consumes the filtered opaque RTGI radiance buffer;
// - forward-lit surfaces consume the world-space irradiance probe cache.
// There is no analytic sky/block/cave fallback.
#include "/include/lighting/rt/ddgi.glsl"
#if defined PROGRAM_DEFERRED4
#define DIFFUSE_USE_RTGI
uniform sampler2D rtgi_filtered_sampler;
#include "/include/lighting/voxel/voxel_constants.glsl"
#endif

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
// RGB = radiance, A = sky-origin weight
vec4 sample_rtgi_smooth(sampler2D rtgi_sampler, vec2 coord) {
    return textureLod(rtgi_sampler, coord, 0.0);
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

    // Indirect lighting: RT only.
#ifdef DIFFUSE_USE_RTGI
    vec2 rtgi_coord = taau_framebuffer_uv(uv);
    vec4 rtgi_sample = sample_rtgi_smooth(rtgi_filtered_sampler, rtgi_coord);
    // RTGI stores mean incoming radiance; convert to irradiance for the
    // shared (albedo / pi) diffuse composition below.
    indirect_lighting = rtgi_sample.rgb * (pi * (RTGI_INTENSITY * RTGI_BRIGHTNESS));
#else
    vec3 world_pos = scene_pos + cameraPosition;
    vec4 probe_irr = sample_ddgi_irradiance(
        world_pos + bent_normal * 0.15,
        bent_normal,
        cameraPosition
    );
    indirect_lighting = probe_irr.rgb * (RTGI_INTENSITY * RTGI_BRIGHTNESS);
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
