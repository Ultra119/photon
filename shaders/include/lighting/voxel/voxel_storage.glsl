#if !defined INCLUDE_LIGHTING_VOXEL_STORAGE
#define INCLUDE_LIGHTING_VOXEL_STORAGE

#include "voxel_constants.glsl"
#include "voxel_palette.glsl"

struct VoxelSample {
    uint block_id;
    vec3 color;
    float block_light;
    float sky_light;
    bool is_solid;
    bool is_translucent;
    bool is_emitter;
};

// Pack block information into voxel cell (including local blocklight and skylight)
uvec4 pack_voxel_data(uint block_id, float block_light, float sky_light, vec3 albedo, bool is_translucent, bool is_emitter) {
    uint b_light = uint(clamp(block_light * 255.0 + 0.5, 0.0, 255.0));
    uint s_light = uint(clamp(sky_light * 255.0 + 0.5, 0.0, 255.0));
    uint flags = (is_translucent ? 1u : 0u) | (is_emitter ? 2u : 0u);
    uint tint_g = uint(clamp(albedo.g * 63.0 + 0.5, 0.0, 63.0));
    return uvec4(block_id & 0xFFu, b_light, s_light, (tint_g << 2u) | (flags & 0x03u));
}

// Unpack voxel cell data
VoxelSample unpack_voxel_data(uvec4 raw_data) {
    VoxelSample sample_data;
    sample_data.block_id = raw_data.r;
    sample_data.is_solid = (raw_data.r != 0u);
    sample_data.block_light = float(raw_data.g) / 255.0;
    sample_data.sky_light = float(raw_data.b) / 255.0;

    uint flags = raw_data.a & 0x03u;
    sample_data.is_translucent = (flags & 1u) != 0u;
    sample_data.is_emitter = (flags & 2u) != 0u || (sample_data.block_id >= 32u && sample_data.block_id < 80u);

    float tint_g = float(raw_data.a >> 2u) / 63.0;
    sample_data.color = vec3(tint_g);

    return sample_data;
}

#endif // INCLUDE_LIGHTING_VOXEL_STORAGE

