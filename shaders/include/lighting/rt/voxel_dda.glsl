#if !defined INCLUDE_LIGHTING_RT_VOXEL_DDA
#define INCLUDE_LIGHTING_RT_VOXEL_DDA

// global.glsl included by parent program
#include "/include/lighting/voxel/voxel_constants.glsl"
#include "/include/lighting/voxel/voxel_storage.glsl"
#include "/include/lighting/shadows/distortion.glsl"
#include "/include/lighting/colors/blocklight_color.glsl"

// Lambertian surfaces convert irradiance to radiance with 1/pi. Voxel DDA
// only stores irradiance-like sun/sky/blocklight terms, so the bounce must be
// divided by pi before being accumulated as GI radiance.
const float voxel_bounce_rcp_pi = 0.31830988618;

// Deterministic ray component safety: avoids division by zero and planar
// seam lock without injecting random angular jitter.
vec3 safe_ray_dir(vec3 dir) {
    const float eps = 1e-5;
    return vec3(
        abs(dir.x) < eps ? (dir.x >= 0.0 ? eps : -eps) : dir.x,
        abs(dir.y) < eps ? (dir.y >= 0.0 ? eps : -eps) : dir.y,
        abs(dir.z) < eps ? (dir.z >= 0.0 ? eps : -eps) : dir.z
    );
}

// Stage 5: Analytic Ray-AABB intersection for sub-block shapes.
// Williams et al. slab method with voxel-entry normal fallback.
bool intersect_sub_box(
    vec3 ray_start,
    vec3 inv_dir,
    vec3 box_min,
    vec3 box_max,
    float seg_start,
    float seg_end,
    vec3 voxel_entry_normal,
    out float hit_t,
    out vec3 hit_normal
) {
    vec3 t0 = (box_min - ray_start) * inv_dir;
    vec3 t1 = (box_max - ray_start) * inv_dir;
    vec3 tnear = min(t0, t1);
    vec3 tfar = max(t0, t1);

    float tenter = max(max(tnear.x, tnear.y), tnear.z);
    float texit = min(min(tfar.x, tfar.y), tfar.z);

    if (tenter <= texit && texit >= seg_start && tenter <= seg_end) {
        hit_t = max(tenter, seg_start);
        if (tenter > seg_start + 1e-4) {
            if (tenter == tnear.x) hit_normal = vec3(-sign(inv_dir.x), 0.0, 0.0);
            else if (tenter == tnear.y) hit_normal = vec3(0.0, -sign(inv_dir.y), 0.0);
            else hit_normal = vec3(0.0, 0.0, -sign(inv_dir.z));
        } else {
            hit_normal = voxel_entry_normal;
        }
        return true;
    }
    return false;
}

bool test_voxel_shape_hit(
    uint shape_class,
    ivec3 voxel_coord,
    vec3 ray_start,
    vec3 inv_dir,
    float seg_start,
    float seg_end,
    vec3 voxel_entry_normal,
    out float hit_t,
    out vec3 hit_normal
) {
    vec3 v = vec3(voxel_coord);
    if (shape_class == VOXEL_SHAPE_CUBE) {
        return intersect_sub_box(ray_start, inv_dir, v, v + vec3(1.0), seg_start, seg_end, voxel_entry_normal, hit_t, hit_normal);
    } else if (shape_class == VOXEL_SHAPE_SLAB_BOTTOM) {
        return intersect_sub_box(ray_start, inv_dir, v, v + vec3(1.0, 0.5, 1.0), seg_start, seg_end, voxel_entry_normal, hit_t, hit_normal);
    } else if (shape_class == VOXEL_SHAPE_SLAB_TOP) {
        return intersect_sub_box(ray_start, inv_dir, v + vec3(0.0, 0.5, 0.0), v + vec3(1.0, 1.0, 1.0), seg_start, seg_end, voxel_entry_normal, hit_t, hit_normal);
    } else if (shape_class == VOXEL_SHAPE_PANE_OR_FENCE) {
        return intersect_sub_box(ray_start, inv_dir, v + vec3(0.375, 0.0, 0.375), v + vec3(0.625, 1.0, 0.625), seg_start, seg_end, voxel_entry_normal, hit_t, hit_normal);
    } else if (shape_class == VOXEL_SHAPE_STAIRS) {
        float t1; vec3 n1;
        bool h1 = intersect_sub_box(ray_start, inv_dir, v, v + vec3(1.0, 0.5, 1.0), seg_start, seg_end, voxel_entry_normal, t1, n1);
        float t2; vec3 n2;
        bool h2 = intersect_sub_box(ray_start, inv_dir, v + vec3(0.0, 0.5, 0.0), v + vec3(0.5, 1.0, 1.0), seg_start, seg_end, voxel_entry_normal, t2, n2);
        if (h1 && h2) {
            if (t1 < t2) { hit_t = t1; hit_normal = n1; }
            else { hit_t = t2; hit_normal = n2; }
            return true;
        } else if (h1) {
            hit_t = t1; hit_normal = n1; return true;
        } else if (h2) {
            hit_t = t2; hit_normal = n2; return true;
        }
        return false;
    }
    return intersect_sub_box(ray_start, inv_dir, v, v + vec3(1.0), seg_start, seg_end, voxel_entry_normal, hit_t, hit_normal);
}

struct VoxelHit {
    bool hit;
    vec3 hit_pos;
    vec3 hit_normal;
    vec3 radiance;
    float distance;
    vec3 transmittance;
    float sky_weight;
    vec3 accumulated_light;
    vec3 albedo;
};

// Camera-independent sun visibility: march the hit level's voxel grid toward
// the light until an occluder or the distance budget. This replaces the raster
// cascade lookup: Iris shadowModelView/shadowProjection describe CASCADE 0 — a
// small camera-fitted box (shadowIntervalSize = 2.0) that returned
// "shadowed" everywhere outside it. That box edge followed the camera frustum
// (brightness steps and a ~5-block camera-locked line on walls/floor when the
// view pitch changed), raster shadow seams leaked sun at grazing angles, and
// every bounce beyond the box was silently killed. A voxel march is stable in
// world space and occludes against the same geometry the GI ray sees.
const float voxel_sun_shadow_dist = 48.0;
const int voxel_sun_shadow_max_steps = 48;

float trace_sun_visibility(
    usampler3D voxel_grid,
    int level,
    vec3 start_scene,
    vec3 l_dir_in
) {
    // safe_ray_dir keeps axis-aligned light directions from producing
    // infinite/NaN DDA inv_dir terms when the origin sits on a grid plane.
    vec3 l_dir = safe_ray_dir(l_dir_in);
    float scale = rt_clip_scale(level);
    vec3 origin_scene = rt_clip_origin_scene(level);

    vec3 start_level = (start_scene - origin_scene) / scale;
    vec3 dir_level = l_dir / scale;
    vec3 inv_dir_level = 1.0 / dir_level;

    vec3 t0 = (vec3(0.0) - start_level) * inv_dir_level;
    vec3 t1 = (rt_clipmap_size_f - start_level) * inv_dir_level;
    vec3 tnear = min(t0, t1);
    vec3 tfar = max(t0, t1);
    float tenter = max(max(tnear.x, tnear.y), tnear.z);
    float texit = min(min(tfar.x, tfar.y), tfar.z);
    float max_dist_level = voxel_sun_shadow_dist / scale;
    float seg_end = min(texit, max_dist_level);
    if (seg_end < max(tenter, 0.0)) {
        // The light direction leaves this level's grid immediately: no
        // occluder within range at this resolution.
        return 1.0;
    }

    float t = max(tenter, 0.0) + 1e-4;
    ivec3 current_voxel = ivec3(floor(start_level + dir_level * t));

    vec3 step_dir = sign(dir_level);
    vec3 delta_t = abs(inv_dir_level);
    vec3 t_max =
        (step_dir * (vec3(current_voxel) - start_level) + step_dir * 0.5 + 0.5)
        * delta_t;
    vec3 mask;

    for (int i = 0; i < voxel_sun_shadow_max_steps; ++i) {
        if (!is_inside_voxel_grid(current_voxel) || t > seg_end) break;

        // i == 0 is the (biased) origin cell on the hit face — never occlude
        // against the surface the march started from.
        if (i > 0) {
            uint packed = texelFetch(voxel_grid, rt_clip_texel(current_voxel), 0).r;
            VoxelSample sample_data = unpack_voxel_data(packed);
            if (sample_data.block_id != 0u) {
                VoxelMaterial mat =
                    get_voxel_material(sample_data.block_id, sample_data.color);
                // Glass/tinted materials are non-solid in the material table
                // and are skipped, matching the main loop's transmission.
                if (mat.is_solid || sample_data.is_emitter) {
                    return 0.0;
                }
            }
        }

        float next_t = min(min(t_max.x, t_max.y), t_max.z);
        if (next_t > seg_end) break;
        if (t_max.x < t_max.y) {
            mask = (t_max.x < t_max.z) ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0);
        } else {
            mask = (t_max.y < t_max.z) ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
        }
        t = next_t;
        t_max += mask * delta_t;
        current_voxel += ivec3(mask * step_dir);
    }

    return 1.0;
}

// ---------------------------------------------------------------------------
// R7 nested clipmap traversal
// ---------------------------------------------------------------------------

VoxelHit make_miss_voxel_hit(vec3 ray_origin_scene, vec3 ray_dir, float max_dist) {
    VoxelHit result;
    result.hit = false;
    result.hit_pos = ray_origin_scene + ray_dir * max_dist;
    result.hit_normal = -ray_dir;
    result.radiance = vec3(0.0);
    result.distance = max_dist;
    result.transmittance = vec3(1.0);
    result.sky_weight = 0.0;
    result.accumulated_light = vec3(0.0);
    result.albedo = vec3(0.0);
    return result;
}

void shade_voxel_hit(
    inout VoxelHit result,
    VoxelSample sample_data,
    VoxelMaterial mat,
    vec3 hit_face_scene,
    vec3 hit_norm,
    vec3 ray_transmittance,
    usampler3D voxel_grid,
    int level,
    vec3 direct_sun_color,
    vec3 l_dir
) {
    result.hit = true;
    result.hit_normal = hit_norm;
    result.hit_pos = hit_face_scene;
    result.transmittance = ray_transmittance;

    float NoL = max(0.0, dot(hit_norm, l_dir));
    float sun_vis = 0.0;
    if (NoL > 0.0) {
        // Voxel-space sun visibility (see trace_sun_visibility): world-stable,
        // no dependence on the camera-fitted raster cascade box.
        vec3 shadow_start = hit_face_scene + hit_norm * 0.05 + l_dir * 0.02;
        sun_vis = trace_sun_visibility(voxel_grid, level, shadow_start, l_dir);
    }
    vec3 sun_irradiance = direct_sun_color * (sun_vis * NoL);

    // Solid voxels never inject analytic sky/block ambient. Emission is
    // intrinsic radiance and is not divided by pi.
    vec3 emission_radiance = mat.emission;
    vec3 bounce_albedo = mat.albedo;
    if (sample_data.block_id == 5u || sample_data.block_id == 14u || sample_data.block_id == 2u) {
        bounce_albedo *= 0.35;
    }
    result.albedo = bounce_albedo;

    vec3 bounce_radiance = bounce_albedo * sun_irradiance * voxel_bounce_rcp_pi;
    vec3 sky_lit = bounce_radiance;
    vec3 local_lit = emission_radiance;
    float sky_lum = dot(sky_lit, luminance_weights);
    float local_lum = dot(local_lit, luminance_weights);
    result.sky_weight = clamp01(sky_lum / max(sky_lum + local_lum, eps));
    // Outgoing radiance at the hit is unattenuated; callers multiply by the
    // accumulated transmittance exactly once (including across clip levels).
    result.radiance = emission_radiance + bounce_radiance;
}

// Trace one clipmap level. Distances are world blocks from the original ray
// origin. level_exit_world reports where the ray leaves this level's cube, so
// the next coarser level can start outside the finer coverage and never shade
// the same surface twice.
VoxelHit trace_voxel_level(
    usampler3D voxel_grid,
    int level,
    vec3 ray_origin_scene,
    vec3 surface_normal,
    vec3 dda_dir,
    float t_start_world,
    float max_dist_world,
    float dither,
    vec3 direct_sun_color,
    vec3 l_dir,
    out float level_exit_world
) {
    float scale = rt_clip_scale(level);
    vec3 origin_scene = rt_clip_origin_scene(level);
    vec3 base_scene = ray_origin_scene + dda_dir * t_start_world;
    vec3 dir_level = dda_dir / scale;
    vec3 inv_dir_level = 1.0 / dir_level;
    float max_dist_level = max(0.0, max_dist_world - t_start_world) / scale;

    // A small normal/directional bias clears the raster surface seam. Coarser
    // levels start just outside the finer cube, so they only need a forward
    // bias. The per-ray dither (threaded through from the caller — previously
    // dead) nudges the origin along the ray so exactly-on-boundary starts and
    // face/corner-aligned slides do not repeat the same leak every frame;
    // DDA tie-breaks shift, turning persistent seam streaks into temporally
    // averaged noise. Probe updates pass a per-ray-index (frame-stable) value
    // so the probe field itself does not gain noise.
    vec3 start_scene = base_scene + dda_dir * (0.02 + 0.008 * dither);
    if (level == 0) start_scene += surface_normal * 0.03;
    vec3 start_level = (start_scene - origin_scene) / scale;

    level_exit_world = t_start_world;
    VoxelHit result = make_miss_voxel_hit(ray_origin_scene, dda_dir, max_dist_world);

    // Clip the biased ray to this level's [0, dim]^3 cube in level-local units.
    vec3 t0 = (vec3(0.0) - start_level) * inv_dir_level;
    vec3 t1 = (rt_clipmap_size_f - start_level) * inv_dir_level;
    vec3 tnear = min(t0, t1);
    vec3 tfar = max(t0, t1);
    float tenter = max(max(tnear.x, tnear.y), tnear.z);
    float texit = min(min(tfar.x, tfar.y), tfar.z);
    if (texit < max(tenter, 0.0) || texit < 0.0) {
        return result;
    }
    level_exit_world = t_start_world + texit * scale;

    float seg_start = max(tenter, 0.0) + 1e-4;
    float seg_end = min(texit, max_dist_level);
    if (seg_start > seg_end) {
        return result;
    }

    ivec3 current_voxel = ivec3(floor(start_level + dir_level * seg_start));

    ivec3 origin_voxel = ivec3(floor((ray_origin_scene - surface_normal * 0.05 - origin_scene) / scale));
    ivec3 origin_voxel_ray = ivec3(floor((ray_origin_scene - dda_dir * 0.05 - origin_scene) / scale));

    vec3 step_dir = sign(dir_level);
    vec3 delta_t = abs(inv_dir_level);
    vec3 t_max = (step_dir * (vec3(current_voxel) - start_level) + step_dir * 0.5 + 0.5) * delta_t;
    // Entry face of the first voxel: the axis whose cube-boundary crossing
    // achieved tenter. A zero mask made first-iteration hits use
    // -sign(dir) — an unnormalized diagonal — as the shading normal,
    // producing over-bright garbage NoL exactly at corners. The mask is
    // overwritten with the next step axis before the first t_max update, so
    // this only feeds the entry-normal path.
    vec3 mask;
    if (tenter == tnear.x) mask = vec3(1.0, 0.0, 0.0);
    else if (tenter == tnear.y) mask = vec3(0.0, 1.0, 0.0);
    else mask = vec3(0.0, 0.0, 1.0);
    float t = seg_start;
    vec3 ray_transmittance = vec3(1.0);

    for (int i = 0; i < voxel_dda_max_steps; ++i) {
        if (!is_inside_voxel_grid(current_voxel) || t > seg_end) break;

        float next_t = min(min(t_max.x, t_max.y), t_max.z);
        float clamped_next_t = min(next_t, seg_end);

        if (current_voxel != origin_voxel && current_voxel != origin_voxel_ray) {
            uint packed = texelFetch(voxel_grid, rt_clip_texel(current_voxel), 0).r;
            VoxelSample sample_data = unpack_voxel_data(packed);
            if (sample_data.block_id != 0u) {
                VoxelMaterial mat = get_voxel_material(sample_data.block_id, sample_data.color);
                if (level > 0) {
                    // Coarse clipmap cells are occupancy only. imageAtomicMax
                    // lets a single torch/lamp block ID win the whole 2^3/4^3
                    // cell; shading that cell with the emitter's palette
                    // radiance would turn one distant light into a giant
                    // emissive cube (popping far-field fireflies).
                    mat.emission = vec3(0.0);
                }
                if (sample_data.block_id >= 81u && sample_data.block_id <= 96u) {
                    ray_transmittance *= mat.albedo;
                } else if (sample_data.block_id == 80u) {
                    // Clear glass passes through.
                } else if (mat.is_solid || sample_data.is_emitter) {
                    float hit_t;
                    vec3 hit_norm;
                    vec3 entry_norm = (dot(mask, mask) > 0.5) ? (-mask * step_dir) : -sign(dir_level);
                    // Fine level keeps sub-block shapes. Coarse cells are
                    // conservative occupancy cubes; their payload is a
                    // representative material, not a sum of emitter power.
                    uint shape = (level == 0) ? sample_data.shape_class : VOXEL_SHAPE_CUBE;
                    bool did_hit = test_voxel_shape_hit(
                        shape, current_voxel, start_level, inv_dir_level,
                        t, clamped_next_t, entry_norm, hit_t, hit_norm
                    );
                    if (did_hit) {
                        vec3 hit_face_scene = start_scene + dda_dir * (hit_t * scale);
                        shade_voxel_hit(
                            result, sample_data, mat, hit_face_scene, hit_norm,
                            ray_transmittance, voxel_grid, level,
                            direct_sun_color, l_dir
                        );
                        result.distance = t_start_world + hit_t * scale;
                        return result;
                    }
                }
            }
        }

        if (t_max.x < t_max.y) {
            if (t_max.x < t_max.z) mask = vec3(1.0, 0.0, 0.0);
            else mask = vec3(0.0, 0.0, 1.0);
        } else {
            if (t_max.y < t_max.z) mask = vec3(0.0, 1.0, 0.0);
            else mask = vec3(0.0, 0.0, 1.0);
        }
        t = next_t;
        t_max += mask * delta_t;
        current_voxel += ivec3(mask * step_dir);
    }

    result.transmittance = ray_transmittance;
    return result;
}

// Shared RT scene query: nested clipmaps, finest level first. A ray is shaded
// once, at the first opaque/emissive hit across the stack. Glass transmittance
// is carried across level boundaries; coarser levels begin outside the finer
// cube to avoid duplicate surface hits and duplicate emitter power.
VoxelHit trace_voxel_dda(
    usampler3D voxel_grid,
    usampler3D voxel_mid,
    usampler3D voxel_coarse,
    vec3 ray_origin_scene,
    vec3 surface_normal,
    vec3 ray_dir,
    float dither,
    vec3 direct_sun_color,
    vec3 l_dir,
    float max_dist
) {
    vec3 dda_dir = normalize(safe_ray_dir(ray_dir));
    VoxelHit result = make_miss_voxel_hit(ray_origin_scene, dda_dir, max_dist);
    vec3 transmittance = vec3(1.0);
    float t_start = 0.0;

    for (int level = 0; level < RT_COVERAGE_LEVELS; ++level) {
        float level_exit;
        VoxelHit hit;
        if (level == 0) {
            hit = trace_voxel_level(
                voxel_grid, level,
                ray_origin_scene, surface_normal, dda_dir, t_start, max_dist,
                dither, direct_sun_color, l_dir, level_exit
            );
        } else if (level == 1) {
            hit = trace_voxel_level(
                voxel_mid, level,
                ray_origin_scene, surface_normal, dda_dir, t_start, max_dist,
                dither, direct_sun_color, l_dir, level_exit
            );
        } else {
            hit = trace_voxel_level(
                voxel_coarse, level,
                ray_origin_scene, surface_normal, dda_dir, t_start, max_dist,
                dither, direct_sun_color, l_dir, level_exit
            );
        }

        if (hit.hit) {
            hit.transmittance *= transmittance;
            return hit;
        }

        transmittance *= hit.transmittance;
        t_start = max(t_start, level_exit + 0.02);
        if (t_start >= max_dist) break;
    }

    result.transmittance = transmittance;
    return result;
}

// Stage 5: Fast shadow / occlusion test (terminates on first opaque sub-box hit)
bool trace_any_hit(
    usampler3D voxel_grid,
    vec3 ray_origin_scene,
    vec3 surface_normal,
    vec3 ray_dir,
    float max_dist
) {
    vec3 dda_dir = normalize(safe_ray_dir(ray_dir));
    vec3 inv_dir = 1.0 / dda_dir;
    vec3 start_scene = ray_origin_scene + surface_normal * 0.03 + dda_dir * 0.02;
    vec3 start_voxel = scene_to_voxel_space(start_scene);
    ivec3 current_voxel = ivec3(floor(start_voxel));

    ivec3 origin_voxel = ivec3(floor(scene_to_voxel_space(ray_origin_scene - surface_normal * 0.05)));
    ivec3 origin_voxel_ray = ivec3(floor(scene_to_voxel_space(ray_origin_scene - dda_dir * 0.05)));

    vec3 step_dir = sign(dda_dir);
    vec3 delta_t = abs(inv_dir);
    vec3 t_max = (step_dir * (vec3(current_voxel) - start_voxel) + step_dir * 0.5 + 0.5) * delta_t;

    vec3 mask = vec3(0.0);
    float t = 0.0;

    const int MAX_STEPS = voxel_dda_max_steps;
    for (int i = 0; i < MAX_STEPS; ++i) {
        if (!is_inside_voxel_grid(current_voxel) || t > max_dist) {
            break;
        }

        float next_t = min(min(t_max.x, t_max.y), t_max.z);
        float clamped_next_t = min(next_t, max_dist);

        if (current_voxel != origin_voxel && current_voxel != origin_voxel_ray) {
            uint packed = texelFetch(voxel_grid, current_voxel, 0).r;
            VoxelSample sample_data = unpack_voxel_data(packed);

            if (sample_data.is_solid && !sample_data.is_translucent) {
                float hit_t;
                vec3 hit_norm;
                vec3 entry_norm = (dot(mask, mask) > 0.5) ? (-mask * step_dir) : -sign(dda_dir);
                if (test_voxel_shape_hit(
                    sample_data.shape_class,
                    current_voxel,
                    start_voxel,
                    inv_dir,
                    t,
                    clamped_next_t,
                    entry_norm,
                    hit_t,
                    hit_norm
                )) {
                    return true;
                }
            }
        }

        if (t_max.x < t_max.y) {
            if (t_max.x < t_max.z) {
                mask = vec3(1.0, 0.0, 0.0);
            } else {
                mask = vec3(0.0, 0.0, 1.0);
            }
        } else {
            if (t_max.y < t_max.z) {
                mask = vec3(0.0, 1.0, 0.0);
            } else {
                mask = vec3(0.0, 0.0, 1.0);
            }
        }
        t = next_t;
        t_max += mask * delta_t;
        current_voxel += ivec3(mask * step_dir);
    }

    return false;
}

#endif // INCLUDE_LIGHTING_RT_VOXEL_DDA
