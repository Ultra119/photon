#if !defined INCLUDE_LIGHTING_RT_RT_GI
#define INCLUDE_LIGHTING_RT_RT_GI

// RT-mode diffuse indirect estimator.
//
// Primary visibility stays in the raster G-buffer. Indirect transport is
// world-space voxel RT only: there is no screen-space GI partition, no
// previous-composite feedback, and no analytic sky/block fallback. A ray that
// leaves the voxel volume samples the directional sky map as an explicit
// environment miss.

#include "/include/utility/color.glsl"
#include "/include/utility/geometry.glsl"
#include "/include/sky/projection.glsl"
#include "voxel_dda.glsl"
#include "ddgi.glsl"

#define RTGI_HIT_NONE  0
#define RTGI_HIT_VOXEL 1
#define RTGI_HIT_SKY   2

vec3 sample_cosine_hemisphere(vec3 normal, vec2 u) {
    float r = sqrt(u.x);
    float phi = 6.28318530718 * u.y;

    vec3 local_dir = vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.x)));
    mat3 tbn_basis = build_orthonormal_basis(normal);
    return normalize(tbn_basis * local_dir);
}

// RGB = incoming radiance along the sampled diffuse ray.
// A   = fraction of that radiance attributed to sun/sky rather than local
//       emissive transport. The alpha channel is retained for the existing
//       temporal/filter/debug plumbing.
vec4 evaluate_rtgi_ray(
    vec3 scene_pos,
    vec3 world_normal,
    vec3 ray_dir_world,
    float dither,
    usampler3D voxel_grid,
    usampler3D voxel_mid,
    usampler3D voxel_coarse,
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    sampler2D sky_map,
    vec3 direct_sun_color,
    vec3 l_dir,
    out int hit_source
) {
    VoxelHit vx_hit = trace_voxel_dda(
        voxel_grid,
        voxel_mid,
        voxel_coarse,
        shadow_tex,
        shadow_mv,
        shadow_proj,
        scene_pos,
        world_normal,
        ray_dir_world,
        dither,
        direct_sun_color,
        l_dir,
        rt_scene_max_distance
    );

    if (vx_hit.hit) {
        hit_source = RTGI_HIT_VOXEL;

        vec3 hit_world_pos = vx_hit.hit_pos + cameraPosition;
        vec4 probe_irr = sample_ddgi_irradiance(
            hit_world_pos + vx_hit.hit_normal * 0.15,
            vx_hit.hit_normal,
            cameraPosition
        );

        // The probe cache stores irradiance. Convert the cached indirect
        // irradiance at the hit surface back into outgoing radiance.
        vec3 probe_bounce = vx_hit.albedo * voxel_bounce_rcp_pi * probe_irr.rgb;
        vec3 radiance = (vx_hit.radiance + probe_bounce) * vx_hit.transmittance;

        float sky_lum = dot(vx_hit.radiance * vx_hit.sky_weight
            + probe_bounce * probe_irr.a, luminance_weights);
        float total_lum = dot(radiance, luminance_weights);
        float sky_weight = clamp01(sky_lum / max(total_lum, eps));

        return vec4(radiance, sky_weight);
    }

    hit_source = RTGI_HIT_SKY;
    vec3 sky_radiance = texture(sky_map, project_sky(ray_dir_world)).rgb
        * vx_hit.transmittance;
    return vec4(sky_radiance, 1.0);
}

#endif // INCLUDE_LIGHTING_RT_RT_GI
