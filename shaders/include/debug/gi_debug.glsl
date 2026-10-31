#if !defined INCLUDE_DEBUG_GI_DEBUG
#define INCLUDE_DEBUG_GI_DEBUG

// GI debug visualization utilities
#include "/include/utility/color.glsl"
#include "/include/lighting/voxel/voxel_storage.glsl"
#if GI_DEBUG == 10
#include "/include/lighting/rt/ddgi.glsl"
#endif

// GI debug view encoding.
//
// Fixed hue palette for block IDs
const vec3 gi_debug_palette[16] = vec3[16](
    vec3(0.20, 0.20, 0.20), vec3(0.90, 0.20, 0.20), vec3(0.20, 0.80, 0.20),
    vec3(0.95, 0.85, 0.20), vec3(0.25, 0.45, 0.95), vec3(0.85, 0.35, 0.85),
    vec3(0.20, 0.85, 0.85), vec3(0.95, 0.55, 0.15), vec3(0.55, 0.35, 0.95),
    vec3(0.55, 0.85, 0.25), vec3(0.95, 0.45, 0.65), vec3(0.35, 0.65, 0.55),
    vec3(0.70, 0.70, 0.95), vec3(0.80, 0.60, 0.40), vec3(0.45, 0.45, 0.70),
    vec3(0.98, 0.98, 0.98)
);

vec3 gi_debug_palette_color(uint id) {
    return gi_debug_palette[id & 15u];
}

// Tonemap HDR radiance for display
vec3 gi_debug_tonemap(vec3 radiance) {
    vec3 mapped = radiance / (1.0 + max(radiance, vec3(0.0)));
    return srgb_eotf(mapped);
}

#if GI_DEBUG == GI_DEBUG_COVERAGE
// Clipmap coverage visualization
vec3 gi_debug_coverage(vec3 world_pos) {
    int level = rt_clip_finest_containing_level(world_pos);
    if (level < 0) return vec3(0.6, 0.0, 0.6);

    float scale = rt_clip_scale(level);
    vec3 local = (world_pos - rt_clip_origin_world(level)) / scale;
    ivec3 coord = rt_clip_texel(ivec3(floor(local)));

    uint packed = 0u;
    if (level == 0) {
        packed = texelFetch(voxel_sampler, coord, 0).r;
    } else if (level == 1) {
        packed = texelFetch(voxel_mid_sampler, coord, 0).r;
    } else {
        packed = texelFetch(voxel_coarse_sampler, coord, 0).r;
    }
    bool populated = unpack_voxel_data(packed).block_id != 0u;

    vec3 color = level == 0 ? vec3(0.9, 0.2, 0.2)
               : level == 1 ? vec3(0.2, 0.85, 0.25)
                            : vec3(0.25, 0.45, 0.95);
    if (!populated) color *= 0.22;

    vec3 edge = min(local, rt_clipmap_size_f - local);
    float edge_dist = min(min(edge.x, edge.y), edge.z);
    if (edge_dist < 2.0) {
        color = mix(color, vec3(1.0, 0.9, 0.1), 0.45);
    }
    return color;
}

#endif // GI_DEBUG_COVERAGE

vec3 gi_debug_voxel_id(uint packed) {
    VoxelSample voxel = unpack_voxel_data(packed);
    if (voxel.block_id == 0u) {
        return voxel.block_light > 0.0
            ? vec3(0.10) + 0.25 * voxel.block_light
            : vec3(0.0);
    }
    return gi_debug_palette_color(voxel.block_id);
}

// Voxel light visualization (R = block light, G = sky light)
vec3 gi_debug_voxel_light(uint packed) {
    VoxelSample voxel = unpack_voxel_data(packed);
    if (voxel.is_emitter) {
        return max(voxel.color, vec3(0.2)) * 2.0;
    }
    if (voxel.is_solid) {
        return max(vec3(voxel.block_light, voxel.sky_light, 0.0), vec3(0.05));
    }
    return vec3(voxel.block_light, voxel.sky_light, 0.0);
}

vec3 gi_debug_voxel_albedo(uint packed) {
    VoxelSample voxel = unpack_voxel_data(packed);
    if (voxel.block_id == 0u && voxel.block_light <= 0.0) {
        return vec3(0.0);
    }
    return srgb_eotf(voxel.color);
}

// Ray hit source visualization (G = voxel, B = sky)
vec3 gi_debug_hit_mask(vec4 hit) {
    float total = hit.r + hit.g + hit.b;
    if (total <= 0.0) {
        return vec3(0.0);
    }
    return hit.rgb / total;
}

// Temporal history decision (R = reject, G = accept)
vec3 gi_debug_reject_mask(vec4 reject) {
    return vec3(reject.r, reject.g, 0.0);
}

// Relative variance visualization
vec3 gi_debug_spread(vec3 raw, vec3 accumulated) {
    vec3 delta = raw - accumulated;
    float magnitude = clamp01(dot(delta, delta) * 4.0);
    vec3 sign_colour = vec3(
        max(delta.r, 0.0) + max(delta.g, 0.0) + max(delta.b, 0.0),
        0.0,
        max(-delta.r, 0.0) + max(-delta.g, 0.0) + max(-delta.b, 0.0)
    );
    return mix(vec3(0.5), sign_colour * magnitude * 3.0, clamp01(magnitude * 3.0));
}

// 3x3 box filter for discrete masks
vec3 gi_debug_smooth_3x3(sampler2D source, vec2 uv) {
    ivec2 size = textureSize(source, 0);
    ivec2 base = clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);
    vec3 sum = vec3(0.0);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            sum += texelFetch(source, clamp(base + ivec2(x, y), ivec2(0), size - 1), 0).rgb;
        }
    }
    return sum * (1.0 / 9.0);
}

// Corner swatch indicator

vec3 gi_debug_view_swatch() {
#if GI_DEBUG == GI_DEBUG_RAW
    return vec3(1.0, 0.55, 0.10);
#elif GI_DEBUG == GI_DEBUG_HISTORY
    return vec3(0.10, 0.70, 1.0);
#elif GI_DEBUG == GI_DEBUG_FILTERED
    return vec3(0.20, 1.0, 0.30);
#elif GI_DEBUG == GI_DEBUG_HIT
    return vec3(1.0, 0.0, 1.0);
#elif GI_DEBUG == GI_DEBUG_REJECT
    return vec3(1.0, 1.0, 1.0);
#elif GI_DEBUG == GI_DEBUG_VOXEL_ID
    // labels is worse than no swatch.
    return vec3(0.0, 1.0, 1.0);
#elif GI_DEBUG == GI_DEBUG_VOXEL_LIGHT
    return vec3(1.0, 1.0, 0.0);
#elif GI_DEBUG == GI_DEBUG_VOXEL_ALBEDO
    return vec3(0.60, 0.60, 0.60);
#elif GI_DEBUG == GI_DEBUG_VARIANCE
    return vec3(1.0, 0.35, 0.0);
#elif GI_DEBUG == GI_DEBUG_PROBE
    return vec3(0.85, 0.20, 0.95);
#elif GI_DEBUG == GI_DEBUG_COVERAGE
    return vec3(0.50, 1.00, 0.50);
#else
    return vec3(0.0);
#endif
}

vec3 gi_debug_stamp_swatch(vec3 color, ivec2 texel) {
    return (texel.x < int(gi_debug_swatch_size.x)
            && texel.y < int(gi_debug_swatch_size.y))
        ? gi_debug_view_swatch()
        : color;
}

// ---------------------------------------------------------------------------
//   View dispatcher
// ---------------------------------------------------------------------------
//
// this compiles down to `return fallback` and no sampler is read.
vec3 gi_debug_view(ivec2 texel, vec2 uv, vec3 fallback) {
#if GI_DEBUG == GI_DEBUG_OFF
    return fallback;
#else
    vec2 rtgi_uv = taau_framebuffer_uv(uv);

    // The temporal pass ping-pongs: ping writes accum, !ping writes history.
    bool ping = (frameCounter & 1) == 0;

#if GI_DEBUG == GI_DEBUG_RAW
    return gi_debug_tonemap(texture(rtgi_raw_sampler, rtgi_uv).rgb);
#elif GI_DEBUG == GI_DEBUG_HISTORY
    return gi_debug_tonemap(
        ping ? texture(rtgi_accum_sampler, rtgi_uv).rgb
             : texture(rtgi_history_sampler, rtgi_uv).rgb
    );
#elif GI_DEBUG == GI_DEBUG_FILTERED
    return gi_debug_tonemap(texture(rtgi_filtered_sampler, rtgi_uv).rgb);
#elif GI_DEBUG == GI_DEBUG_VARIANCE
    vec4 aux_sample = ping ? texture(rtgi_sky_accum_sampler, rtgi_uv)
                           : texture(rtgi_sky_history_sampler, rtgi_uv);
    vec4 accum_sample = ping ? texture(rtgi_accum_sampler, rtgi_uv)
                             : texture(rtgi_history_sampler, rtgi_uv);
    float m1 = dot(accum_sample.rgb, vec3(0.2126, 0.7152, 0.0722));
    float m2 = aux_sample.r;
    float variance = max(0.0, m2 - m1 * m1);
    float rel_std_dev = sqrt(variance) / (m1 + 0.05);
    // Cold-to-hot colormap: blue (converged / low variance) -> green -> yellow -> red (high variance)
    vec3 col_blue = vec3(0.0, 0.25, 0.95);
    vec3 col_green = vec3(0.1, 0.85, 0.25);
    vec3 col_yellow = vec3(0.95, 0.90, 0.10);
    vec3 col_red = vec3(0.95, 0.15, 0.05);
    float t_var = clamp01(rel_std_dev);
    vec3 var_color = t_var < 0.33 ? mix(col_blue, col_green, t_var * 3.0)
                   : t_var < 0.66 ? mix(col_green, col_yellow, (t_var - 0.33) * 3.0)
                   : mix(col_yellow, col_red, (t_var - 0.66) * 3.0);
    return var_color;
#elif GI_DEBUG == GI_DEBUG_HIT
    return gi_debug_hit_mask(
        vec4(gi_debug_smooth_3x3(rtgi_hit_sampler, rtgi_uv), 1.0)
    );
#elif GI_DEBUG == GI_DEBUG_REJECT
    return gi_debug_reject_mask(
        vec4(gi_debug_smooth_3x3(rtgi_reject_sampler, rtgi_uv), 1.0)
    );
#else
    // Reconstruct world-space position and sample voxel grid
    // convention wins.
    ivec2 depth_texel = ivec2(taau_framebuffer_uv(uv) * view_res);
    float depth = texelFetch(depthtex0, depth_texel, 0).x;
    if (depth >= 1.0) {
        return vec3(0.0); // sky
    }

    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(gbufferProjectionInverse, screen_pos, true);

    // Screen-space geometric normal
    vec3 dpdx = dFdx(view_pos);
    vec3 dpdy = dFdy(view_pos);
    vec3 cross_n = cross(dpdx, dpdy);
    float len_sq = dot(cross_n, cross_n);
    vec3 view_normal = len_sq > 1e-8 ? cross_n * inversesqrt(len_sq) : -normalize(view_pos);
    if (dot(view_normal, view_pos) > 0.0) {
        view_normal = -view_normal;
    }
    vec3 scene_normal = mat3(gbufferModelViewInverse) * view_normal;

    vec3 scene_pos = view_to_scene_space(view_pos) - scene_normal * 0.12;

#if GI_DEBUG == GI_DEBUG_COVERAGE
    return gi_debug_coverage(scene_pos + cameraPosition);
#endif

    ivec3 voxel_coord = ivec3(floor(scene_to_voxel_space(scene_pos)));
    if (!is_inside_voxel_grid(voxel_coord)) {
        return vec3(0.6, 0.0, 0.6);
    }

    uint packed = texelFetch(voxel_sampler, voxel_coord, 0).r;

#if GI_DEBUG == GI_DEBUG_VOXEL_ID
    return gi_debug_voxel_id(packed);
#elif GI_DEBUG == GI_DEBUG_VOXEL_LIGHT
    return gi_debug_voxel_light(packed);
#elif GI_DEBUG == GI_DEBUG_VOXEL_ALBEDO
    return gi_debug_voxel_albedo(packed);
#elif GI_DEBUG == GI_DEBUG_PROBE
    vec3 world_pos = scene_pos + cameraPosition;
    vec4 probe_irr = sample_ddgi_irradiance(world_pos + scene_normal * 0.15, scene_normal, cameraPosition);
    return gi_debug_tonemap(probe_irr.rgb);
#else
    return fallback;
#endif
#endif
#endif
}

#endif // INCLUDE_DEBUG_GI_DEBUG
