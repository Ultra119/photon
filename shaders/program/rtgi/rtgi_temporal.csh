/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_temporal.csh:
  SVGF Temporal Reconstruction with 3-Way Disocclusion & Moment Tracking

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

#if RTGI_RESOLUTION == 0
const vec2 workGroupsRender = vec2(0.25, 0.25);
#elif RTGI_RESOLUTION == 2
const vec2 workGroupsRender = vec2(1.0, 1.0);
#else
const vec2 workGroupsRender = vec2(0.5, 0.5);
#endif
layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f) writeonly uniform image2D rtgi_history_img;
layout(rgba16f) writeonly uniform image2D rtgi_accum_img;
layout(rgba16f) writeonly uniform image2D rtgi_sky_history_img;
layout(rgba16f) writeonly uniform image2D rtgi_sky_accum_img;

uniform sampler2D rtgi_raw_sampler;
uniform sampler2D rtgi_history_sampler;
uniform sampler2D rtgi_accum_sampler;
uniform sampler2D rtgi_sky_history_sampler;
uniform sampler2D rtgi_sky_accum_sampler;

// Declared only when the diagnostic view is active (see rtgi_trace.csh).
#if GI_DEBUG == GI_DEBUG_REJECT
layout(rgba8) writeonly uniform image2D rtgi_reject_img;
#endif
uniform sampler2D depthtex1;
uniform sampler2D colortex1; // gbuffer0

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

uniform vec2 view_res;
uniform vec2 view_pixel_size;

uniform float near;
uniform float far;
uniform vec2 taa_offset;

#define TEMPORAL_REPROJECTION
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "/include/utility/color.glsl"

void write_zero(ivec2 texel, bool ping) {
    if (ping) {
        imageStore(rtgi_accum_img, texel, vec4(0.0));
        imageStore(rtgi_sky_accum_img, texel, vec4(0.0));
    } else {
        imageStore(rtgi_history_img, texel, vec4(0.0));
        imageStore(rtgi_sky_history_img, texel, vec4(0.0));
    }
}

void main() {
#if RTGI_RESOLUTION == 0
    const float render_scale = 0.25;
#elif RTGI_RESOLUTION == 2
    const float render_scale = 1.0;
#else
    const float render_scale = 0.5;
#endif

    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 target_res = ivec2(view_res * render_scale);

    if (texel.x >= target_res.x || texel.y >= target_res.y) {
        return;
    }

    // uv is a full-framebuffer UV; see rtgi_trace.csh.
    vec2 uv = (vec2(texel) + 0.5) / vec2(target_res);
    bool ping = (frameCounter & 1) == 0;

    if (taau_uv_outside_viewport(uv)) {
        write_zero(texel, ping);
        return;
    }

    ivec2 full_texel = ivec2(uv * view_res);

    float depth = texelFetch(depthtex1, full_texel, 0).x;

    if (depth >= 1.0) {
        write_zero(texel, ping);
        return;
    }

    // Current frame raw sample
    vec4 raw_sample = texelFetch(rtgi_raw_sampler, texel, 0);
    vec3 current_radiance = raw_sample.rgb;
    float current_sky_weight = clamp01(raw_sample.a);
    float current_lum = dot(current_radiance, luminance_weights);

    // Current surface geometric data from G-buffer
    vec4 gbuf = texelFetch(colortex1, full_texel, 0);
    vec3 current_world_normal = decode_unit_vector(unpack_unorm_2x8(gbuf.z));

    // 3x3 neighbourhood statistics for variance clipping (variance-driven AABB)
    vec3 raw_m1 = vec3(0.0);
    vec3 raw_m2 = vec3(0.0);

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            ivec2 n_coord = clamp(texel + ivec2(dx, dy), ivec2(0), target_res - 1);
            vec3 n_val = texelFetch(rtgi_raw_sampler, n_coord, 0).rgb;
            raw_m1 += n_val;
            raw_m2 += n_val * n_val;
        }
    }
    raw_m1 *= (1.0 / 9.0);
    raw_m2 *= (1.0 / 9.0);
    vec3 raw_sigma = sqrt(max(vec3(0.0), raw_m2 - raw_m1 * raw_m1));

    // Extreme-outlier guard only. The trace pass already clamps per-ray
    // luminance (RTGI_MAX_RADIANCE), and a neighbour-relative ceiling makes
    // the clamp itself flicker with the 2-ray neighbourhood while starving
    // legitimate emitter hits in dark scenes (brightness pumping). Real
    // outlier control is the history variance clip below, which now runs on
    // correctly tracked moments.
    const float absolute_radiance_cap = 32.0;
    if (current_lum > absolute_radiance_cap) {
        current_radiance *= absolute_radiance_cap / current_lum;
        current_lum = absolute_radiance_cap;
    }

    // NOTE: the history variance-clip box is built inside the history block
    // below, sized by the ACCUMULATED temporal variance. Sizing it from the
    // current frame's spatial statistics (the old bug) re-clamps the long
    // history into the current few-sample noise every frame, so a static
    // camera never converges past "slightly smoothed raw".

    // Reconstruct position in view and scene space (handle_jitter = true because depth buffer is jittered)
    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    float current_dist = -view_pos.z; // Exact metric distance in meters
    vec3 scene_pos = view_to_scene_space(view_pos);

    // Reproject to previous frame projection space
    vec3 prev_screen_pos = reproject_scene_space(scene_pos, false, false);
    vec2 prev_framebuffer_uv = taau_framebuffer_uv(prev_screen_pos.xy);
    // The history images are zero outside the active TAAU viewport; sampling
    // them there would resurrect stale/garbage data as "valid" history.
    bool inside_prev_screen = clamp01(prev_screen_pos.xy) == prev_screen_pos.xy
        && !taau_uv_outside_viewport(prev_framebuffer_uv);

#if GI_DEBUG == GI_DEBUG_REJECT
    float history_accepted = 0.0;
    float history_available = inside_prev_screen ? 1.0 : 0.0;
#endif

    float n_samples = 1.0;
    float alpha = 1.0;
    vec3 accumulated_radiance = current_radiance;
    float accumulated_sky = current_sky_weight;
    // M2 moment seed: center luminance squared plus the local raw variance so
    // freshly reset pixels expose a real noise level to the à-trous filter
    // instead of a structurally-zero variance. (M1 needs no storage: the
    // accumulated radiance's luminance already is the EMA of sample
    // luminance.)
    float m2 = current_lum * current_lum
        + dot(raw_sigma * raw_sigma, luminance_weights);

    if (inside_prev_screen) {
        // Point-sample history at the reprojected integer texel. Bilinear
        // filtering here would interpolate the packed sky/age bytes, the
        // octahedral normal and the stored distance, corrupting every
        // disocclusion test at depth/normal edges.
        ivec2 prev_texel = clamp(
            ivec2(prev_framebuffer_uv * vec2(target_res)),
            ivec2(0),
            target_res - 1
        );
        vec4 prev_sample = ping ? texelFetch(rtgi_history_sampler, prev_texel, 0)
                                : texelFetch(rtgi_accum_sampler, prev_texel, 0);
        vec4 prev_aux = ping ? texelFetch(rtgi_sky_history_sampler, prev_texel, 0)
                             : texelFetch(rtgi_sky_accum_sampler, prev_texel, 0);

        float prev_dist = prev_sample.a;
        float dist_diff = abs(current_dist - prev_dist);

        // SVGF Disocclusion Test 1: Tight metric depth tolerance
        float dist_tolerance = max(current_dist * 0.06, 0.10);
        bool depth_valid = (prev_dist > 0.05) && (dist_diff < dist_tolerance * 2.0);
        float depth_confidence = clamp01(1.0 - max(0.0, dist_diff - dist_tolerance) / dist_tolerance);

        // SVGF Disocclusion Test 2: Normal orientation consistency
        vec3 prev_world_normal = decode_unit_vector(prev_aux.ba);
        float normal_dot = dot(current_world_normal, prev_world_normal);
        bool normal_valid = normal_dot > 0.85;
        float normal_confidence = smoothstep(0.70, 0.90, normal_dot);

        bool history_valid = depth_valid && normal_valid;
        float total_confidence = depth_confidence * normal_confidence;

        if (history_valid) {
            // Unpack previous sample age and sky weight
            vec2 prev_sky_age = unpack_sky_age(prev_aux.g);
            float prev_sky = prev_sky_age.x;
            float prev_age = prev_sky_age.y;

            n_samples = min(prev_age + 1.0, 96.0);

            vec2 screen_motion = abs(prev_framebuffer_uv - uv) * view_res * render_scale;
            float motion_amount = length(screen_motion);
            // Dead-band below 1.5 px: TAAU jitter and reprojection round-off
            // register as sub-pixel "motion" every frame even when the camera
            // is perfectly still; without the gate they floor alpha at ~0.05
            // and cap the effective accumulation at ~20 frames, which is what
            // kept the converged history confetti-noisy.
            float motion_alpha = clamp01((motion_amount - 1.5) * 0.05);

            // SVGF Disocclusion Test 3: History Variance-Clipping.
            //
            // Box sized by the accumulated temporal variance: aux.r tracks M2
            // (EMA of sample luminance^2, alpha = 1/n); with M1 = luminance of
            // the accumulated radiance, var = max(0, M2 - M1^2) is the spread
            // of the frame-sample distribution the history was built from.
            // The floor is the current spatial variance of the mean estimate
            // (sigma^2 / n) so freshly-reset and low-variance pixels still get
            // a sane box. The box tightens as history ages (var_t tracks the
            // per-frame spread, not the standard error of the mean) and
            // widens with motion so reprojected smears are not locked out.
            float prev_lum = dot(prev_sample.rgb, luminance_weights);
            float var_t = max(0.0, prev_aux.r - prev_lum * prev_lum);
            float var_floor = dot(raw_sigma * raw_sigma, luminance_weights) / n_samples;
            // Standard-error scaling: var_t tracks the per-frame sample
            // spread, but the uncertainty of the accumulated estimate is
            // spread/sqrt(n). Shrinking the box below ~1.6/sqrt(n)*sigma
            // re-introduces the old clip-undoes-history bug; leaving it at
            // full spread stops killing retained fireflies (radiance-8
            // emitter dots against 0.2 walls survive any box wider than
            // ~0.2 sigma). 1.6/sqrt(n) sits between the two.
            float shrink = min(1.0, 1.6 * inversesqrt(n_samples));
            float sigma_clip = sqrt(max(var_t, var_floor))
                * shrink
                * (1.0 + 0.05 * motion_amount);
            vec3 clamp_box_min = max(vec3(0.0), raw_m1 - sigma_clip * 1.25);
            // No raw_max ceiling: bounding the box by the current 3x3 maximum
            // crushed legitimately brighter accumulated light (dark blotches
            // inside bright pixels).
            vec3 clamp_box_max = raw_m1 + sigma_clip * 1.25;

            vec3 clamped_prev_radiance = clamp(prev_sample.rgb, clamp_box_min, clamp_box_max);
            vec3 clip_delta = clamped_prev_radiance - prev_sample.rgb;
            bool history_clipped = dot(clip_delta, clip_delta) > 1e-8;

            // Adaptive temporal alpha from sample count clamped by motion:
            // alpha_temporal = 1 / n
            float alpha_temporal = 1.0 / n_samples;

            float base_alpha = max(alpha_temporal, motion_alpha);
            // Floor 0.01 (was 0.03): the old floor capped static accumulation
            // at ~33 effective frames regardless of the age budget (96).
            alpha = clamp(mix(1.0, base_alpha, total_confidence), 0.01, 1.0);

            accumulated_radiance = mix(clamped_prev_radiance, current_radiance, alpha);
            accumulated_sky = mix(prev_sky, current_sky_weight, alpha);

            // Second-moment tracking for the à-trous variance: M2 must be an
            // EMA of sample luminance SQUARED. Driving it toward
            // (accumulated luminance)^2 instead would collapse
            // variance = M2 - M1^2 to zero and disable all variance-guided
            // filtering. M1 needs no storage: the accumulated radiance's
            // luminance already is the matched EMA of sample luminance.
            float prev_m2_source = prev_aux.r;
            if (history_clipped) {
                // SVGF-style moment correction: after a clip, move the carried
                // second moment toward the squared clip distance so the next
                // frames relax back gradually instead of stair-stepping, and
                // so the filter sees the discontinuity as real variance.
                // Bounded to at most ~4x variance growth per frame (sigma
                // doubling): a clip can neither wedge the box permanently
                // open nor run away on a single huge drag.
                float drag2 = dot(clip_delta * clip_delta, luminance_weights);
                drag2 = min(drag2, 16.0 * max(var_t, var_floor) + var_floor * 4.0);
                prev_m2_source = prev_lum * prev_lum + max(var_floor * 4.0, drag2);
            }
            m2 = mix(prev_m2_source, current_lum * current_lum, alpha);

#if GI_DEBUG == GI_DEBUG_REJECT
            history_accepted = 1.0;
#endif
        }
    }

#if GI_DEBUG == GI_DEBUG_REJECT
    // Red: history rejected. Yellow: history accepted. Black: no history available.
    imageStore(rtgi_reject_img, texel, vec4(1.0 - history_accepted, history_available, 0.0, 1.0));
#endif

    // Auxiliary buffer:
    // .r = mean squared luminance M2 (variance = max(0, M2 - M1*M1), M1 = dot(radiance, luminance_weights))
    // .g = exact packed sky weight + sample age [0..2047]
    // .b = octahedral world normal X
    // .a = octahedral world normal Y
    vec2 oct_norm = encode_unit_vector(current_world_normal);
    vec4 aux_data = vec4(
        m2,
        pack_sky_age(accumulated_sky, n_samples),
        oct_norm.x,
        oct_norm.y
    );

    vec4 accum_data = vec4(accumulated_radiance, current_dist);

    if (ping) {
        imageStore(rtgi_accum_img, texel, accum_data);
        imageStore(rtgi_sky_accum_img, texel, aux_data);
    } else {
        imageStore(rtgi_history_img, texel, accum_data);
        imageStore(rtgi_sky_history_img, texel, aux_data);
    }
}
