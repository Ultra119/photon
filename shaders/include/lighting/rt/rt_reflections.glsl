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

  Voxel hit shading needs the shadow map to resolve direct sun at the hit
  surface. Dimensions/programs without a shadow map (Nether, SHADOW disabled)
  cannot shade voxel hits, so the transport resolves to environment radiance
  there. That is an environment-only RT reflection, not an SSR fallback.

--------------------------------------------------------------------------------
*/

#include "voxel_dda.glsl"
#include "/include/sky/projection.glsl"

// Voxel hit shading requires shadowtex0/shadowModelView/shadowProjection, which
// are only declared by the Overworld/End programs that enable SHADOW.
#if defined SHADOW && !defined WORLD_NETHER
#define RT_REFLECTION_CAN_TRACE_VOXEL 1
#else
#define RT_REFLECTION_CAN_TRACE_VOXEL 0
#endif

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
        vec3 radiance = vx_hit.radiance * vx_hit.transmittance;

        // Firefly guard: suppress extreme single-ray emitter spikes so rough
        // multi-ray reflections stay temporally stable.
        float lum = dot(radiance, vec3(0.2126, 0.7152, 0.0722));
        const float max_reflection_radiance = 64.0;
        if (lum > max_reflection_radiance) {
            radiance *= max_reflection_radiance / lum;
        }
        return radiance;
    }

    return environment * vx_hit.transmittance;
}

#endif // INCLUDE_LIGHTING_RT_REFLECTIONS
