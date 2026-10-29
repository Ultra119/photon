#version 400 compatibility
#extension GL_ARB_shader_image_load_store : enable
#define WORLD_OVERWORLD
#define PROGRAM_GBUFFERS_TERRAIN
#define PROGRAM_GBUFFERS_BLOCK
#define PROGRAM_GBUFFERS_ENTITIES
#define COLORWHEEL
#define vsh
#include "/program/gbuffers_all_solid.vsh"
