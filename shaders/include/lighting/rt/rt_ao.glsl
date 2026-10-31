#if !defined INCLUDE_LIGHTING_RT_RT_AO
#define INCLUDE_LIGHTING_RT_RT_AO

/*
 * RT Mode contact occlusion.
 *
 * Short world-space visibility rays supplement the occlusion already present
 * in traced GI. This is an artistic direct-light/contact term, not a second
 * indirect-lighting estimator: its result must not multiply RTGI or probes.
 * Missing voxel coverage is unoccluded, never an ambient-light fallback.
 */

#include "/include/utility/geometry.glsl"
#include "/include/utility/random.glsl"
#include "voxel_dda.glsl"

#ifndef RT_AO_STRENGTH
#define RT_AO_STRENGTH 0.50
#endif
#ifndef RT_AO_RADIUS
#define RT_AO_RADIUS 0.75
#endif
#ifndef RT_AO_RAYS
#define RT_AO_RAYS 4
#endif

float compute_rt_ao(
    vec3 scene_pos,
    vec3 geometric_normal,
    vec2 dither,
    usampler3D voxel_grid
) {
    if (RT_AO_STRENGTH <= 0.0) return 1.0;

    vec3 normal = normalize(geometric_normal);
    mat3 basis = build_orthonormal_basis(normal);
    float blocked = 0.0;

    for (int i = 0; i < RT_AO_RAYS; ++i) {
        vec2 u = r2(i, dither);
        float radius = sqrt(u.x);
        float phi = tau * u.y;
        vec3 local_dir = vec3(
            radius * cos(phi),
            radius * sin(phi),
            sqrt(max0(1.0 - u.x))
        );
        vec3 ray_dir = normalize(basis * local_dir);

        blocked += float(trace_any_hit(
            voxel_grid,
            scene_pos,
            normal,
            ray_dir,
            RT_AO_RADIUS
        ));
    }

    return clamp01(1.0 - RT_AO_STRENGTH * blocked / float(RT_AO_RAYS));
}

#endif // INCLUDE_LIGHTING_RT_RT_AO
