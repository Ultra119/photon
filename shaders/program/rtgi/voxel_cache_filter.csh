/*
--------------------------------------------------------------------------------

  Photon Shader: RT / PT Mode
  program/rtgi/voxel_cache_filter.csh:
  Voxel Irradiance Volume: Air-Constrained Spatial Filter Pass.

  Applies an air-constrained 6-neighbor spatial blur. Neighbor voxels that are
  solid geometry are rejected from contributing, guaranteeing that indirect
  light never bleeds through or into walls.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
#if RT_CLIPMAP_SIZE == 64
const ivec3 workGroups = ivec3(16, 16, 16);
#elif RT_CLIPMAP_SIZE == 96
const ivec3 workGroups = ivec3(24, 24, 24);
#else
const ivec3 workGroups = ivec3(32, 32, 32);
#endif

layout(rgba16f) writeonly uniform image3D voxel_cache_sh_img;
layout(rgba16f) writeonly uniform image3D voxel_cache_aux_img;

uniform sampler3D voxel_cache_flip_sh_sampler;
uniform sampler3D voxel_cache_flip_aux_sampler;

#include "/include/lighting/rt/voxel_samplers.glsl"
uniform vec3 cameraPosition;

#define VOXEL_CACHE_WRITE_ONLY
#include "/include/lighting/rt/voxel_cache.glsl"

const ivec3 face_dirs[6] = ivec3[6](
    ivec3( 1,  0,  0),
    ivec3(-1,  0,  0),
    ivec3( 0,  1,  0),
    ivec3( 0, -1,  0),
    ivec3( 0,  0,  1),
    ivec3( 0,  0, -1)
);

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
    if (any(greaterThanEqual(cell, rt_clipmap_size))) return;

    vec4 center_aux = texelFetch(voxel_cache_flip_aux_sampler, cell, 0);
    float center_samples = floor(center_aux.a);

    // If cell has no valid history or is inside solid block, pass through
    if (center_samples < 0.5) {
        imageStore(voxel_cache_sh_img, cell, vec4(0.0));
        imageStore(voxel_cache_aux_img, cell, vec4(0.0));
        return;
    }

    vec4 center_sh = texelFetch(voxel_cache_flip_sh_sampler, cell, 0);

    // Blur weight decreases as sample count increases to preserve sharpness
    float blur_weight = clamp(2.0 / max(center_samples, 1.0), 0.05, 0.5);

    vec4 accum_sh = center_sh;
    vec3 accum_rgb = center_aux.rgb;
    float accum_sky = fract(center_aux.a) * (1.0 / 0.99);
    float total_w = 1.0;

    for (int i = 0; i < 6; ++i) {
        ivec3 neighbor_cell = cell + face_dirs[i];

        if (any(lessThan(neighbor_cell, ivec3(0))) || any(greaterThanEqual(neighbor_cell, rt_clipmap_size))) {
            continue;
        }

        // Air-constraint: verify neighbor voxel is air
        uint vx_data = texelFetch(voxel_sampler, neighbor_cell, 0).r;
        VoxelSample vs = unpack_voxel_data(vx_data);
        if (vs.block_id != 0u && vs.shape_class != VOXEL_SHAPE_PLANT) {
            continue; // Skip solid block neighbor
        }

        vec4 n_aux = texelFetch(voxel_cache_flip_aux_sampler, neighbor_cell, 0);
        if (floor(n_aux.a) < 0.5) continue; // Uninitialized neighbor

        vec4 n_sh = texelFetch(voxel_cache_flip_sh_sampler, neighbor_cell, 0);
        float n_sky = fract(n_aux.a) * (1.0 / 0.99);

        accum_sh += n_sh * blur_weight;
        accum_rgb += n_aux.rgb * blur_weight;
        accum_sky += n_sky * blur_weight;
        total_w += blur_weight;
    }

    accum_sh /= total_w;
    accum_rgb /= total_w;
    accum_sky = clamp01(accum_sky / total_w);

    float packed_aux_a = center_samples + accum_sky * 0.99;

    imageStore(voxel_cache_sh_img, cell, accum_sh);
    imageStore(voxel_cache_aux_img, cell, vec4(accum_rgb, packed_aux_a));
}
