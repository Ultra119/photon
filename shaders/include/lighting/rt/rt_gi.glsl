#if !defined INCLUDE_LIGHTING_RT_RT_GI
#define INCLUDE_LIGHTING_RT_RT_GI

// World-space diffuse GI ray evaluation

#include "/include/utility/color.glsl"
#include "/include/utility/geometry.glsl"
#include "/include/sky/projection.glsl"
#include "voxel_dda.glsl"
// Let sample_ddgi_irradiance() occlusion-test surface->probe segments against
// the fine voxel grid (callers of this file declare the voxel samplers).
#define DDGI_QUERY_OCCLUSION
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
    float receiver_skylight,
    usampler3D voxel_grid,
    usampler3D voxel_mid,
    usampler3D voxel_coarse,
    sampler2D sky_map,
    vec3 direct_sun_color,
    vec3 sky_irradiance,
    vec3 l_dir,
    out int hit_source
) {
    VoxelHit vx_hit = trace_voxel_dda(
        voxel_grid,
        voxel_mid,
        voxel_coarse,
        scene_pos,
        world_normal,
        ray_dir_world,
        dither,
        direct_sun_color,
        sky_irradiance,
        l_dir,
        rt_scene_max_distance
    );

    // Skylight gate for enclosed spaces
#if defined WORLD_OVERWORLD
    float sky_gate = clamp01(receiver_skylight * 10.0);
#else
    float sky_gate = 1.0;
#endif

    if (vx_hit.hit) {
        hit_source = RTGI_HIT_VOXEL;

        vec3 hit_world_pos = vx_hit.hit_pos + cameraPosition;
        vec4 probe_irr = sample_ddgi_irradiance(
            hit_world_pos + vx_hit.hit_normal * 0.15,
            vx_hit.hit_normal,
            cameraPosition
        );

        // Distance fade for multi-bounce probe contribution
        float probe_gate = smoothstep(1.0, 3.0, vx_hit.distance);

        // Convert cached probe irradiance to outgoing radiance
        vec3 probe_bounce = vx_hit.albedo * voxel_bounce_rcp_pi * probe_irr.rgb;
        vec3 probe_bounce_local = probe_bounce * (1.0 - probe_irr.a);
        vec3 probe_bounce_sky = probe_bounce * probe_irr.a * sky_gate;
        probe_bounce = (probe_bounce_local + probe_bounce_sky) * probe_gate;

        // Gate sky-origin bounce against receiver skylight
        vec3 hit_sky = vx_hit.radiance * vx_hit.sky_weight;
        vec3 hit_local = vx_hit.radiance - hit_sky;

        vec3 radiance = (hit_local + hit_sky * sky_gate + probe_bounce)
            * vx_hit.transmittance
            + vx_hit.passed_emission;

        float sky_lum = dot(
            hit_sky * sky_gate + probe_bounce * probe_irr.a,
            luminance_weights
        );
        float total_lum = dot(radiance, luminance_weights);
        float sky_weight = clamp01(sky_lum / max(total_lum, eps));

        return vec4(radiance, sky_weight);
    }

    hit_source = RTGI_HIT_SKY;
    vec3 sky_radiance = texture(sky_map, project_sky(ray_dir_world)).rgb
        * vx_hit.transmittance * sky_gate
        + vx_hit.passed_emission;
    return vec4(sky_radiance, sky_gate);
}

#endif // INCLUDE_LIGHTING_RT_RT_GI
