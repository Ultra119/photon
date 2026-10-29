#version 420 compatibility
#extension GL_ARB_shader_image_load_store : enable
#define WORLD_NETHER
#define PROGRAM_GBUFFERS_SPIDEREYES
#define vsh

#include "/settings.glsl"

#if defined IS_IRIS && defined USE_SEPARATE_ENTITY_DRAWS
#include "/program/gbuffers_all_translucent.vsh"
#else
#include "/program/gbuffers_all_solid.vsh"
#endif
