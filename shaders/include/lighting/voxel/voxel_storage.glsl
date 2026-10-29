#if !defined INCLUDE_LIGHTING_VOXEL_STORAGE
#define INCLUDE_LIGHTING_VOXEL_STORAGE

#include "voxel_constants.glsl"
#include "voxel_palette.glsl"

struct VoxelSample {
    uint block_id;
    vec3 color;
    float block_light;
    float sky_light;
    uint shape_class;
    bool is_solid;
    bool is_translucent;
    bool is_emitter;
};

// Pack/unpack a full-RGB albedo into 15 bits (RGB555). The voxel image is a
// single-channel R32UI 3D image, so each texel is one deterministic 32-bit
// payload. imageAtomicMax() is used by the voxelization pass; the most
// significant fields therefore win in a write race:
//
//   bits  0..14 : albedo RGB555 (15 bits)
//   bits 15..18 : block light (4 bits, 0..15)
//   bits 19..21 : shape class (3 bits, 0..7)
//   bits 22..24 : flags (3 bits: translucent, emitter, unused)
//   bits 25..31 : block ID (7 bits; block.properties currently stops at 96)
//
// Air is all-zero and always loses to any solid voxel. A voxel with
// block_id == 0 but block_light > 0 is a light-only voxel injected around a
// small emitter; DDA accumulates it without treating it as geometry.
uint pack_unorm_rgb555(vec3 color) {
    uvec3 quantized = uvec3(clamp(color, vec3(0.0), vec3(1.0)) * 31.0 + 0.5);
    return quantized.r | (quantized.g << 5u) | (quantized.b << 10u);
}

vec3 unpack_unorm_rgb555(uint packed) {
    uvec3 quantized = uvec3(
        packed & 0x1Fu,
        (packed >> 5u) & 0x1Fu,
        (packed >> 10u) & 0x1Fu
    );
    return vec3(quantized) * (1.0 / 31.0);
}

// Pack block information into one deterministic 32-bit voxel texel.
uint pack_voxel_data(
    uint block_id,
    float block_light,
    uint shape_class,
    vec3 albedo,
    bool is_translucent,
    bool is_emitter
) {
    uint color = pack_unorm_rgb555(albedo);
    uint block_id7 = block_id & 0x7Fu;
    uint b_light = uint(clamp(block_light * 15.0 + 0.5, 0.0, 15.0));
    uint shape3 = shape_class & 0x7u;
    uint flags = (is_translucent ? 1u : 0u) | (is_emitter ? 2u : 0u);

    return color
        | (b_light << 15u)
        | (shape3 << 19u)
        | (flags << 22u)
        | (block_id7 << 25u);
}

// Unpack voxel cell data from one R32UI texel value.
VoxelSample unpack_voxel_data(uint packed) {
    VoxelSample sample_data;
    sample_data.block_id = (packed >> 25u) & 0x7Fu;
    sample_data.is_solid = sample_data.block_id != 0u;
    sample_data.block_light = float((packed >> 15u) & 0xFu) * (1.0 / 15.0);
    sample_data.sky_light = 0.0;
    sample_data.shape_class = (packed >> 19u) & 0x7u;

    uint flags = (packed >> 22u) & 0x07u;
    sample_data.is_translucent = (flags & 1u) != 0u;
    sample_data.is_emitter = (flags & 2u) != 0u || (sample_data.block_id >= 32u && sample_data.block_id < 80u && sample_data.block_id != 58u && sample_data.block_id != 63u);

    sample_data.color = unpack_unorm_rgb555(packed & 0x7FFFu);

    return sample_data;
}

#endif // INCLUDE_LIGHTING_VOXEL_STORAGE
