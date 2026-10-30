#if !defined INCLUDE_LIGHTING_VOXEL_UPDATE
#define INCLUDE_LIGHTING_VOXEL_UPDATE

#include "voxel_constants.glsl"
#include "voxel_storage.glsl"
#include "/include/utility/color.glsl"

// R7 clipmap stack. Iris clears all three images at frame start; terrain writes
// repopulate the active levels. Inactive levels stay cleared and are not traced.
layout(r32ui) uniform uimage3D voxel_img;
layout(r32ui) uniform uimage3D voxel_mid_img;
layout(r32ui) uniform uimage3D voxel_coarse_img;

#if defined PROGRAM_SHADOW || defined PROGRAM_GBUFFERS_TERRAIN || defined PROGRAM_GBUFFERS_WATER

bool is_voxel_corner(vec3 pos, float tolerance) {
    bvec3 lower = lessThan(pos, vec3(tolerance));
    bvec3 upper = greaterThan(pos, vec3(1.0 - tolerance));
    return all(bvec3(lower.x || upper.x, lower.y || upper.y, lower.z || upper.z));
}

// Only terrain draw calls contribute to the world voxel grid.
// In PROGRAM_GBUFFERS_TERRAIN and PROGRAM_GBUFFERS_WATER this is naturally terrain only.
// In PROGRAM_SHADOW, renderStage ensures entities/particles do not overwrite world voxels.
bool is_voxel_terrain_stage() {
#if defined PROGRAM_GBUFFERS_TERRAIN || defined PROGRAM_GBUFFERS_WATER
    return true;
#elif defined COLORWHEEL
    return true;
#elif defined PROGRAM_SHADOW
#if defined RTGI_VOXELIZE_ENTITIES && RTGI_VOXELIZE_ENTITIES == 1
    if (renderStage == MC_RENDER_STAGE_ENTITIES || renderStage == MC_RENDER_STAGE_BLOCK_ENTITIES) return true;
#endif
    return any(equal(
        ivec4(renderStage),
        ivec4(
            MC_RENDER_STAGE_TERRAIN_SOLID,
            MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED,
            MC_RENDER_STAGE_TERRAIN_CUTOUT,
            MC_RENDER_STAGE_TERRAIN_TRANSLUCENT
        )
    ));
#else
    return false;
#endif
}

uint get_voxel_shape_class(uint block_id, vec3 mid_block_attr, vec3 normal) {
    if (block_id == 2u || block_id == 3u || block_id == 14u || block_id == 15u) {
        return VOXEL_SHAPE_PLANT;
    }
    if (block_id == 80u || (block_id >= 81u && block_id <= 96u)) {
        return VOXEL_SHAPE_GLASS;
    }

    // Fences and panes: thin along horizontal axes
    if (block_id == 30u || block_id == 28u) {
        if (abs(mid_block_attr.x) < 22.0 && abs(mid_block_attr.z) < 22.0) {
            return VOXEL_SHAPE_PANE_OR_FENCE;
        }
    }

    // Half-slabs:
    // mid_block_attr = (midBlock - vertex) * 64.0.
    // For a cut face at y = 0.5, mid_block_attr.y is close to 0.0.
    // Normal pointing UP (normal.y > 0.3) -> top of bottom slab.
    // Normal pointing DOWN (normal.y < -0.3) -> bottom of top slab.
    if (abs(mid_block_attr.y) < 4.0) {
        if (normal.y > 0.3) {
            return VOXEL_SHAPE_SLAB_BOTTOM;
        } else if (normal.y < -0.3) {
            return VOXEL_SHAPE_SLAB_TOP;
        }
    }

    // Side faces of half-slabs:
    // Vertices strictly within [4.0, 30.0] -> bottom half
    if (mid_block_attr.y > 4.0 && mid_block_attr.y < 30.0) {
        return VOXEL_SHAPE_SLAB_BOTTOM;
    }
    // Vertices strictly within [-30.0, -4.0] -> top half
    if (mid_block_attr.y < -4.0 && mid_block_attr.y > -30.0) {
        return VOXEL_SHAPE_SLAB_TOP;
    }

    return VOXEL_SHAPE_CUBE;
}

bool should_voxelize(uint block_id) {
    bool is_transparent_block = (block_id == 1u || block_id == 18u || block_id == 28u || block_id == 30u || block_id == 80u);
    bool is_emitter = (32u <= block_id && block_id < 80u && block_id != 58u && block_id != 63u);
    bool is_non_solid = (block_id == 2u || block_id == 3u || block_id == 14u || block_id == 15u || block_id == 58u);
    bool is_stained_glass = (block_id >= 81u && block_id <= 96u);

    return (!is_non_solid || is_emitter || is_stained_glass)
        && !is_transparent_block
        && is_voxel_terrain_stage();
}

void update_rt_voxel_grid(
    uint block_id,
    vec3 vertex_tint,
    vec3 mid_block_attr,
    vec2 light_levels,
    vec2 mid_tex_coord,
    vec2 tex_coord
) {
    vec3 model_pos = gl_Vertex.xyz + mid_block_attr * (1.0 / 64.0);
    vec3 view_pos = (gl_ModelViewMatrix * vec4(model_pos, 1.0)).xyz;
#ifdef PROGRAM_SHADOW
    vec3 scene_pos = (shadowModelViewInverse * vec4(view_pos, 1.0)).xyz;
#else
    vec3 scene_pos = (gbufferModelViewInverse * vec4(view_pos, 1.0)).xyz;
#endif
    vec3 world_pos = scene_pos + cameraPosition;

    // Remap 0u (default unassigned terrain like stone, dirt, deepslate) to stone ID 4u
#if !defined PROGRAM_GBUFFERS_WATER
    if (block_id == 0u) {
        block_id = 4u;
    }
#endif

    // Nether stem emission mapping
    if (19u <= block_id && block_id < 23u) block_id = 46u;
    if (23u <= block_id && block_id < 27u) block_id = 58u;

    // The packed voxel payload has a 7-bit block ID. Current IDs stop at 96;
    // map anything unexpected to stone instead of wrapping into emitter IDs.
    if (block_id > 127u) {
        block_id = 4u;
    }

    bool is_translucent = (block_id == 5u || block_id == 14u || block_id == 15u || (80u <= block_id && block_id <= 96u));
    bool is_emitter = (32u <= block_id && block_id < 80u && block_id != 58u && block_id != 63u);

    if (should_voxelize(block_id)) {
        vec2 sample_uv = (mid_tex_coord != vec2(0.0)) ? mid_tex_coord : tex_coord;
        vec4 tex_sample = textureLod(tex, sample_uv, 0.0);
        if (tex_sample.a < 0.1 && sample_uv != tex_coord) {
            tex_sample = textureLod(tex, tex_coord, 0.0);
        }
        vec3 albedo_srgb = (tex_sample.a > 0.05) ? (tex_sample.rgb * vertex_tint) : vertex_tint;
        vec3 linear_albedo = srgb_eotf_inv(clamp01(albedo_srgb));

        vec3 voxel_albedo = is_emitter ? get_voxel_light_color(block_id) : linear_albedo;
        // Only actual light-emitting blocks (torches, lanterns, glowstone, lava)
        // store block light in the voxel grid. Solid blocks (stone, wood, quartz, etc.)
        // must NEVER store vanilla lightmap: because voxel cells lack face orientation,
        // any light on an exterior face (roof, outer wall) bleeds through to the interior.
        float voxel_block_light = is_emitter ? 1.0 : 0.0;
        uint shape_class = get_voxel_shape_class(block_id, mid_block_attr, gl_Normal);

        uint packed_data = pack_voxel_data(
            block_id,
            voxel_block_light,
            shape_class,
            voxel_albedo,
            is_translucent,
            is_emitter
        );
        // Atomic max makes the final voxel independent of vertex write order.
        // The packed layout puts block ID in the high bits, so a solid /
        // higher-ID voxel always wins over air. Coarse levels reuse the same
        // representative payload as conservative occupancy cubes; they do not
        // sum emitter power across the blocks folded into one coarse cell.
        for (int level = 0; level < RT_COVERAGE_LEVELS; ++level) {
            float scale = rt_clip_scale(level);
            vec3 local = (world_pos - rt_clip_origin_world(level)) / scale;
            if (any(lessThan(local, vec3(0.0)))
                || any(greaterThanEqual(local, rt_clipmap_size_f))) {
                continue;
            }
            ivec3 coord = rt_clip_texel(ivec3(floor(local)));
            uint payload = (level == 0)
                ? packed_data
                : (packed_data & ~(0x7u << 19u)); // force VOXEL_SHAPE_CUBE

            if (level == 0) {
                imageAtomicMax(voxel_img, coord, payload);
            } else if (level == 1) {
                imageAtomicMax(voxel_mid_img, coord, payload);
            } else {
                imageAtomicMax(voxel_coarse_img, coord, payload);
            }
        }
    }
}

#endif // PROGRAM_SHADOW || PROGRAM_GBUFFERS_TERRAIN || PROGRAM_GBUFFERS_WATER

#endif // INCLUDE_LIGHTING_VOXEL_UPDATE

