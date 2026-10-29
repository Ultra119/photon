#if !defined INCLUDE_DEBUG_GI_DEBUG
#define INCLUDE_DEBUG_GI_DEBUG

// Self-contained: the voxel views need the pack/unpack helpers and the radiance
// views need srgb_eotf(). Both have include guards, so this is free.
#include "/include/utility/color.glsl"
#include "/include/lighting/voxel/voxel_storage.glsl"

// GI debug view encoding.
//
// Everything here is inert unless GI_DEBUG != GI_DEBUG_OFF. The values are
// defined in settings.glsl so that shaders.properties can gate image
// allocation on the same setting; when the option is OFF the debug images are
// not declared at all, so they cost no memory and no bandwidth.
//
// Display contract: each encoder returns a value already in display space.
// final.fsh does not apply display_eotf() to these, exactly like the existing
// DEBUG_VIEW_SAMPLER path, so the colours below are what the user sees.

// Distinct, roughly evenly-spaced hues. A hash gives random colours where two
// neighbouring block IDs can land on the same hue; a fixed palette guarantees
// that IDs 1 and 2 are always distinguishable, which is what makes holes in the
// voxelization readable.
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

// Radiance is HDR; without a curve, everything but the brightest surfaces is
// black and the view is useless. Reinhard in linear space, then sRGB.
vec3 gi_debug_tonemap(vec3 radiance) {
    vec3 mapped = radiance / (1.0 + max(radiance, vec3(0.0)));
    return srgb_eotf(mapped);
}

// Air is black; solid voxels get a palette colour; light-only voxels (block_id
// 0 but block_light > 0) get a dim white so they are not mistaken for air.
vec3 gi_debug_voxel_id(uint packed) {
    VoxelSample voxel = unpack_voxel_data(packed);
    if (voxel.block_id == 0u) {
        return voxel.block_light > 0.0
            ? vec3(0.10) + 0.25 * voxel.block_light
            : vec3(0.0);
    }
    return gi_debug_palette_color(voxel.block_id);
}

// R = block light, G = sky light. Both are what the DDA accumulates, not the
// value after any attenuation, so a gradient here means the light field itself
// varies and not that the ray path is thinning out.
vec3 gi_debug_voxel_light(uint packed) {
    VoxelSample voxel = unpack_voxel_data(packed);
    if (voxel.is_emitter) {
        return max(voxel.color, vec3(0.2)) * 2.0;
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

// Ray hit source. Written by rtgi_trace.csh into the R/G/B channels.
//
//   R = fraction of rays resolved by screen space (SSGI)
//   G = fraction resolved by the voxel DDA
//   B = fraction that escaped to sky
//
// The hybrid split is only correct if SSGI dominates up close and the voxel
// path takes over with distance; a scene where G is flat across depth usually
// means SSGI is failing and everything is falling through to voxels.
vec3 gi_debug_hit_mask(vec4 hit) {
    float total = hit.r + hit.g + hit.b;
    if (total <= 0.0) {
        return vec3(0.0);
    }
    return hit.rgb / total;
}

// Temporal history decision. rtgi_temporal.csh writes 1.0 in R when the
// reprojected history was rejected (disocclusion or depth mismatch) and 1.0 in
// G when it was accepted. Intentionally binary: a partial acceptance is the
// interesting case and shows as yellow.
vec3 gi_debug_reject_mask(vec4 reject) {
    return vec3(reject.r, reject.g, 0.0);
}

// Diverging colour map for the convergence view. Neutral grey means the
// accumulated history and the current raw estimate agree; red means the new
// estimate is brighter, blue means darker. A converged static image is close to
// uniform grey; a view-dependent estimator stays coloured no matter how long
// you wait.
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

// Box filter for display only. The hit and reject images carry one sample per
// ray, so at RTGI_RAY_COUNT=2 every texel is 0 / 0.5 / 1 per channel and the
// raw view is pure binary noise. Averaging a 3x3 neighbourhood makes the
// spatial structure visible without touching the buffer itself, which is what
// the acceptance criterion ("interpretable") actually asks for.
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

// A solid swatch in the bottom-left corner identifying the active view.
//
// Without it, a screenshot cannot prove which view produced it. That matters:
// "the three voxel views look the same" is ambiguous between a broken encoder
// and an option that did not switch, and this settles it in one glance.
const vec3 gi_debug_swatch_size = vec3(24.0);

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
    // Deliberately not palette index 4 (0.25, 0.45, 0.95): that is exactly the
    // colour stone voxels get, and a corner swatch identical to the content it
    // labels is worse than no swatch.
    return vec3(0.0, 1.0, 1.0);
#elif GI_DEBUG == GI_DEBUG_VOXEL_LIGHT
    return vec3(1.0, 1.0, 0.0);
#elif GI_DEBUG == GI_DEBUG_VOXEL_ALBEDO
    return vec3(0.60, 0.60, 0.60);
#elif GI_DEBUG == GI_DEBUG_VARIANCE
    return vec3(1.0, 0.35, 0.0);
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
// Requires the includer to declare, under DEBUG_VIEW == DEBUG_VIEW_GI:
//   depthtex1, voxel_sampler, rtgi_{raw,history,accum,filtered}_sampler,
//   cameraPosition, frameCounter, near, far, gbufferProjectionInverse,
//   gbufferModelViewInverse, and (for GI_DEBUG_HIT/REJECT) the matching
//   rtgi_{hit,reject}_sampler. final.fsh does exactly this.
//
// Every branch is selected at compile time, so with GI_DEBUG == GI_DEBUG_OFF
// this compiles down to `return fallback` and no sampler is read.
vec3 gi_debug_view(ivec2 texel, vec2 uv, vec3 fallback) {
#if GI_DEBUG == GI_DEBUG_OFF
    return fallback;
#else
    // RTGI images cover the same uv space as the framebuffer, at
    // RTGI_RESOLUTION scale, so the same coordinate transform that
    // diffuse_lighting.glsl uses for the filtered buffer applies to all of them.
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
    float m1 = aux_sample.r;
    float m2 = aux_sample.g;
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
    // Voxel views: reconstruct the opaque surface position and read the voxel
    // the camera actually sees, so a hole in this image is a hole in the volume
    // at the place the player is looking.
    //
    // handle_jitter = true matches every other depth reconstruction in this
    // pack (rtgi_trace, rtgi_temporal, d3_ao, and the DISTANCE_VIEW block in
    // final.fsh itself): the depth buffer is rendered through a jittered
    // projection, so the offset has to be compensated for. An earlier revision
    // passed false on the reasoning that final runs after TAA resolves; that
    // was not verified and it did not fix the flicker, so the codebase
    // convention wins.
    ivec2 depth_texel = ivec2(taau_framebuffer_uv(uv) * view_res);
    float depth = texelFetch(depthtex1, depth_texel, 0).x;
    if (depth >= 1.0) {
        return vec3(0.0); // sky
    }

    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(gbufferProjectionInverse, screen_pos, true);

    // Compute screen-space geometric normal from view position derivatives.
    // Stepping perpendicularly into the surface normal ensures we penetrate
    // cleanly into the solid block under any view angle (including grazing
    // walls and ceilings), eliminating zebra stripes and block edge slits.
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
    ivec3 voxel_coord = ivec3(floor(scene_to_voxel_space(scene_pos)));
    if (!is_inside_voxel_grid(voxel_coord)) {
        // Outside the volume there is no voxel data, which is different from
        // "there is a hole". Flag it as magenta instead of black.
        return vec3(0.6, 0.0, 0.6);
    }

    uint packed = texelFetch(voxel_sampler, voxel_coord, 0).r;

#if GI_DEBUG == GI_DEBUG_VOXEL_ID
    return gi_debug_voxel_id(packed);
#elif GI_DEBUG == GI_DEBUG_VOXEL_LIGHT
    return gi_debug_voxel_light(packed);
#else
    return gi_debug_voxel_albedo(packed);
#endif
#endif
#endif
}

#endif // INCLUDE_DEBUG_GI_DEBUG
