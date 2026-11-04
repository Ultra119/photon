#if !defined INCLUDE_LIGHTING_RT_VOXEL_CACHE
#define INCLUDE_LIGHTING_RT_VOXEL_CACHE

/*
--------------------------------------------------------------------------------

  Photon Shader: RT / PT Mode
  include/lighting/rt/voxel_cache.glsl:
  Modernized Dense Voxel Irradiance Volume.

  1:1 block-aligned 3D irradiance grid matching Level 0 voxel clipmap coordinates.
  Stores directional L1 Spherical Harmonics + converged RGB irradiance and
  sky-origin fraction for leak gating. Evaluated with air-weighted filtering.

--------------------------------------------------------------------------------
*/

#include "/include/utility/color.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/lighting/voxel/voxel_constants.glsl"
#include "/include/lighting/voxel/voxel_storage.glsl"
#include "/include/lighting/rt/voxel_samplers.glsl"

#ifndef VOXEL_CACHE_WRITE_ONLY
uniform sampler3D voxel_cache_sh_sampler;
uniform sampler3D voxel_cache_aux_sampler;
uniform sampler3D voxel_cache_flip_sh_sampler;
uniform sampler3D voxel_cache_flip_aux_sampler;
#endif

// L1 Spherical Harmonics projection constants
// Y_00 = 0.28209479
// Y_11 = 0.48860251 * x
// Y_1-1 = 0.48860251 * y
// Y_10 = 0.48860251 * z
// Diffuse convolution factor: pi for l=0, 2*pi/3 for l=1
// Convolved:
// l=0: pi * 0.28209479 = 0.8862269
// l=1: (2*pi/3) * 0.48860251 = 1.0233267
const float sh_c0 = 0.28209479;
const float sh_c1 = 0.48860251;
const float sh_conv0 = 0.8862269;
const float sh_conv1 = 1.0233267;

// Converts incoming radiance and ray direction to 4-coefficient L1 SH (luma Y).
vec4 radiance_to_l1_sh(vec3 radiance, vec3 dir) {
    float Y = dot(radiance, luminance_weights);
    return vec4(
        sh_c1 * dir.x * Y,
        sh_c1 * dir.y * Y,
        sh_c1 * dir.z * Y,
        sh_c0 * Y
    );
}

// Projects stored L1 SH coefficients against a receiver surface normal.
float project_l1_sh_irradiance(vec4 sh, vec3 normal) {
    float E_Y = sh.w * sh_conv0 + (sh.x * normal.x + sh.y * normal.y + sh.z * normal.z) * sh_conv1;
    return max(0.0, E_Y);
}

#ifndef VOXEL_CACHE_WRITE_ONLY
// Queries the Voxel Irradiance Volume with air-weighted trilinear filtering.
// Offsets by normal * 0.2 into the adjacent air cell, then filters across the
// 2x2x2 neighborhood while completely ignoring solid blocks (vs.block_id != 0).
// Returns vec4(RGB irradiance, sky-origin fraction).
vec4 sample_voxel_cache_irradiance(
    vec3 scene_pos,
    vec3 normal,
    vec3 cam_pos
) {
    vec3 query_scene_pos = scene_pos + normal * 0.2;
    vec3 voxel_coord = scene_to_voxel_space(query_scene_pos);

    // Bounds check within Level 0 clipmap extent
    if (any(lessThan(voxel_coord, vec3(0.0))) || any(greaterThanEqual(voxel_coord, rt_clipmap_size_f))) {
        return vec4(0.0);
    }

    ivec3 base_cell = ivec3(floor(voxel_coord));
    vec3 frac_coord = fract(voxel_coord);

    vec4 accum_sh = vec4(0.0);
    vec3 accum_rgb = vec3(0.0);
    float accum_sky = 0.0;
    float total_w = 0.0;

    for (int dz = 0; dz <= 1; ++dz) {
        float wz = dz == 1 ? frac_coord.z : (1.0 - frac_coord.z);
        for (int dy = 0; dy <= 1; ++dy) {
            float wy = dy == 1 ? frac_coord.y : (1.0 - frac_coord.y);
            for (int dx = 0; dx <= 1; ++dx) {
                float wx = dx == 1 ? frac_coord.x : (1.0 - frac_coord.x);
                ivec3 tap_cell = base_cell + ivec3(dx, dy, dz);

                if (any(lessThan(tap_cell, ivec3(0))) || any(greaterThanEqual(tap_cell, rt_clipmap_size))) {
                    continue;
                }

                // Air-weighted test: reject solid voxels so wall interiors never leak into rooms
                uint vx_data = texelFetch(voxel_sampler, tap_cell, 0).r;
                VoxelSample vs = unpack_voxel_data(vx_data);
                if (vs.block_id != 0u && vs.shape_class != VOXEL_SHAPE_PLANT) {
                    continue;
                }

                vec4 tap_aux = texelFetch(voxel_cache_aux_sampler, tap_cell, 0);
                if (tap_aux.a < 0.5) continue; // Uninitialized cell

                float w = wx * wy * wz;
                vec4 tap_sh = texelFetch(voxel_cache_sh_sampler, tap_cell, 0);

                accum_sh += tap_sh * w;
                accum_rgb += tap_aux.rgb * w;
                accum_sky += fract(tap_aux.a) * (1.0 / 0.99) * w;
                total_w += w;
            }
        }
    }

    if (total_w < 1e-4) return vec4(0.0);

    accum_sh /= total_w;
    accum_rgb /= total_w;
    accum_sky = clamp01(accum_sky / total_w);

    // Directional modulation: project L1 SH against surface normal and modulate RGB
    float E_Y = project_l1_sh_irradiance(accum_sh, normal);
    float dc_Y = max(1e-4, accum_sh.w * sh_conv0);
    float dir_ratio = clamp(E_Y / dc_Y, 0.15, 2.5);

    vec3 final_irradiance = accum_rgb * dir_ratio;
    return vec4(final_irradiance, accum_sky);
}

// Queries the previous-frame flip cache for recursive multi-bounce transport.
vec4 sample_voxel_cache_irradiance_flip(
    vec3 scene_pos,
    vec3 normal
) {
    vec3 query_scene_pos = scene_pos + normal * 0.2;
    vec3 voxel_coord = scene_to_voxel_space(query_scene_pos);

    if (any(lessThan(voxel_coord, vec3(0.0))) || any(greaterThanEqual(voxel_coord, rt_clipmap_size_f))) {
        return vec4(0.0);
    }

    ivec3 base_cell = ivec3(floor(voxel_coord));
    vec3 frac_coord = fract(voxel_coord);

    vec4 accum_sh = vec4(0.0);
    vec3 accum_rgb = vec3(0.0);
    float accum_sky = 0.0;
    float total_w = 0.0;

    for (int dz = 0; dz <= 1; ++dz) {
        float wz = dz == 1 ? frac_coord.z : (1.0 - frac_coord.z);
        for (int dy = 0; dy <= 1; ++dy) {
            float wy = dy == 1 ? frac_coord.y : (1.0 - frac_coord.y);
            for (int dx = 0; dx <= 1; ++dx) {
                float wx = dx == 1 ? frac_coord.x : (1.0 - frac_coord.x);
                ivec3 tap_cell = base_cell + ivec3(dx, dy, dz);

                if (any(lessThan(tap_cell, ivec3(0))) || any(greaterThanEqual(tap_cell, rt_clipmap_size))) {
                    continue;
                }

                uint vx_data = texelFetch(voxel_sampler, tap_cell, 0).r;
                VoxelSample vs = unpack_voxel_data(vx_data);
                if (vs.block_id != 0u && vs.shape_class != VOXEL_SHAPE_PLANT) {
                    continue;
                }

                vec4 tap_aux = texelFetch(voxel_cache_flip_aux_sampler, tap_cell, 0);
                if (tap_aux.a < 0.5) continue;

                float w = wx * wy * wz;
                vec4 tap_sh = texelFetch(voxel_cache_flip_sh_sampler, tap_cell, 0);

                accum_sh += tap_sh * w;
                accum_rgb += tap_aux.rgb * w;
                accum_sky += fract(tap_aux.a) * (1.0 / 0.99) * w;
                total_w += w;
            }
        }
    }

    if (total_w < 1e-4) return vec4(0.0);

    accum_sh /= total_w;
    accum_rgb /= total_w;
    accum_sky = clamp01(accum_sky / total_w);

    float E_Y = project_l1_sh_irradiance(accum_sh, normal);
    float dc_Y = max(1e-4, accum_sh.w * sh_conv0);
    float dir_ratio = clamp(E_Y / dc_Y, 0.15, 2.5);

    return vec4(accum_rgb * dir_ratio, accum_sky);
}
#endif // VOXEL_CACHE_WRITE_ONLY

#endif // INCLUDE_LIGHTING_RT_VOXEL_CACHE
