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
    return gi_debug_spread(
        texture(rtgi_raw_sampler, rtgi_uv).rgb,
        ping ? texture(rtgi_accum_sampler, rtgi_uv).rgb
             : texture(rtgi_history_sampler, rtgi_uv).rgb
    );
#elif GI_DEBUG == GI_DEBUG_HIT
    return gi_debug_hit_mask(texture(rtgi_hit_sampler, rtgi_uv));
#elif GI_DEBUG == GI_DEBUG_REJECT
    return gi_debug_reject_mask(texture(rtgi_reject_sampler, rtgi_uv));
#else
    // Voxel views: reconstruct the opaque surface position and read the voxel
    // the camera actually sees, so a hole in this image is a hole in the volume
    // at the place the player is looking.
    float depth = texelFetch(depthtex1, texel, 0).x;
    if (depth >= 1.0) {
        return vec3(0.0); // sky
    }

    vec3 screen_pos = vec3(uv, depth);
    vec3 view_pos = screen_to_view_space(gbufferProjectionInverse, screen_pos, true);
    vec3 scene_pos = view_to_scene_space(view_pos);

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
