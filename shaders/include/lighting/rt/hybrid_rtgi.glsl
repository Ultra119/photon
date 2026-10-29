#if !defined INCLUDE_LIGHTING_RT_HYBRID_RTGI
#define INCLUDE_LIGHTING_RT_HYBRID_RTGI

// global.glsl included by parent program
#include "/include/utility/color.glsl"
#include "/include/utility/geometry.glsl"
#include "voxel_dda.glsl"
#include "ssgi.glsl"
#include "ray_query.glsl"
#include "ddgi.glsl"

#define RTGI_TRACER_VOXEL  0
#define RTGI_TRACER_HYBRID 1

#ifndef RTGI_TRACER
#define RTGI_TRACER RTGI_TRACER_VOXEL
#endif

// Generate cosine-weighted hemisphere direction around normal
vec3 sample_cosine_hemisphere(vec3 normal, vec2 u) {
    float r = sqrt(u.x);
    float phi = 6.28318530718 * u.y; // 2 * pi

    vec3 local_dir = vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.x)));
    mat3 tbn_basis = build_orthonormal_basis(normal);
    return normalize(tbn_basis * local_dir);
}

// Which estimator answered a ray. Written to `hit_source` so that
// DEBUG_VIEW_GI / GI_DEBUG_HIT can show the hybrid split without a second
// code path that could disagree with the real dispatch below.
#define RTGI_HIT_NONE  0
#define RTGI_HIT_SSGI  1
#define RTGI_HIT_VOXEL 2
#define RTGI_HIT_SKY   3

// Evaluate single hybrid RTGI sample. RGB is radiance; A is the estimated
// fraction of that radiance that originated from sun/sky rather than from
// emissive blocks or block light.
//
// `hit_source` is an out parameter rather than a separate diagnostic function:
// duplicating the dispatch to report on it would let the diagnostic drift out
// of sync with the thing it is supposed to describe.
vec4 evaluate_hybrid_rtgi_ray(
    vec3 screen_pos,
    vec3 view_pos,
    vec3 view_normal,
    vec3 scene_pos,
    vec3 world_normal,
    vec3 ray_dir_world,
    float dither,
    usampler3D voxel_grid,
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    sampler2D scene_color_sampler,
    sampler2D gbuffer0_sampler,
    vec3 direct_sun_color,
    vec3 sky_ambient_color,
    vec3 l_dir,
    float surface_skylight,
    sampler2D depth_translucent_sampler,
    out int hit_source
) {
    vec3 ray_dir_view = mat3(gbufferModelView) * ray_dir_world;
    hit_source = RTGI_HIT_NONE;

    // 1. Evaluate 3D Voxel DDA (handles occluded objects, off-screen surroundings, ceilings)
    const float max_voxel_dist = voxel_distance;
    VoxelHit vx_hit = trace_voxel_dda(
        voxel_grid,
        shadow_tex,
        shadow_mv,
        shadow_proj,
        scene_pos,
        world_normal,
        ray_dir_world,
        dither,
        direct_sun_color,
        sky_ambient_color,
        l_dir,
        max_voxel_dist
    );

    // 2. Evaluate sky ambient fallback (attenuated by stained glass transmittance)
    float sky_hemi = clamp01(ray_dir_world.y * 0.5 + 0.5);
    vec3 sky_radiance = sky_ambient_color
        * (sky_hemi * sqr(surface_skylight))
        * vx_hit.transmittance;
    vec3 total_sky_radiance = sky_radiance + vx_hit.accumulated_light;
    float sky_lum = dot(sky_radiance, luminance_weights);
    float local_lum = dot(vx_hit.accumulated_light, luminance_weights);
    float sky_weight = clamp01(sky_lum / max(sky_lum + local_lum, eps));

#if RTGI_TRACER == RTGI_TRACER_HYBRID
    // 3. Stage 6 C.2: Feathered Partition MIS between Screen-Space GI and Voxel DDA
    SSGIHit ss_hit = trace_screen_space_gi(
        screen_pos,
        view_pos,
        view_normal,
        ray_dir_view,
        dither,
        surface_skylight,
        shadow_tex,
        shadow_mv,
        shadow_proj,
        direct_sun_color,
        sky_ambient_color,
        l_dir,
        gbuffer0_sampler,
        depth_translucent_sampler
    );

    float w_ss = ss_hit.hit ? ss_hit.edge_fade : 0.0;
    vec3 vx_radiance = vx_hit.radiance + vx_hit.accumulated_light;
#if RTGI_MULTIBOUNCE == RTGI_MULTIBOUNCE_PROBES
    if (vx_hit.hit) {
        vec3 hit_world_pos = vx_hit.hit_pos + cameraPosition;
        vec4 probe_irr = sample_ddgi_irradiance(
            hit_world_pos + vx_hit.hit_normal * 0.15,
            vx_hit.hit_normal,
            cameraPosition
        );
        vx_radiance += (vx_hit.albedo * voxel_bounce_rcp_pi) * probe_irr.rgb;
    }
#endif
    vec3 vx_or_sky_radiance = vx_hit.hit ? vx_radiance : total_sky_radiance;
    float vx_or_sky_weight = vx_hit.hit ? vx_hit.sky_weight : sky_weight;

    vec3 final_radiance = ss_hit.radiance * w_ss + vx_or_sky_radiance * (1.0 - w_ss);
    float final_sky_weight = ss_hit.sky_weight * w_ss + vx_or_sky_weight * (1.0 - w_ss);

    if (w_ss > 0.5) {
        hit_source = RTGI_HIT_SSGI;
    } else if (vx_hit.hit) {
        hit_source = RTGI_HIT_VOXEL;
    } else {
        hit_source = RTGI_HIT_SKY;
    }

    return vec4(final_radiance, final_sky_weight);
#else
    // Pure Voxel RT (SEUS-style robust offline-like GI): zero camera dependence
    if (vx_hit.hit) {
        hit_source = RTGI_HIT_VOXEL;
#if RTGI_MULTIBOUNCE == RTGI_MULTIBOUNCE_PROBES
        vec3 hit_world_pos = vx_hit.hit_pos + cameraPosition;
        vec4 probe_irr = sample_ddgi_irradiance(
            hit_world_pos + vx_hit.hit_normal * 0.15,
            vx_hit.hit_normal,
            cameraPosition
        );
        vec3 multi_bounce = (vx_hit.albedo * voxel_bounce_rcp_pi) * probe_irr.rgb;
        return vec4(
            vx_hit.radiance + vx_hit.accumulated_light + multi_bounce,
            vx_hit.sky_weight
        );
#else
        return vec4(
            vx_hit.radiance + vx_hit.accumulated_light,
            vx_hit.sky_weight
        );
#endif
    }

    hit_source = RTGI_HIT_SKY;
    return vec4(total_sky_radiance, sky_weight);
#endif
}

#endif // INCLUDE_LIGHTING_RT_HYBRID_RTGI

