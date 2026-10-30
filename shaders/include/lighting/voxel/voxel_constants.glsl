#if !defined INCLUDE_LIGHTING_VOXEL_CONSTANTS
#define INCLUDE_LIGHTING_VOXEL_CONSTANTS

// global.glsl included by parent program
#include "/include/utility/fast_math.glsl"

// R7 clipmap backend. Level l uses 2^l blocks per voxel. All levels share the
// same texel dimension, so three 128^3 levels cover 128/256/512 blocks across
// without a single 512^3 allocation. Iris clears these images each frame; the
// toroidal address mapping is stable, while population is a full rebuild from
// the terrain submitted to the shadow/gbuffer passes.
#ifndef RT_CLIPMAP_SIZE
#define RT_CLIPMAP_SIZE 128
#endif
#ifndef RT_COVERAGE_LEVELS
#define RT_COVERAGE_LEVELS 3
#endif

const int rt_clipmap_dim = RT_CLIPMAP_SIZE;
const ivec3 rt_clipmap_size = ivec3(RT_CLIPMAP_SIZE);
const vec3 rt_clipmap_size_f = vec3(float(RT_CLIPMAP_SIZE));

// Voxel shape classification (Stage 4 data model, consumed by Stage 5 ray queries)
const uint VOXEL_SHAPE_CUBE          = 0u; // Full 1x1x1 solid block
const uint VOXEL_SHAPE_SLAB_BOTTOM   = 1u; // Bottom half-slab (y in 0.0 .. 0.5)
const uint VOXEL_SHAPE_SLAB_TOP      = 2u; // Top half-slab (y in 0.5 .. 1.0)
const uint VOXEL_SHAPE_STAIRS        = 3u; // Stairs
const uint VOXEL_SHAPE_PANE_OR_FENCE = 4u; // Thin fence, iron bars, or glass pane
const uint VOXEL_SHAPE_PLANT         = 5u; // Non-solid plant / flower / crop
const uint VOXEL_SHAPE_GLASS         = 6u; // Transparent full cube
const uint VOXEL_SHAPE_OTHER         = 7u; // Non-standard shape

float rt_clip_scale(int level) {
    return float(1 << level);
}

float rt_clip_extent(int level) {
    return float(rt_clipmap_dim) * rt_clip_scale(level);
}

// World-space min corner, snapped to the level's voxel grid. Snapping prevents
// sub-voxel camera drift from reshuffling every cell each frame.
vec3 rt_clip_origin_world(int level) {
    float scale = rt_clip_scale(level);
    float extent = rt_clip_extent(level);
    return floor((cameraPosition - vec3(extent * 0.5)) / scale) * scale;
}

vec3 rt_clip_origin_scene(int level) {
    return rt_clip_origin_world(level) - cameraPosition;
}

// Positive modulo toroidal addressing. The current backend rebuilds cleared
// images each frame, but keeping the mapping toroidal makes the coordinate
// contract ready for persistent scroll updates without changing ray queries.
ivec3 rt_clip_texel(ivec3 cell) {
    vec3 wrapped = vec3(cell) - rt_clipmap_size_f * floor(vec3(cell) / rt_clipmap_size_f);
    return ivec3(wrapped);
}

bool rt_clip_contains_world(vec3 world_pos, int level) {
    vec3 local = (world_pos - rt_clip_origin_world(level)) / rt_clip_scale(level);
    return all(greaterThanEqual(local, vec3(0.0)))
        && all(lessThan(local, rt_clipmap_size_f));
}

int rt_clip_finest_containing_level(vec3 world_pos) {
    for (int level = 0; level < RT_COVERAGE_LEVELS; ++level) {
        if (rt_clip_contains_world(world_pos, level)) return level;
    }
    return -1;
}

// Backwards-compatible fine-level helpers used by contact AO, probe relocation
// and voxel debug views. Fine level 0 is still one block per voxel.
vec3 scene_to_voxel_space(vec3 scene_pos) {
    return (scene_pos + cameraPosition - rt_clip_origin_world(0));
}

vec3 voxel_to_scene_space(vec3 voxel_pos) {
    return voxel_pos + rt_clip_origin_scene(0);
}

bool is_inside_voxel_grid(ivec3 voxel_coord) {
    return all(greaterThanEqual(voxel_coord, ivec3(0)))
        && all(lessThan(voxel_coord, rt_clipmap_size));
}

ivec3 clamp_to_voxel_grid(ivec3 pos) {
    return clamp(pos, ivec3(0), rt_clipmap_size - 1);
}

// Maximum RT scene query distance: the active coarsest half-extent times sqrt(3)
// so a diagonal ray can reach the far corner of the cube. Actual population is
// still limited to terrain submitted by the shadow/gbuffer passes.
const float rt_scene_max_distance =
    float(RT_CLIPMAP_SIZE) * float(1 << (RT_COVERAGE_LEVELS - 1)) * 0.5 * 1.73205080757;

const int voxel_dda_max_steps = RT_CLIPMAP_SIZE * 3 + 8;

#endif // INCLUDE_LIGHTING_VOXEL_CONSTANTS
