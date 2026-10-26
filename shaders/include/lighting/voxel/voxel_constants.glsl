#if !defined INCLUDE_LIGHTING_VOXEL_CONSTANTS
#define INCLUDE_LIGHTING_VOXEL_CONSTANTS

// global.glsl included by parent program
#include "/include/utility/fast_math.glsl"

#ifndef VOXEL_VOLUME_SIZE
#define VOXEL_VOLUME_SIZE 128
#endif

const ivec3 voxel_volume_size = ivec3(VOXEL_VOLUME_SIZE);
const vec3 voxel_volume_size_f = vec3(VOXEL_VOLUME_SIZE);
const vec3 voxel_half_volume = voxel_volume_size_f * 0.5;
const vec3 rcp_voxel_volume = 1.0 / voxel_volume_size_f;

// Distance in blocks from player camera that voxels span
const float voxel_distance = float(VOXEL_VOLUME_SIZE) * 0.5;

// Fade the vanilla blocklight fallback in near the edge of the axis-aligned
// voxel cube. A 45-degree ray crosses ~sqrt(3) * distance voxel boundaries,
// so 7/8 * VOXEL_VOLUME_SIZE + 8 is a safe DDA step budget.
const float voxel_edge_fade_start = max(0.0, voxel_distance - 12.0);
const float voxel_edge_fade_end = max(1.0, voxel_distance - 4.0);
const int voxel_dda_max_steps = int(VOXEL_VOLUME_SIZE) * 7 / 8 + 8;

vec3 get_voxel_grid_center(vec3 look_dir) {
#if VOXEL_VOLUME_CENTER == VOXEL_VOLUME_CENTER_AHEAD
    const float forward_bias = 0.25;
    return floor(look_dir * voxel_volume_size_f * forward_bias * rcp(max_of(abs(look_dir))));
#else
    return vec3(0.0);
#endif
}

vec3 scene_to_voxel_space(vec3 scene_pos) {
    vec3 to_center = get_voxel_grid_center(gbufferModelViewInverse[2].xyz);
    return scene_pos + fract(cameraPosition) + voxel_half_volume + to_center;
}

vec3 voxel_to_scene_space(vec3 voxel_pos) {
    vec3 to_center = get_voxel_grid_center(gbufferModelViewInverse[2].xyz);
    return voxel_pos - fract(cameraPosition) - voxel_half_volume - to_center;
}

// Chebyshev distance from the volume center, matching the axis-aligned cube.
float get_voxel_edge_distance(vec3 scene_pos) {
    vec3 voxel_pos = scene_to_voxel_space(scene_pos);
    return max_of(abs(voxel_pos - voxel_half_volume));
}

bool is_inside_voxel_volume(vec3 voxel_pos) {
    vec3 normalized_pos = voxel_pos * rcp_voxel_volume;
    return clamp01(normalized_pos) == normalized_pos;
}

bool is_inside_voxel_grid(ivec3 voxel_coord) {
    return all(greaterThanEqual(voxel_coord, ivec3(0))) &&
           all(lessThan(voxel_coord, voxel_volume_size));
}

ivec3 clamp_to_voxel_grid(ivec3 pos) {
    return clamp(pos, ivec3(0), voxel_volume_size - 1);
}

#endif // INCLUDE_LIGHTING_VOXEL_CONSTANTS

