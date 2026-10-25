#if !defined INCLUDE_LIGHTING_VOXEL_STORAGE
#define INCLUDE_LIGHTING_VOXEL_STORAGE

#include "voxel_constants.glsl"
#include "voxel_palette.glsl"

struct VoxelSample {
    uint block_id;
    vec3 color;
    bool is_solid;
    bool is_translucent;
    bool is_emitter;
};

// Pack block information into voxel cell
uvec4 pack_voxel_data(uint block_id, vec3 albedo, bool is_translucent, bool is_emitter) {
    uvec3 quantized_color = uvec3(clamp(albedo * 255.0 + 0.5, vec3(0.0), vec3(255.0)));
    uint flags = (is_translucent ? 1u : 0u) | (is_emitter ? 2u : 0u);
    return uvec4(block_id & 0xFFu, quantized_color.r, quantized_color.g, (quantized_color.b & 0xFCu) | (flags & 0x03u));
}

// Unpack voxel cell data
VoxelSample unpack_voxel_data(uvec4 raw_data) {
    VoxelSample sample_data;
    sample_data.block_id = raw_data.r;
    sample_data.is_solid = (raw_data.r != 0u);

    vec3 rgb;
    rgb.r = float(raw_data.g) / 255.0;
    rgb.g = float(raw_data.b) / 255.0;
    rgb.b = float(raw_data.a & 0xFCu) / 255.0;
    sample_data.color = rgb;

    uint flags = raw_data.a & 0x03u;
    sample_data.is_translucent = (flags & 1u) != 0u;
    sample_data.is_emitter = (flags & 2u) != 0u || (sample_data.block_id >= 32u && sample_data.block_id < 80u);

    return sample_data;
}

#endif // INCLUDE_LIGHTING_VOXEL_STORAGE

