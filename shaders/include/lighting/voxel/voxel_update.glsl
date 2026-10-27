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

// Only terrain shadow draw calls should contribute to the world voxel grid.
// Otherwise entities, block entities, particles, outlines, etc. can overwrite
// world voxels with local geometry. COLORWHEEL wrappers do not provide a
// reliable renderStage in the same way, so they keep the upstream fallback.
bool is_voxel_terrain_stage() {
#if defined COLORWHEEL
    return true;
#else
    return any(equal(
        ivec4(renderStage),
        ivec4(
            MC_RENDER_STAGE_TERRAIN_SOLID,
            MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED,
            MC_RENDER_STAGE_TERRAIN_CUTOUT,
            MC_RENDER_STAGE_TERRAIN_TRANSLUCENT
        )
    ));
#endif
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
    vec2 light_levels
) {
    vec3 model_pos = gl_Vertex.xyz + mid_block_attr * (1.0 / 64.0);
    vec3 view_pos = (gl_ModelViewMatrix * vec4(model_pos, 1.0)).xyz;
    vec3 scene_pos = (shadowModelViewInverse * vec4(view_pos, 1.0)).xyz;
    vec3 voxel_pos = scene_to_voxel_space(scene_pos);

    // Remap 0u (default unassigned terrain like stone, dirt, deepslate) to stone ID 4u
    if (block_id == 0u) {
        block_id = 4u;
    }

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

    if (should_voxelize(block_id) && is_inside_voxel_volume(voxel_pos)) {
        ivec3 coord = clamp_to_voxel_grid(ivec3(voxel_pos));
        vec3 voxel_albedo = is_emitter ? get_voxel_light_color(block_id) : vertex_tint;
        float voxel_block_light = is_emitter ? 1.0 : light_levels.x;

        uint packed_data = pack_voxel_data(
            block_id,
            voxel_block_light,
            light_levels.y,
            voxel_albedo,
            is_translucent,
            is_emitter
        );
        // Atomic max makes the final voxel independent of vertex write order.
        // The packed layout puts block ID and light levels in the high bits,
        // so a solid / brighter / higher-ID voxel always wins over air.
        imageAtomicMax(voxel_img, coord, packed_data);

        // Inject a camera-independent radial light field around emitters.
        // Light-only voxels have block_id = 0, so they never overwrite solid
        // geometry under imageAtomicMax(); DDA accumulates them volumetrically.
        // Line-of-sight is verified against solid blocks so light cannot
        // penetrate through solid walls, floors, or ceilings.
        // gl_VertexID gating reduces duplicate writes from multi-vertex models.
#if RTGI_POINT_LIGHT_STRENGTH > 0
        if (is_emitter && is_voxel_light_source(block_id) && (gl_VertexID & 3) == 0) {
            vec3 point_light_color = get_voxel_light_color(block_id);
            const int radius = RTGI_POINT_LIGHT_RADIUS;
            const float radius_f = float(radius);

            for (int z = -radius; z <= radius; ++z) {
                for (int y = -radius; y <= radius; ++y) {
                    for (int x = -radius; x <= radius; ++x) {
                        ivec3 offset = ivec3(x, y, z);
                        if (offset == ivec3(0)) {
                            continue;
                        }

                        float dist = length(vec3(offset));
                        if (dist > radius_f) {
                            continue;
                        }

                        float attenuation = exp(-0.55 * dist)
                            * (1.0 - smoothstep(radius_f - 1.0, radius_f, dist))
                            * RTGI_POINT_LIGHT_STRENGTH;

                        if (attenuation < 0.02) {
                            continue;
                        }

                        ivec3 light_coord = coord + offset;
                        if (!is_inside_voxel_grid(light_coord)) {
                            continue;
                        }

                        // Test occlusion along the path from coord to light_coord
                        bool occluded = false;
                        int max_step = max(abs(offset.x), max(abs(offset.y), abs(offset.z)));
                        for (int s = 1; s <= max_step; ++s) {
                            ivec3 check_coord = coord + ivec3(round(vec3(offset) * (float(s) / float(max_step))));
                            if (!is_inside_voxel_grid(check_coord)) {
                                occluded = true;
                                break;
                            }
                            uint occ_packed = imageLoad(voxel_img, check_coord).r;
                            uint occ_id = (occ_packed >> 25u) & 0x7Fu;
                            // Any solid block (stone, wood, dirt, quartz, etc.) blocks light
                            if (occ_id >= 4u && occ_id < 80u) {
                                occluded = true;
                                break;
                            }
                        }

                        if (occluded) {
                            continue;
                        }

                        uint light_payload = pack_voxel_data(
                            0u,
                            attenuation,
                            0.0,
                            point_light_color,
                            false,
                            false
                        );
                        imageAtomicMax(voxel_img, light_coord, light_payload);
                    }
                }
            }
        }
#endif
    }
}

#endif // PROGRAM_SHADOW

#endif // INCLUDE_LIGHTING_VOXEL_UPDATE

