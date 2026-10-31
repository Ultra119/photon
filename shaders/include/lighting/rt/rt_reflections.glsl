#if !defined INCLUDE_LIGHTING_RT_REFLECTIONS
#define INCLUDE_LIGHTING_RT_REFLECTIONS

/*
--------------------------------------------------------------------------------

  Photon Shader: RT Mode
  include/lighting/rt/rt_reflections.glsl:
  World-space voxel ray-traced specular reflection transport.

  Reflections are traced into the same voxel scene used by diffuse GI. There is
  no screen-space ray march and no previous-composite color sampling: a ray that
  leaves the voxel volume resolves to directional sky/environment radiance. This
  keeps reflections valid off-screen and behind the camera.

  Voxel hit shading resolves sun visibility with the voxel march (Wave-3
  cascade fix); it no longer depends on the raster shadow map, so all worlds
  and SHADOW-disabled profiles trace real voxel reflections. Escaped rays
  resolve to environment radiance (sky map), not an SSR fallback.

--------------------------------------------------------------------------------
*/

#include "voxel_dda.glsl"
#include "/include/sky/projection.glsl"

// Voxel hit shading used to require the raster shadow map (removed in the
// Wave-3 cascade fix: sun visibility is a voxel march now). Every program
// that can reach this path already binds the clipmap voxel textures, so voxel
// reflections work in the Nether and with SHADOW disabled too.
#define RT_REFLECTION_CAN_TRACE_VOXEL 1

// Directional environment radiance for a reflection ray that escapes the voxel
// scene. This is the sky map, not a screen-space or history buffer.
vec3 get_rt_reflection_environment(vec3 ray_dir_world, sampler2D sky_map) {
    return texture(sky_map, project_sky(ray_dir_world)).rgb;
}

// Primary RT reflection transport. Returns the radiance seen along a specular
// ray: voxel surface outgoing radiance on hit, environment radiance on miss.
vec3 trace_rt_reflection(
    vec3 scene_pos,
    vec3 surface_normal,
    vec3 ray_dir_world,
    float dither,
    usampler3D voxel_grid,
    usampler3D voxel_mid,
    usampler3D voxel_coarse,
    vec3 direct_sun_color,
    vec3 l_dir,
    sampler2D sky_map
) {
    vec3 environment = get_rt_reflection_environment(ray_dir_world, sky_map);

    VoxelHit vx_hit = trace_voxel_dda(
        voxel_grid,
        voxel_mid,
        voxel_coarse,
        scene_pos,
        surface_normal,
        ray_dir_world,
        dither,
        direct_sun_color,
        l_dir,
        rt_scene_max_distance
    );

    if (vx_hit.hit) {
        // Outgoing radiance at the hit surface (emission + first diffuse bounce
        // of direct sun), attenuated by any tinted glass along the ray.
        vec3 radiance =
            vx_hit.radiance * vx_hit.transmittance + vx_hit.passed_emission;

        // Firefly guard: suppress extreme single-ray emitter spikes so rough
        // multi-ray reflections stay temporally stable.
        float lum = dot(radiance, vec3(0.2126, 0.7152, 0.0722));
        const float max_reflection_radiance = 64.0;
        if (lum > max_reflection_radiance) {
            radiance *= max_reflection_radiance / lum;
        }
        return radiance;
    }

    return environment * vx_hit.transmittance + vx_hit.passed_emission;
}

#endif // INCLUDE_LIGHTING_RT_REFLECTIONS
