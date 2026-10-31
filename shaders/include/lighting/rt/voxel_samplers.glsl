#if !defined INCLUDE_LIGHTING_RT_VOXEL_SAMPLERS
#define INCLUDE_LIGHTING_RT_VOXEL_SAMPLERS

// Single declaration point for the clipmap voxel textures, shared by the RTGI
// compute programs, the specular/reflection path, and the forward diffuse
// consumers of the DDGI occlusion query (L1). Include guards make repeated
// inclusion within one translation unit safe.
uniform usampler3D voxel_sampler;
uniform usampler3D voxel_mid_sampler;
uniform usampler3D voxel_coarse_sampler;

#endif
