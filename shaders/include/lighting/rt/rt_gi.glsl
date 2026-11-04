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
#include "voxel_cache.glsl"

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

    // SEUS-style cave/sky leak gate (Overworld only): sky-origin GI is
    // multiplied by the receiver's vanilla skylight so sealed interiors stay
    // dark even when rays escape the voxel grid through seams and then see
    // the sky. Local/emissive transport is unaffected.
#if defined WORLD_OVERWORLD
    float sky_gate = clamp01(receiver_skylight * 10.0);
#else
    float sky_gate = 1.0;
#endif

    if (vx_hit.hit) {
        hit_source = RTGI_HIT_VOXEL;

        // With the volume switched off its images stop being written and would
        // freeze whatever they last held into the second bounce, so the
        // consumer honours the same switch as the passes that fill it.
#if defined VOXEL_CACHE_ENABLED
        vec4 cache_irr = sample_voxel_cache_irradiance(
            vx_hit.hit_pos,
            vx_hit.hit_normal,
            cameraPosition
        );
#else
        vec4 cache_irr = vec4(0.0);
#endif

        float cache_gate = mix(0.45, 1.0, smoothstep(1.0, 3.0, vx_hit.distance));

        // The voxel cache stores directional L1 SH irradiance. Convert the cached
        // indirect irradiance at the hit surface back into outgoing radiance.
        vec3 cache_bounce = vx_hit.albedo * voxel_bounce_rcp_pi * cache_irr.rgb;
        vec3 cache_bounce_local = cache_bounce * (1.0 - cache_irr.a);
        vec3 cache_bounce_sky = cache_bounce * cache_irr.a * sky_gate;
        vec3 second_bounce = (cache_bounce_local + cache_bounce_sky) * cache_gate;

        // Split the hit into its sun/sky-bounce and local/emission parts and
        // gate ONLY the sky part. This is the full S2 leak gate: a bounce hit
        // that should never have been lit (shadow-map bias at perpendicular
        // sun angles, seam escapes) carries sky_weight = 1 and is zeroed on
        // low-skylight receivers, while emissive transport passes untouched.
        vec3 hit_sky = vx_hit.radiance * vx_hit.sky_weight;
        vec3 hit_local = vx_hit.radiance - hit_sky;

        vec3 radiance = (hit_local + hit_sky * sky_gate + second_bounce)
            * vx_hit.transmittance
            + vx_hit.passed_emission;

        float sky_lum = dot(
            hit_sky * sky_gate + second_bounce * cache_irr.a,
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
