#if !defined INCLUDE_LIGHTING_VOXEL_UPDATE
#define INCLUDE_LIGHTING_VOXEL_UPDATE

#include "voxel_constants.glsl"
#include "voxel_storage.glsl"

#ifdef PROGRAM_SHADOW

bool is_voxel_corner(vec3 pos, float tolerance) {
    bvec3 lower = lessThan(pos, vec3(tolerance));
    bvec3 upper = greaterThan(pos, vec3(1.0 - tolerance));
    return all(bvec3(lower.x || upper.x, lower.y || upper.y, lower.z || upper.z));
}

bool should_voxelize(uint block_id, bool vertex_at_grid_corner) {
    bool is_transparent_block = (block_id == 1u || block_id == 18u || block_id == 28u || block_id == 30u || block_id == 80u);
    bool is_emitter = (32u <= block_id && block_id < 80u);

    return (vertex_at_grid_corner || is_emitter) && !is_transparent_block;
}

void update_rt_voxel_grid(
    writeonly uimage3D voxel_img,
    uint block_id,
    vec3 vertex_tint,
    vec3 mid_block_attr,
    vec2 light_levels
) {
    vec3 model_pos = gl_Vertex.xyz + mid_block_attr * (1.0 / 64.0);
    vec3 view_pos = (gl_ModelViewMatrix * vec4(model_pos, 1.0)).xyz;
    vec3 scene_pos = (shadowModelViewInverse * vec4(view_pos, 1.0)).xyz;
    vec3 voxel_pos = scene_to_voxel_space(scene_pos);

    // Grid corner test
    vec3 block_pos = (gl_ModelViewMatrix * vec4(gl_Vertex.xyz, 1.0)).xyz;
    block_pos = (shadowModelViewInverse * vec4(block_pos, 1.0)).xyz;
    block_pos = fract(block_pos + cameraPosition);
    bool at_corner = is_voxel_corner(block_pos, (1.0 / 16.0) - 1e-3);

    block_id = max(block_id, 1u);

    // Nether stem emission mapping
    if (19u <= block_id && block_id < 23u) block_id = 46u;
    if (23u <= block_id && block_id < 27u) block_id = 58u;

    bool is_translucent = (block_id == 5u || block_id == 14u || block_id == 15u || (80u <= block_id && block_id < 96u));
    bool is_emitter = (32u <= block_id && block_id < 80u);

    if (should_voxelize(block_id, at_corner) && is_inside_voxel_volume(voxel_pos)) {
        ivec3 coord = clamp_to_voxel_grid(ivec3(voxel_pos));
        uvec4 packed_data = pack_voxel_data(block_id, light_levels.x, light_levels.y, vertex_tint, is_translucent, is_emitter);
        imageStore(voxel_img, coord, packed_data);
    }
}

#endif // PROGRAM_SHADOW

#endif // INCLUDE_LIGHTING_VOXEL_UPDATE

