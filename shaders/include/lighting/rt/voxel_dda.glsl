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
};

// Check if voxel point is in sunlight shadow using shadow map
float sample_voxel_sun_shadow(
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    vec3 scene_pos,
    vec3 normal,
    vec3 l_dir
) {
    float NoL = dot(normal, l_dir);
    if (NoL <= 0.0) return 0.0;

    vec3 bias = normal * 0.08;
    vec3 shadow_view = mat3(shadow_mv) * (scene_pos + bias) + shadow_mv[3].xyz;
    vec4 shadow_clip = shadow_proj * vec4(shadow_view, 1.0);
    vec3 shadow_ndc = shadow_clip.xyz / shadow_clip.w;
    shadow_ndc = distort_shadow_space(shadow_ndc);
    vec3 shadow_screen = shadow_ndc * 0.5 + 0.5;

    if (clamp01(shadow_screen) != shadow_screen) {
        return 0.0; // Outside shadow map: assume shadowed to avoid leaks
    }

    float shadow_depth = texture(shadow_tex, shadow_screen.xy).r;
    return float(shadow_depth >= shadow_screen.z - 0.001);
}

// 3D Amanatides-Woo DDA voxel traversal
VoxelHit trace_voxel_dda(
    usampler3D voxel_grid,
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    vec3 ray_origin_scene,
    vec3 surface_normal,
    vec3 ray_dir,
    float dither,
    vec3 direct_sun_color,
    vec3 sky_ambient_color,
    vec3 l_dir,
    float max_dist
) {
    VoxelHit result;
    vec3 dda_dir = normalize(safe_ray_dir(ray_dir));
    vec3 inv_dir = 1.0 / dda_dir;
    result.hit = false;
    result.hit_pos = ray_origin_scene + dda_dir * max_dist;
    result.hit_normal = -dda_dir;
    result.radiance = vec3(0.0);
    result.distance = max_dist;
    result.transmittance = vec3(1.0);
    result.sky_weight = 0.0;
    result.accumulated_light = vec3(0.0);

    vec3 ray_transmittance = vec3(1.0);
    vec3 accumulated_light = vec3(0.0);

    // Offset ray origin along surface normal and forward to clear starting block boundary
    // Tight 3 cm normal bias and 2 cm directional offset prevents jumping across
    // adjacent interior corners, walls, or ceilings while reliably clearing precision seams.
    vec3 start_scene = ray_origin_scene + surface_normal * 0.03 + dda_dir * 0.02;
    vec3 start_voxel = scene_to_voxel_space(start_scene);
    ivec3 current_voxel = ivec3(floor(start_voxel));

    // Voxels containing the origin surface point (must not self-intersect).
    // Use both the geometric normal and the traced ray so mapped normals or
    // exact seams cannot leave an unignored solid voxel at the ray start.
    ivec3 origin_voxel = ivec3(floor(scene_to_voxel_space(ray_origin_scene - surface_normal * 0.05)));
    ivec3 origin_voxel_ray = ivec3(floor(scene_to_voxel_space(ray_origin_scene - dda_dir * 0.05)));

    vec3 step_dir = sign(dda_dir);
    vec3 delta_t = abs(1.0 / (dda_dir + vec3(1e-7)));
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
        float segment_length = max(clamped_next_t - t, 0.0);
        float segment_mid = 0.5 * (t + clamped_next_t);

        // Ignore the origin block to completely eliminate self-intersection
        if (current_voxel != origin_voxel && current_voxel != origin_voxel_ray) {
            uint packed = texelFetch(voxel_grid, current_voxel, 0).r;
            VoxelSample sample_data = unpack_voxel_data(packed);

            // Light-only voxel: block_id == 0, block_light > 0. Accumulate it
            // as a camera-independent emissive medium instead of stopping the ray.
            // NB: RTGI_POINT_LIGHT_STRENGTH is a float slider; it must be tested
            // with a runtime if (constant-folded by the driver), never with #if,
            // because float literals are illegal in GLSL preprocessor expressions.
            if (RTGI_POINT_LIGHT_STRENGTH > 0.0 && sample_data.block_id == 0u && sample_data.block_light > 0.0) {
                float scatter = 1.0 - exp(-0.22 * segment_length);
                float distance_falloff = exp(-0.16 * segment_mid);
                accumulated_light += sample_data.color
                    * (sample_data.block_light * blocklight_scale)
                    * scatter * distance_falloff * ray_transmittance;
            }

            if (sample_data.block_id != 0u) {
                VoxelMaterial mat = get_voxel_material(sample_data.block_id, sample_data.color);

                // Stained glass tints transmittance but does not stop the ray.
                if (sample_data.block_id >= 81u && sample_data.block_id <= 96u) {
                    ray_transmittance *= mat.albedo;
                } else if (sample_data.block_id == 80u) {
                    // Clear glass: passes through without tinting
                } else if (RTGI_POINT_LIGHT_STRENGTH > 0.0 && sample_data.is_emitter && is_point_light_emitter(sample_data.block_id)) {
                    // Small emitters are transparent light sources when radial point-light
                    // accumulation is active.
                    vec3 emitter_pos = voxel_to_scene_space(vec3(current_voxel) + 0.5);
                    float emitter_dist = length(emitter_pos - ray_origin_scene);
                    float emitter_attenuation = exp(-0.30 * emitter_dist)
                        * RTGI_POINT_LIGHT_STRENGTH;
                    accumulated_light += mat.emission
                        * emitter_attenuation * 0.20 * ray_transmittance;
                } else if (mat.is_solid || sample_data.is_emitter) {
                    float hit_t;
                    vec3 hit_norm;
                    vec3 entry_norm = (dot(mask, mask) > 0.5) ? (-mask * step_dir) : -sign(dda_dir);

                    bool did_hit = test_voxel_shape_hit(
                        sample_data.shape_class,
                        current_voxel,
                        start_voxel,
                        inv_dir,
                        t,
                        clamped_next_t,
                        entry_norm,
                        hit_t,
                        hit_norm
                    );

                    if (did_hit) {
                        result.hit = true;
                        result.hit_normal = hit_norm;
                        result.distance = hit_t;
                        result.transmittance = ray_transmittance;

                        vec3 hit_face_pos = start_scene + dda_dir * hit_t;
                        result.hit_pos = hit_face_pos;

                    // 1. Direct Sun / Moonlight bounce
                    float sun_vis = sample_voxel_sun_shadow(
                        shadow_tex,
                        shadow_mv,
                        shadow_proj,
                        hit_face_pos,
                        result.hit_normal,
                        l_dir
                    );
                    float NoL = max(0.0, dot(result.hit_normal, l_dir));
                    // Direct light is already scaled by SUN_I / exposure.
                    vec3 sun_radiance = direct_sun_color * (sun_vis * NoL);

                    // 2. Skylight bounce: solid voxels DO NOT inject ambient sky light.
                    // Following SEUS PTGI, ambient skylight is only accumulated when a ray
                    // escapes to the sky (RTGI_HIT_SKY). Stored voxel skylight is contaminated
                    // by exterior roof/wall faces and leaks into dark interiors.
                    vec3 sky_radiance = vec3(0.0);

                    // 3. Blocklight bounce: solid non-emitter blocks do not bounce blocklight
                    // (direct blocklight is handled by mc_block on the camera receiver).
                    // Actual light emitters radiate their calibrated light via mat.emission.
                    vec3 blocklight_bounce = vec3(0.0);

                    // 4. Emissive radiance from block itself
                    vec3 emission_radiance = mat.emission;

                    // Organic foliage (leaves & plants): absorb light rather than concentrating it inside canopy
                    vec3 bounce_albedo = mat.albedo;
                    if (sample_data.block_id == 5u || sample_data.block_id == 14u || sample_data.block_id == 2u) {
                        bounce_albedo *= 0.35;
                        blocklight_bounce *= 0.50;
                    }

                    // Split sky/sun-origin radiance from emission/block-light radiance.
                    // The radial point-light field is local and is included in
                    // local_lit so sky leaks can still be gated independently.
                    vec3 bounce_irradiance = blocklight_bounce + sun_radiance;
                    vec3 bounce_radiance = bounce_albedo * bounce_irradiance * voxel_bounce_rcp_pi;

                    vec3 sky_lit = bounce_albedo * sun_radiance * voxel_bounce_rcp_pi;
                    vec3 local_lit = emission_radiance
                        + bounce_albedo * blocklight_bounce * voxel_bounce_rcp_pi
                        + accumulated_light;
                    float sky_lum = dot(sky_lit, luminance_weights);
                    float local_lum = dot(local_lit, luminance_weights);
                    result.sky_weight = clamp01(sky_lum / max(sky_lum + local_lum, eps));

                    // Combined indirect bounce from the solid hit, tinted by
                    // stained glass transmittance. accumulated_light is added
                    // by the caller so it also appears on sky-miss rays.
                    result.radiance = (
                        emission_radiance + bounce_radiance
                    ) * ray_transmittance;
                        break;
                    }
                }
            }
        }

        // Advance DDA strictly one axis per step to prevent diagonal corner slipping
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

    result.transmittance = ray_transmittance;
    result.accumulated_light = accumulated_light;
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
