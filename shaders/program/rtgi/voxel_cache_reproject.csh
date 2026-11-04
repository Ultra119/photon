/*
--------------------------------------------------------------------------------

  Photon Shader: RT / PT Mode
  program/rtgi/voxel_cache_reproject.csh:
  Voxel Irradiance Volume: Camera Motion Reprojection Pass.

  Scrolls the previous frame's converged irradiance data according to the
  integer camera block displacement, writing into the flip cache images.
  Newly exposed boundary cells are initialized with zero history.

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

layout(rgba16f) writeonly uniform image3D voxel_cache_flip_sh_img;
layout(rgba16f) writeonly uniform image3D voxel_cache_flip_aux_img;

uniform sampler3D voxel_cache_sh_sampler;
uniform sampler3D voxel_cache_aux_sampler;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

#define VOXEL_CACHE_WRITE_ONLY
#include "/include/lighting/rt/voxel_cache.glsl"

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
    if (any(greaterThanEqual(cell, rt_clipmap_size))) return;

    vec3 curr_origin = rt_clip_origin_world(0);
    vec3 prev_origin = floor(previousCameraPosition - vec3(rt_clipmap_size_f * 0.5));
    ivec3 origin_shift = ivec3(curr_origin - prev_origin);

    ivec3 prev_cell = cell + origin_shift;

    bool valid_history = all(greaterThanEqual(prev_cell, ivec3(0)))
                      && all(lessThan(prev_cell, rt_clipmap_size));

    if (valid_history) {
        vec4 prev_sh = texelFetch(voxel_cache_sh_sampler, prev_cell, 0);
        vec4 prev_aux = texelFetch(voxel_cache_aux_sampler, prev_cell, 0);

        imageStore(voxel_cache_flip_sh_img, cell, prev_sh);
        imageStore(voxel_cache_flip_aux_img, cell, prev_aux);
    } else {
        imageStore(voxel_cache_flip_sh_img, cell, vec4(0.0));
        imageStore(voxel_cache_flip_aux_img, cell, vec4(0.0));
    }
}
