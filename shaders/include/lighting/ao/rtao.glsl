#if !defined INCLUDE_LIGHTING_AO_RTAO
#define INCLUDE_LIGHTING_AO_RTAO

// global.glsl included by parent program
#include "/include/utility/geometry.glsl"
#include "/include/lighting/voxel/voxel_constants.glsl"
#include "/include/lighting/rt/voxel_dda.glsl"

vec2 compute_rtao(
    vec3 scene_pos,
    vec3 world_normal,
    usampler3D voxel_grid,
    vec2 dither,
    out vec3 bent_normal
) {
    const int RTAO_SAMPLES = 4;
    const float RTAO_RADIUS = 3.0; // 3 blocks

    float total_occlusion = 0.0;
    vec3 unoccluded_dir_sum = world_normal;

    mat3 tbn = build_orthonormal_basis(world_normal);

    for (int i = 0; i < RTAO_SAMPLES; ++i) {
        vec2 u = fract(dither + r2(i * 13, dither));
        float r = sqrt(u.x);
        float phi = 6.28318530718 * u.y;

        vec3 local_dir = vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.x)));
        vec3 ray_dir = normalize(tbn * local_dir);

        // Trace short distance through voxel grid
        vec3 ray_start = scene_pos + world_normal * 0.1;
        vec3 start_vx = scene_to_voxel_space(ray_start);
        ivec3 cur_vx = ivec3(floor(start_vx));

        vec3 step_dir = sign(ray_dir);
        vec3 delta_t = abs(1.0 / (ray_dir + vec3(1e-7)));
        vec3 t_max = (step_dir * (vec3(cur_vx) - start_vx) + step_dir * 0.5 + 0.5) * delta_t;
        vec3 mask = vec3(0.0);
        float t = 0.0;
        bool hit = false;

        for (int s = 0; s < 6; ++s) {
            if (!is_inside_voxel_grid(cur_vx) || t > RTAO_RADIUS) break;

            uvec4 data = texelFetch(voxel_grid, cur_vx, 0);
            if (data.r != 0u) {
                hit = true;
                break;
            }

            mask = step(t_max.xyz, min(t_max.yzx, t_max.zxy));
            t = min(min(t_max.x, t_max.y), t_max.z);
            t_max += mask * delta_t;
            cur_vx += ivec3(mask * step_dir);
        }

        if (hit) {
            float occ = clamp01(1.0 - (t / RTAO_RADIUS));
            total_occlusion += occ;
        } else {
            unoccluded_dir_sum += ray_dir;
        }
    }

    float ao = clamp01(1.0 - (total_occlusion / float(RTAO_SAMPLES)));
    bent_normal = normalize((mat3(gbufferModelView) * normalize(unoccluded_dir_sum)));

    return vec2(ao, 0.0);
}

#endif // INCLUDE_LIGHTING_AO_RTAO

