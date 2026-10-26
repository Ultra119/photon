#if !defined INCLUDE_LIGHTING_VOXEL_PALETTE
#define INCLUDE_LIGHTING_VOXEL_PALETTE

// global.glsl included by parent program
#include "/include/lighting/voxel/light_colors.glsl"

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
    mat.is_solid = true;
    mat.is_translucent = false;

    if (block_id == 0u) {
        mat.albedo = vec3(0.0);
        mat.is_solid = false;
        return mat;
    }

    // Check emissive blocks
    if (block_id >= 32u && block_id < 80u) {
        uint light_idx = clamp(block_id - 32u, 0u, 47u);
        mat.emission = voxel_light_color_table[light_idx] * 2.5;
        mat.roughness = 0.5;
        mat.is_solid = true;
    }

    // Base block types according to block.properties
    switch (block_id) {
        // Water
        case 1u:
            mat.albedo = vec3(0.05, 0.15, 0.25);
            mat.roughness = 0.05;
            mat.is_solid = false;
            mat.is_translucent = true;
            break;

        // Small plants (grass, short_grass, flowers, dandelion, poppy, fern)
        case 2u:
            mat.albedo = (fallback_color.g > 0.05) ? fallback_color * 0.40 : vec3(0.12, 0.22, 0.06);
            mat.roughness = 0.90;
            mat.is_solid = false;
            break;

        // Tall plants (sunflowers, lilac, rose bush)
        case 3u:
            mat.albedo = (fallback_color.g > 0.05) ? fallback_color * 0.40 : vec3(0.12, 0.22, 0.06);
            mat.roughness = 0.90;
            mat.is_solid = false;
            break;

        // Default Stone / unassigned terrain
        case 4u:
            mat.albedo = vec3(0.35, 0.35, 0.35);
            mat.roughness = 0.80;
            mat.is_solid = true;
            break;

        // Leaves & foliage
        case 5u:
            mat.albedo = (fallback_color.g > 0.05) ? fallback_color * 0.30 : vec3(0.06, 0.14, 0.03);
            mat.roughness = 0.90;
            mat.sss_amount = 0.0;
            mat.is_solid = true;
            mat.is_translucent = true;
            break;

        // Dirt, grass block, coarse dirt, stone, cobblestone, deepslate
        case 6u:
            mat.albedo = (fallback_color.g > fallback_color.r * 1.05 && fallback_color.g > 0.08) ? fallback_color * 0.40 : vec3(0.35, 0.30, 0.25);
            mat.roughness = 0.88;
            mat.is_solid = true;
            break;

        // Sand, sandstone
        case 7u:
            mat.albedo = vec3(0.72, 0.65, 0.46);
            mat.roughness = 0.88;
            mat.is_solid = true;
            break;

        // Ice, packed ice, blue ice
        case 8u:
            mat.albedo = vec3(0.75, 0.85, 0.95);
            mat.roughness = 0.20;
            mat.sss_amount = 0.25;
            mat.is_solid = true;
            mat.is_translucent = true;
            break;

        // Red sand, red sandstone
        case 9u:
            mat.albedo = vec3(0.68, 0.36, 0.18);
            mat.roughness = 0.88;
            mat.is_solid = true;
            break;

        // Wood planks / logs
        case 10u:
            mat.albedo = vec3(0.48, 0.32, 0.18);
            mat.roughness = 0.75;
            mat.is_solid = true;
            break;

        // Terracotta
        case 11u:
            mat.albedo = vec3(0.55, 0.35, 0.25);
            mat.roughness = 0.85;
            mat.is_solid = true;
            break;

        // Metals (Iron, gold, copper)
        case 12u:
            mat.albedo = vec3(0.70, 0.70, 0.70);
            mat.roughness = 0.40;
            mat.is_solid = true;
            break;

        // Netherrack, nether bricks
        case 13u:
            mat.albedo = vec3(0.38, 0.12, 0.12);
            mat.roughness = 0.90;
            mat.is_solid = true;
            break;

        // Strong SSS materials (azalea, sugar cane, bamboo, vine, lily pad)
        case 14u:
            mat.albedo = (fallback_color.g > 0.05) ? fallback_color * 0.30 : vec3(0.10, 0.20, 0.05);
            mat.roughness = 0.80;
            mat.is_solid = false;
            mat.is_translucent = true;
            break;

        // Weak SSS materials (leaf litter, pink petals, cobwebs, wool)
        case 15u:
            mat.albedo = clamp(fallback_color, vec3(0.10), vec3(0.50));
            mat.roughness = 0.70;
            mat.is_solid = false; // Never block rays! Leaf litter & petals are flat decals!
            break;

        // Clear glass, glass panes, snow layer, rails, carpets
        case 80u:
            mat.albedo = vec3(0.95);
            mat.roughness = 0.04;
            mat.is_solid = false;
            mat.is_translucent = true;
            break;

        // Stained glass / tinted translucent (10081 - 10096)
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
        case 95u:
        case 96u: {
            uint tint_idx = clamp(block_id - 81u, 0u, 15u);
            mat.albedo = voxel_tint_color_table[tint_idx];
            mat.roughness = 0.04;
            mat.is_solid = false;
            mat.is_translucent = true;
            break;
        }

        default:
            // Fallback to reasonable albedo
            mat.albedo = clamp(fallback_color, vec3(0.08), vec3(0.45));
            mat.is_solid = true;
            break;
    }

    return mat;
}

#endif // INCLUDE_LIGHTING_VOXEL_PALETTE

