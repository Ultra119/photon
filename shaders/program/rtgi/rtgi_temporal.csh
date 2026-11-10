// SVGF Temporal Reconstruction with Disocclusion & Moment Tracking

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

layout(rgba16f) writeonly uniform image2D rtgi_state_img;

uniform sampler2D rtgi_raw_sampler;
uniform sampler2D rtgi_history_sampler;
uniform sampler2D rtgi_accum_sampler;
uniform sampler2D rtgi_sky_history_sampler;
uniform sampler2D rtgi_sky_accum_sampler;
uniform sampler2D rtgi_state_sampler;

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
#include "/include/lighting/rt/pt_state.glsl"

// Every exit path writes the state image: a pixel that leaves the accumulation
// must still say why, or the debug view reads whatever the previous frame left
// in a texel nobody owns.
void write_state(ivec2 texel, float reason, float reactive, float valid_fraction, float converged) {
    imageStore(
        rtgi_state_img,
        texel,
        pt_state_pack(reason, reactive, valid_fraction, converged)
    );
}

void write_zero(ivec2 texel, bool ping, float reason) {
    if (ping) {
        imageStore(rtgi_accum_img, texel, vec4(0.0));
        imageStore(rtgi_sky_accum_img, texel, vec4(0.0));
    } else {
        imageStore(rtgi_history_img, texel, vec4(0.0));
        imageStore(rtgi_sky_history_img, texel, vec4(0.0));
    }
    write_state(texel, reason, 1.0, 0.0, 0.0);
}

// Spatial preaccumulation fallback
// Only reached when a pixel's history is invalid, so a static frame never pays
// for it. It gathers the CURRENT frame's raw neighbourhood with depth and
// normal edge-stopping, and the caller treats the result as up to
// PT_SPATIAL_MAX_WEIGHT samples of evidence.
void pt_spatial_fallback(
    ivec2 texel,
    ivec2 target_res,
    float current_dist,
    vec3 current_normal,
    vec3 current_view_pos,
    out vec4 radiance_and_sky,
    out float second_moment,
    out float weight
) {
    vec4 sum = vec4(0.0);
    float sum_lum2 = 0.0;
    float sum_weight = 0.0;

    vec3 current_view_norm = mat3(gbufferModelView) * current_normal;

    for (int sy = -3; sy <= 3; sy += 2) {
        for (int sx = -3; sx <= 3; sx += 2) {
            ivec2 n_coord = clamp(texel + ivec2(sx, sy), ivec2(0), target_res - 1);
            vec2 n_uv = (vec2(n_coord) + 0.5) / vec2(target_res);
            ivec2 n_full = ivec2(taau_framebuffer_uv(n_uv) * view_res);

            float n_depth = texelFetch(depthtex1, n_full, 0).x;
            if (n_depth >= 1.0) {
                continue; // sky: no surface to share lighting with
            }

            vec3 n_view_pos = screen_to_view_space(
                vec3(taau_projection_uv(n_uv), n_depth), true
            );
            float n_dist = -n_view_pos.z;

            // Same tolerance scale as the disocclusion test, soft rather than
            // binary so the gather degrades gracefully at a sloped edge.
            float dist_tolerance = max(current_dist * 0.06, 0.10);
            float w_depth = exp(-abs(n_dist - current_dist) / dist_tolerance);

            vec3 n_normal = decode_unit_vector(
                unpack_unorm_2x8(texelFetch(colortex1, n_full, 0).z)
            );
            // 8th power: a 30 degree tilt already halves the weight.
            float w_normal = pow(max(dot(n_normal, current_normal), 0.0), 8.0);

            // Plane consistency: reject neighbors that do not lie on the same flat surface tangent plane
            float plane_dist = abs(dot(current_view_norm, n_view_pos - current_view_pos));
            float plane_tolerance = max(current_dist * 0.05, 0.12);
            float w_plane = exp(-plane_dist / plane_tolerance);

            float w = w_depth * w_normal * w_plane;
            if (w < 1e-3) {
                continue;
            }

            vec4 n_raw = texelFetch(rtgi_raw_sampler, n_coord, 0);
            sum += n_raw * w;
            sum_lum2 += dot(n_raw.rgb, luminance_weights)
                * dot(n_raw.rgb, luminance_weights) * w;
            sum_weight += w;
        }
    }

    float inv = 1.0 / max(sum_weight, 1e-4);
    radiance_and_sky = sum * inv;
    second_moment = sum_lum2 * inv;
    weight = sum_weight;
}

// Catmull-Rom resampling weights for taps at -1, 0, +1, +2 relative to the
// sample point
vec4 catmull_rom_weights(float f) {
    float f2 = f * f;
    float f3 = f2 * f;
    return vec4(
        -0.5 * f3 + f2 - 0.5 * f,
         1.5 * f3 - 2.5 * f2 + 1.0,
        -1.5 * f3 + 2.0 * f2 + 0.5 * f,
         0.5 * f3 - 0.5 * f2
    );
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
        write_zero(texel, ping, PT_RESET_NO_SURFACE);
        return;
    }

    ivec2 full_texel = ivec2(uv * view_res);

    float depth = texelFetch(depthtex1, full_texel, 0).x;

    if (depth >= 1.0) {
        write_zero(texel, ping, PT_RESET_NO_SURFACE);
        return;
    }

    // The trace pass wrote the valid-path fraction of this frame's rays into
    // the state image's .b channel; carry it through and replace the other
    // three channels with this pass's verdict.
    float valid_path_fraction = pt_state_valid_fraction(
        texelFetch(rtgi_state_sampler, texel, 0)
    );

    // Current frame raw sample
    vec4 raw_sample = texelFetch(rtgi_raw_sampler, texel, 0);
    vec3 current_radiance = raw_sample.rgb;
    float current_sky_weight = clamp01(raw_sample.a);
    float current_lum = dot(current_radiance, luminance_weights);

    // Current surface geometric data from G-buffer
    vec4 gbuf = texelFetch(colortex1, full_texel, 0);
    vec3 current_world_normal = decode_unit_vector(unpack_unorm_2x8(gbuf.z));

    // 3x3 neighbourhood statistics: spatial sigma seeds the M2 moment on
    // freshly-reset pixels so the à-trous filter starts with a real variance.
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
    // Absolute radiance cap
    const float absolute_radiance_cap = 32.0;
    if (current_lum > absolute_radiance_cap) {
        current_radiance *= absolute_radiance_cap / current_lum;
        current_lum = absolute_radiance_cap;
    }

    // Finite sample guard
    bool raw_finite = all(equal(current_radiance, current_radiance))
        && all(greaterThanEqual(current_radiance, vec3(0.0)))
        && (current_sky_weight == current_sky_weight);

    if (!raw_finite) {
        current_radiance = vec3(0.0);
        current_sky_weight = 0.0;
        current_lum = 0.0;
    }

    // Static-state detector
    PtStaticState static_state = pt_static_state(
        cameraPosition,
        previousCameraPosition,
        gbufferModelView,
        gbufferPreviousModelView,
        gbufferProjection,
        gbufferPreviousProjection
    );

    // Reconstruct position in view and scene space (handle_jitter = true because depth buffer is jittered)
    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    float current_dist = -view_pos.z; // Exact metric distance in meters
    vec3 scene_pos = view_to_scene_space(view_pos);

    vec3 prev_camera_view_pos = transform(
        gbufferPreviousModelView,
        scene_pos + (cameraPosition - previousCameraPosition)
    );
    float expected_prev_dist = -prev_camera_view_pos.z;

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

    // Samples, not frames: this frame contributed RTGI_RAY_COUNT traced rays.
    float current_spp = float(RTGI_RAY_COUNT);
    float sample_count = current_spp;
    float alpha = 1.0;
    float reset_reason = PT_RESET_FIRST; // no history was available at all
    float rejection = 0.0;
    vec3 accumulated_radiance = current_radiance;
    float accumulated_sky = current_sky_weight;
    // M2 moment seed
    float m2 = current_lum * current_lum
        + dot(raw_sigma * raw_sigma, luminance_weights);

    if (!inside_prev_screen) {
        // The reprojected pixel left the previous viewport, so there is no
        // history to keep — not a disocclusion, just an absence.
        reset_reason = PT_RESET_OFFSCREEN;
    }

    const vec2 search_taps[9] = vec2[9](
        vec2( 0.0,  0.0),
        vec2( 0.5, -0.5), vec2(-0.5,  0.5), vec2( 0.5,  0.5), vec2(-0.5, -0.5),
        vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0)
    );

    bool history_valid = false;
    bool center_diagnosed = false;
    float total_confidence = 0.0;
    vec4 prev_sample = vec4(0.0);
    vec4 prev_aux = vec4(0.0);
    vec2 history_uv = prev_framebuffer_uv;

    if (inside_prev_screen) {
        for (int tap = 0; tap < 9 && !history_valid; ++tap) {
            vec2 tap_uv = prev_framebuffer_uv + search_taps[tap] / vec2(target_res);
            bool tap_inside = clamp01(tap_uv) == tap_uv
                && !taau_uv_outside_viewport(tap_uv);
            if (!tap_inside) {
                continue;
            }

            ivec2 prev_texel = clamp(
                ivec2(tap_uv * vec2(target_res)),
                ivec2(0),
                target_res - 1
            );
            // Neighbor taps can round to the same texel; harmless duplicate.
            prev_sample = ping ? texelFetch(rtgi_history_sampler, prev_texel, 0)
                               : texelFetch(rtgi_accum_sampler, prev_texel, 0);
            prev_aux = ping ? texelFetch(rtgi_sky_history_sampler, prev_texel, 0)
                            : texelFetch(rtgi_sky_accum_sampler, prev_texel, 0);

            float prev_dist = prev_sample.a;
            // Motion-invariant: both sides are measured from the PREVIOUS
            // camera, so this is geometric disagreement only.
            float dist_diff = abs(expected_prev_dist - prev_dist);

            // Tight metric depth tolerance
            float dist_tolerance = max(current_dist * 0.06, 0.10);
            bool depth_valid = (prev_dist > 0.05) && (dist_diff < dist_tolerance * 2.0);
            float depth_confidence = clamp01(1.0 - max(0.0, dist_diff - dist_tolerance) / dist_tolerance);

            // Normal orientation consistency
            vec3 prev_world_normal = decode_unit_vector(prev_aux.ba);
            float normal_dot = dot(current_world_normal, prev_world_normal);
            bool normal_valid = normal_dot > 0.85;
            float normal_confidence = smoothstep(0.70, 0.90, normal_dot);

            if (tap == 0) {
                center_diagnosed = true;
                reset_reason = depth_valid ? PT_RESET_NORMAL : PT_RESET_DEPTH;
            }

            if (depth_valid && normal_valid) {
                history_valid = true;
                total_confidence = depth_confidence * normal_confidence;
                history_uv = tap_uv;
            }
        }
    }

    if (history_valid) {
            vec2 prev_sky_count = unpack_sky_count(prev_aux.g);
            float prev_sky = prev_sky_count.x;
            float prev_count = prev_sky_count.y;

            // Catmull-Rom resampling of history radiance at the reprojection point.
            vec2 hist_px = history_uv * vec2(target_res) - 0.5;
            ivec2 hist_base = ivec2(floor(hist_px));
            vec2 hist_f = fract(hist_px);
            vec4 hist_wx = catmull_rom_weights(hist_f.x);
            vec4 hist_wy = catmull_rom_weights(hist_f.y);
            vec3 prev_rad = vec3(0.0);
            float hist_weight_sum = 0.0;
            for (int oy = -1; oy <= 2; ++oy) {
                float wy = hist_wy[oy + 1];
                for (int ox = -1; ox <= 2; ++ox) {
                    float wx = hist_wx[ox + 1];
                    ivec2 c = clamp(
                        hist_base + ivec2(ox, oy), ivec2(0), target_res - 1
                    );
                    float w = wx * wy;
                    prev_rad += (ping ? texelFetch(rtgi_history_sampler, c, 0).rgb
                                      : texelFetch(rtgi_accum_sampler, c, 0).rgb) * w;
                    hist_weight_sum += w;
                }
            }
            prev_rad = max(prev_rad / max(hist_weight_sum, 1e-4), vec3(0.0));

            // Adaptive responsiveness: compare current 3x3 spatial mean with temporal history.
            float prev_m1 = dot(prev_sample.rgb, luminance_weights);
            float prev_var = max(prev_aux.r - prev_m1 * prev_m1, 0.0);

            // Two-sample z-score testing difference between spatial mean and temporal history mean.
            float spatial_lum = dot(raw_m1, luminance_weights);
            float spatial_sigma = sqrt(max(
                dot(raw_sigma * raw_sigma, luminance_weights * luminance_weights),
                0.0
            ));
            float test_var = (spatial_sigma * spatial_sigma + prev_var) * (1.0 / 9.0);
            float test_sigma = sqrt(max(test_var, 0.0));
            float z_score = abs(spatial_lum - prev_m1)
                / (test_sigma + RTGI_ADAPT_SIGMA_EPS);

            bool accumulating = static_state.camera_static
                && static_state.projection_static
                && raw_finite;

            bool adapt_allowed = accumulating
                && total_confidence >= RTGI_ADAPT_MIN_CONFIDENCE
                && prev_count >= RTGI_ADAPT_MIN_SAMPLES;

            rejection = adapt_allowed
                ? smoothstep(RTGI_ADAPT_LO, RTGI_ADAPT_HI, z_score)
                    * RTGI_ADAPT_STRENGTH
                : 0.0;
            bool rejected = rejection > 0.05;

            // Accumulate sample count weighted by reprojection confidence.
            sample_count = min(
                prev_count + current_spp * total_confidence,
                float(RTGI_SPP_CAP)
            );

            // Temporal accumulation weight (alpha = current_spp / sample_count).
            float alpha_temporal = current_spp / max(sample_count, current_spp);
            float min_alpha = 0.01 * RTGI_MIN_ACCUM;
            alpha_temporal = max(alpha_temporal, min_alpha);
            alpha_temporal = max(alpha_temporal, rejection);

            reset_reason = !accumulating
                ? (static_state.projection_static
                    ? PT_RESET_CAMERA
                    : PT_RESET_PROJECTION)
                : (rejected ? PT_RESET_ADAPTIVE : PT_RESET_NONE);

            float conf_weight = smoothstep(0.0, 0.75, total_confidence);
            alpha = clamp(mix(0.20, alpha_temporal, conf_weight), min_alpha, 1.0);

            accumulated_radiance = mix(prev_rad, current_radiance, alpha);
            accumulated_sky = mix(prev_sky, current_sky_weight, alpha);

            if (!raw_finite) {
                accumulated_radiance = prev_rad;
                accumulated_sky = prev_sky;
                reset_reason = PT_RESET_NON_FINITE;
            }

            m2 = raw_finite
                ? mix(prev_aux.r, current_lum * current_lum, alpha)
                // A poisoned sample has no second moment to contribute
                : prev_aux.r;

#if GI_DEBUG == GI_DEBUG_REJECT
            history_accepted = 1.0;
#endif
        } else {
#if RTGI_SPATIAL_FALLBACK != 0
            // Spatial preaccumulation fallback for invalid history pixels.
            vec4 fb_radiance_sky = vec4(0.0);
            float fb_second_moment = 0.0;
            float fb_weight = 0.0;
            pt_spatial_fallback(
                texel,
                target_res,
                current_dist,
                current_world_normal,
                view_pos,
                fb_radiance_sky,
                fb_second_moment,
                fb_weight
            );

            // Neighbours are not independent samples of one quantity, so the
            // gather is credited with far fewer samples than it has taps.
            float spatial_samples = min(fb_weight, PT_SPATIAL_MAX_WEIGHT);
            bool spatial_ok = spatial_samples >= 1.0;
#else
            vec4 fb_radiance_sky = vec4(0.0);
            float fb_second_moment = 0.0;
            float spatial_samples = 0.0;
            bool spatial_ok = false;
#endif

            if (spatial_ok) {
                // Combine the gathered neighbourhood with this pixel's own
                // sample, weighted by how much evidence each represents.
                float total_samples = spatial_samples + 1.0;
                float inv_total = 1.0 / total_samples;
                accumulated_radiance
                    = (fb_radiance_sky.rgb * spatial_samples + current_radiance)
                    * inv_total;
                accumulated_sky
                    = (fb_radiance_sky.a * spatial_samples + current_sky_weight)
                    * inv_total;
                sample_count = total_samples;
                alpha = inv_total;
                // Scaled variance of the gathered estimate.
                float fb_lum = dot(fb_radiance_sky.rgb, luminance_weights);
                float fb_var = max(fb_second_moment - fb_lum * fb_lum, 0.0);
                float estimate_lum = dot(accumulated_radiance, luminance_weights);
                m2 = estimate_lum * estimate_lum + fb_var * inv_total;
                reset_reason = PT_RESET_SPATIAL;
            } else {
                // Rejected history and spatial fallback found no valid matching neighbours:
                // Cleanly reset to the current frame to prevent trailing ghosts.
                accumulated_radiance = current_radiance;
                accumulated_sky = current_sky_weight;
                sample_count = current_spp;
                alpha = 1.0;
                reset_reason = inside_prev_screen ? PT_RESET_DEPTH : PT_RESET_OFFSCREEN;
            }
        }

#if GI_DEBUG == GI_DEBUG_REJECT
    // Red: history rejected. Yellow: history accepted. Black: no history available.
    imageStore(rtgi_reject_img, texel, vec4(1.0 - history_accepted, history_available, 0.0, 1.0));
#endif

    // Auxiliary buffer (see /include/lighting/rt/pt_state.glsl for the contract):
    // .r = mean squared luminance M2 (variance = max(0, M2 - M1*M1), M1 = dot(radiance, luminance_weights))
    // .g = exact packed sky fraction (4 bits) + accumulated sample count (7 bits)
    // .b = octahedral world normal X
    // .a = octahedral world normal Y
    vec2 oct_norm = encode_unit_vector(current_world_normal);
    vec4 aux_data = vec4(
        m2,
        pack_sky_count(accumulated_sky, sample_count),
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

    // Reactive mask: fraction of pixel history discarded this frame.
    float reactive = 1.0 - clamp01(
        (sample_count - current_spp) / max(float(RTGI_SPP_CAP) - current_spp, 1.0)
    );
    float converged = step(float(RTGI_SPP_CAP) - 0.5, sample_count)
        * (1.0 - step(0.05, rejection));
    write_state(texel, reset_reason, reactive, valid_path_fraction, converged);
}
