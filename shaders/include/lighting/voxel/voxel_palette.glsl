#if !defined INCLUDE_LIGHTING_VOXEL_PALETTE
#define INCLUDE_LIGHTING_VOXEL_PALETTE

#include "/include/global.glsl"
#include "/include/lighting/lpv/light_colors.glsl"

struct VoxelMaterial {
    vec3 albedo;
    vec3 emission;
    float roughness;
    float sss_amount;
    bool is_solid;
    bool is_translucent;
};

// Physically calibrated block albedos & materials
VoxelMaterial get_voxel_material(uint block_id, vec3 fallback_color) {
    VoxelMaterial mat;
    mat.albedo = fallback_color;
    mat.emission = vec3(0.0);
    mat.roughness = 0.85;
    mat.sss_amount = 0.0;
    mat.is_solid = (block_id != 0u);
    mat.is_translucent = false;

    if (!mat.is_solid) {
        mat.albedo = vec3(0.0);
        return mat;
    }

    // Check emissive blocks
    if (block_id >= 32u && block_id < 80u) {
        uint light_idx = clamp(block_id - 32u, 0u, 47u);
        mat.emission = light_color[light_idx] * 0.25;
        mat.roughness = 0.5;
    }

    // Base block types according to block.properties
    switch (block_id) {
        // Water
        case 1u:
            mat.albedo = vec3(0.05, 0.15, 0.25);
            mat.roughness = 0.05;
            mat.is_translucent = true;
            break;

        // Grass block
        case 2u:
            mat.albedo = (fallback_color.g > 0.05) ? fallback_color : vec3(0.22, 0.42, 0.12);
            mat.roughness = 0.90;
            break;

        // Dirt, coarse dirt, mud, farmland
        case 3u:
            mat.albedo = vec3(0.28, 0.18, 0.10);
            mat.roughness = 0.95;
            break;

        // Stone, cobblestone, andesite, deepslate
        case 4u:
            mat.albedo = vec3(0.35, 0.35, 0.35);
            mat.roughness = 0.80;
            break;

        // Leaves & foliage
        case 5u:
            mat.albedo = (fallback_color.g > 0.05) ? fallback_color : vec3(0.18, 0.38, 0.08);
            mat.roughness = 0.85;
            mat.sss_amount = 0.4;
            mat.is_translucent = true;
            break;

        // Sand, sandstone
        case 6u:
            mat.albedo = vec3(0.68, 0.62, 0.44);
            mat.roughness = 0.88;
            break;

        // Wood planks / logs
        case 7u:
            mat.albedo = vec3(0.42, 0.28, 0.16);
            mat.roughness = 0.75;
            break;

        // Snow & ice
        case 8u:
            mat.albedo = vec3(0.85, 0.88, 0.92);
            mat.roughness = 0.30;
            mat.sss_amount = 0.25;
            break;

        // Metals (Iron, gold, copper)
        case 9u:
            mat.albedo = vec3(0.65, 0.65, 0.65);
            mat.roughness = 0.40;
            break;

        // Bricks, terracotta
        case 10u:
            mat.albedo = vec3(0.48, 0.25, 0.18);
            mat.roughness = 0.85;
            break;

        // Netherrack, nether bricks
        case 11u:
            mat.albedo = vec3(0.32, 0.10, 0.10);
            mat.roughness = 0.90;
            break;

        // End stone, purpur
        case 12u:
            mat.albedo = vec3(0.65, 0.68, 0.48);
            mat.roughness = 0.80;
            break;

        // Strong SSS materials (wax, honey, slime)
        case 14u:
            mat.albedo = fallback_color;
            mat.roughness = 0.50;
            mat.sss_amount = 0.70;
            mat.is_translucent = true;
            break;

        // Weak SSS materials
        case 15u:
            mat.albedo = fallback_color;
            mat.roughness = 0.70;
            mat.sss_amount = 0.35;
            break;

        // Stained glass / tinted translucent
        case 80u:
        case 81u:
        case 82u:
        case 83u:
        case 84u:
        case 85u:
        case 86u:
        case 87u:
        case 88u:
        case 89u:
        case 90u:
        case 91u:
        case 92u:
        case 93u:
        case 94u:
        case 95u: {
            uint tint_idx = clamp(block_id - 80u, 0u, 15u);
            mat.albedo = tint_color[tint_idx];
            mat.roughness = 0.10;
            mat.is_translucent = true;
            break;
        }

        default:
            // Fallback to vertex/texture color
            mat.albedo = max(fallback_color, vec3(0.08));
            break;
    }

    return mat;
}

#endif // INCLUDE_LIGHTING_VOXEL_PALETTE

