#if !defined INCLUDE_LIGHTING_RT_REFLECTIONS
#define INCLUDE_LIGHTING_RT_REFLECTIONS

// global.glsl included by parent program
#include "voxel_dda.glsl"

// Traces specular reflection fallback into the 3D voxel grid when screen-space reflections miss
vec3 trace_voxel_specular_fallback(
    vec3 scene_pos,
    vec3 surface_normal,
    vec3 ray_dir_world,
    float dither,
    usampler3D voxel_grid,
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    vec3 direct_sun_color,
    vec3 sky_ambient_color,
    vec3 l_dir,
    vec3 sky_reflection
) {
    float max_reflection_dist = voxel_distance;

    VoxelHit vx_hit = trace_voxel_dda(
        voxel_grid,
        shadow_tex,
        shadow_mv,
        shadow_proj,
        scene_pos,
        surface_normal,
        ray_dir_world,
        dither,
        direct_sun_color,
        sky_ambient_color,
        l_dir,
        max_reflection_dist
    );

    if (vx_hit.hit) {
        return vx_hit.radiance + vx_hit.accumulated_light;
    }

    return sky_reflection + vx_hit.accumulated_light;
}

#endif // INCLUDE_LIGHTING_RT_REFLECTIONS

