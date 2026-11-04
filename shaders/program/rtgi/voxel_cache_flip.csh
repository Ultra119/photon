/*
--------------------------------------------------------------------------------

  Photon Shader: RT / PT Mode
  program/rtgi/voxel_cache_flip.csh:
  Voxel Irradiance Volume: Buffer Copy Pass.

  Copies the generated irradiance volume to the flip images prior to spatial
  filtering, enabling ping-pong spatial convolution.

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

#define VOXEL_CACHE_WRITE_ONLY
#include "/include/lighting/rt/voxel_cache.glsl"

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
    if (any(greaterThanEqual(cell, rt_clipmap_size))) return;

    imageStore(voxel_cache_flip_sh_img, cell, texelFetch(voxel_cache_sh_sampler, cell, 0));
    imageStore(voxel_cache_flip_aux_img, cell, texelFetch(voxel_cache_aux_sampler, cell, 0));
}
