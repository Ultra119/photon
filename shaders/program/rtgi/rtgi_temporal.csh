/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI
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

// Single-buffered P1 state: written here, read by the debug view and by
// later passes of the same frame. Never read in this dispatch.
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

// ---------------------------------------------------------------------------
// P2: spatial preaccumulation fallback
// ---------------------------------------------------------------------------
// Only reached when a pixel's history is invalid, so a static frame never pays
// for it. It gathers the CURRENT frame's raw neighbourhood with depth and
// normal edge-stopping, and the caller treats the result as up to
// PT_SPATIAL_MAX_WEIGHT samples of evidence.
//
// Strided: 4x4 taps at stride 2 cover the same 7x7 footprint as 49 taps for a
// quarter of the fetches. The taps are edge-stopped against the current
// frame's G-buffer rather than the stored history, because the whole point is
// surfaces the history has never seen.
void pt_spatial_fallback(
    ivec2 texel,
    ivec2 target_res,
    float current_dist,
    vec3 current_normal,
    out vec4 radiance_and_sky,
    out float second_moment,
    out float weight
) {
    vec4 sum = vec4(0.0);
    float sum_lum2 = 0.0;
    float sum_weight = 0.0;

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

            float w = w_depth * w_normal;
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
    // luminance (RTGI_MAX_RADIANCE), and a neighbour-relative ceiling makes
    // the clamp itself flicker with the neighbourhood while starving
    // legitimate emitter hits in dark scenes (brightness pumping). Real
    // outlier control is this absolute cap plus the variance-guided à-trous
    // pyramid that runs after the temporal pass — matching the clip-free
    // temporal of the educational Minecraft-PTGI SVGF.
    const float absolute_radiance_cap = 32.0;
    if (current_lum > absolute_radiance_cap) {
        current_radiance *= absolute_radiance_cap / current_lum;
        current_lum = absolute_radiance_cap;
    }

    // P1 finite guard: a NaN or Inf raw sample would otherwise poison the
    // accumulated radiance, the M2 moment and every à-trous tap that reads
    // them, and it would never wash out (NaN * 0 is still NaN). Reject the
    // sample, not just the history.
    bool raw_finite = all(equal(current_radiance, current_radiance))
        && all(greaterThanEqual(current_radiance, vec3(0.0)))
        && (current_sky_weight == current_sky_weight);

    if (!raw_finite) {
        current_radiance = vec3(0.0);
        current_sky_weight = 0.0;
        current_lum = 0.0;
    }

    // P1 static-state detector. Jitter and frameCounter are deliberately not
    // signals: both advance on a perfectly static frame.
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

    // The distance this surface had in the PREVIOUS frame's camera. Comparing
    // the stored distance against the CURRENT camera's distance instead makes
    // every camera move look like a disocclusion: walk one block toward a wall
    // and the measurement changes by one block although the surface, the wall
    // and the light on it have not moved at all. At 60 Hz that is a large
    // fraction of the disocclusion tolerance, so the confidence collapsed on
    // any motion and the pixel fell back toward its raw sample -- the "moving
    // is pure noise, standing still is clean" behaviour.
    //
    // This is the first half of reproject_scene_space(): the surface has not
    // moved, so the previous camera's view-space depth of the current point is
    // exactly what the previous frame stored, to within texel quantisation.
    // Both are unjittered, so TAAU jitter cancels too.
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
    // M2 moment seed: center luminance squared plus the local raw variance so
    // freshly reset pixels expose a real noise level to the à-trous filter
    // instead of a structurally-zero variance. (M1 needs no storage: the
    // accumulated radiance's luminance already is the EMA of sample
    // luminance.)
    float m2 = current_lum * current_lum
        + dot(raw_sigma * raw_sigma, luminance_weights);

    if (!inside_prev_screen) {
        // The reprojected pixel left the previous viewport, so there is no
        // history to keep — not a disocclusion, just an absence.
        reset_reason = PT_RESET_OFFSCREEN;
    }

    if (inside_prev_screen) {
        // Neighborhood reprojection search (educational Minecraft-PTGI
        // concept, modernized): the reprojected point-sample is sub-pixel
        // accurate, but TAAU jitter and round-off can land the fetch half a
        // texel off — at depth/normal edges that fails the disocclusion
        // tests and resets the whole pixel to raw dots. Search the center
        // plus a 1-texel ring in the previous buffer and take the first tap
        // that passes both tests. History fetches stay point-sampled:
        // bilinear filtering would interpolate the packed sky/age bytes,
        // the octahedral normal and the stored distance, corrupting every
        // disocclusion test.
        const vec2 search_taps[9] = vec2[9](
            vec2( 0.0,  0.0),
            vec2( 0.5, -0.5), vec2(-0.5,  0.5), vec2( 0.5,  0.5), vec2(-0.5, -0.5),
            vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0)
        );

        bool history_valid = false;
        // The centre tap carries the diagnosis; the ring only recovers from
        // jitter, so a failure there is the honest reason for the reset.
        bool center_diagnosed = false;
        float total_confidence = 0.0;
        vec4 prev_sample = vec4(0.0);
        vec4 prev_aux = vec4(0.0);
        // Resample position for the radiance blend: the analytic reprojection
        // point normally, or the search tap that passed the tests.
        vec2 history_uv = prev_framebuffer_uv;

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

            // SVGF Disocclusion Test 1: Tight metric depth tolerance
            float dist_tolerance = max(current_dist * 0.06, 0.10);
            bool depth_valid = (prev_dist > 0.05) && (dist_diff < dist_tolerance * 2.0);
            float depth_confidence = clamp01(1.0 - max(0.0, dist_diff - dist_tolerance) / dist_tolerance);

            // SVGF Disocclusion Test 2: Normal orientation consistency
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

        if (history_valid) {
            // P1: unpack the previous accumulated SAMPLE COUNT and sky weight.
            vec2 prev_sky_count = unpack_sky_count(prev_aux.g);
            float prev_sky = prev_sky_count.x;
            float prev_count = prev_sky_count.y;

            // The count only grows when the surface, the camera and the
            // projection are all unchanged: a reprojected sample from a moving
            // camera is the same light re-measured, not new evidence, so it
            // must not be counted as an independent sample. Holding the count
            // (rather than resetting) keeps the tuned pan behaviour: the blend
            // rate stays exactly where it was instead of dumping the field
            // back to raw dots.
            // Bilinear history radiance at the reprojection point. Fetched
            // before the blend because the P2 adaptive test needs the history
            // MEAN, not just its sample count. Point sampling made the
            // accumulated noise pattern swim in texel steps under dolly -- the
            // "squares" that slide across the wall and pull toward each other
            // as the player moves closer or farther. Radiance is float data,
            // safe to interpolate; the packed sky/count bytes, octahedral
            // normal and stored distance in aux stay point-sampled at the
            // tested tap (bilinear filtering would corrupt them and every
            // disocclusion test with it).
            vec2 hist_px = history_uv * vec2(target_res) - 0.5;
            ivec2 hist_base = ivec2(floor(hist_px));
            vec2 hist_f = fract(hist_px);
            vec3 prev_rad = vec3(0.0);
            for (int oy = 0; oy <= 1; ++oy) {
                for (int ox = 0; ox <= 1; ++ox) {
                    ivec2 c = clamp(hist_base + ivec2(ox, oy), ivec2(0), ivec2(target_res) - 1);
                    float w = (ox == 0 ? 1.0 - hist_f.x : hist_f.x)
                            * (oy == 0 ? 1.0 - hist_f.y : hist_f.y);
                    prev_rad += (ping ? texelFetch(rtgi_history_sampler, c, 0).rgb
                                      : texelFetch(rtgi_accum_sampler, c, 0).rgb) * w;
                }
            }

            // --- P2 adaptive responsiveness --------------------------------
            //
            // Kappa drives rejection from a stored lightmap value; Photon has
            // no free aux channel to store one, so it compares two estimates
            // it already has: the spatially averaged current frame (3x3 mean)
            // against the temporal history mean, in units of the local sample
            // noise. prev_var = M2 - M1^2 is the variance of ONE stored
            // sample, but it is only used to bound the history side; the test
            // itself is driven by the spatial sigma, which is measured from
            // nine samples instead of one.
            //
            // This raises alpha rather than clipping the history VALUE, which
            // is why it is not the variance clip this pack deliberately does
            // not have: nothing moves toward the new sample except by
            // blending, so the estimate cannot pump in brightness the way a
            // clamped history does.
            //
            // M1 comes from the same point-sampled tap as M2, NOT from the
            // bilinear radiance fetch used for the blend. Mixing the two put
            // an interpolated mean into a point-sampled second moment, and at
            // any edge that drove var = M2 - M1^2 to zero -- and z with it
            // straight through the ceiling.
            float prev_m1 = dot(prev_sample.rgb, luminance_weights);
            float prev_var = max(prev_aux.r - prev_m1 * prev_m1, 0.0);

            // The "current" side of the test is the 3x3 neighbourhood MEAN,
            // not this pixel's single raw sample. At one ray per pixel a single
            // sample carries a standard deviation comparable to the signal, so
            // no threshold separates "the light changed" from "Monte-Carlo"
            // when the test is handed one sample -- which is what the first
            // version did, and it put clumps and raw dots all over the image
            // at every usable strength. Nine independent samples are three
            // times quieter, which is the whole margin.
            //
            // The neighbourhood already spans surfaces at geometric edges, and
            // that makes this test self-limiting there: `raw_sigma` inflates
            // with the same mismatch, so the denominator grows with it.
            float spatial_lum = dot(raw_m1, luminance_weights);
            float spatial_sigma = sqrt(max(
                dot(raw_sigma * raw_sigma, luminance_weights * luminance_weights),
                0.0
            ));
            float z_score = abs(spatial_lum - prev_m1)
                / (spatial_sigma * (1.0 / 3.0) + RTGI_ADAPT_SIGMA_EPS);

            bool accumulating = static_state.camera_static
                && static_state.projection_static
                && raw_finite;

            // The test cannot tell "the light changed" from "this pixel is no
            // longer measuring the same surface", so it is only asked when the
            // reprojection is trusted and the history is long enough to have a
            // mean worth testing against. On a pan the reprojected history and
            // the current raw sample disagree by construction; firing there is
            // how an adaptive term turns into the motion alpha this pack
            // removed on purpose.
            bool adapt_allowed = accumulating
                && total_confidence >= RTGI_ADAPT_MIN_CONFIDENCE
                && prev_count >= RTGI_ADAPT_MIN_SAMPLES;

            // Assigned, not declared: the converged flag at the end of main()
            // reads the outer `rejection`, and a shadowed local would leave it
            // at zero for every pixel that took this branch.
            rejection = adapt_allowed
                ? smoothstep(RTGI_ADAPT_LO, RTGI_ADAPT_HI, z_score)
                    * RTGI_ADAPT_STRENGTH
                : 0.0;
            bool rejected = rejection > 0.05;

            // The count grows while the camera moves, scaled by how much the
            // reprojection is trusted.
            //
            // It used to be HELD on motion, on the reasoning that a reprojected
            // sample is the same light re-measured and therefore not new
            // evidence. That is only half right: the light is the same, but the
            // rays are new and independent, so averaging them does reduce
            // variance by 1/N -- which is the entire basis of temporal reuse
            // under a moving camera, and the reason Kappa can be clean while
            // you move. What the reasoning was really protecting against is
            // BIAS from a wrong reprojection, and that is the disocclusion
            // tests' job, not the count's.
            //
            // Holding it had a worse consequence than the bias it avoided: a
            // pixel revealed by a pan (a disocclusion edge, or the strip of new
            // world at the leading edge) restarted at ~1 sample and then could
            // NEVER grow, for as long as the camera kept moving. Pan for a
            // second and the whole screen is newly revealed and pinned at that
            // one sample -- the field of raw dots that only settles after the
            // camera stops, and the columns that converge latest are the ones
            // revealed last, which is what reads as vertical stripes.
            sample_count = min(
                prev_count + current_spp * total_confidence,
                float(RTGI_SPP_CAP)
            );

            // alpha = this frame's samples / total samples. At one ray per
            // pixel this is the previous pure 1/n; at eight rays per pixel it
            // correctly reflects eight new samples instead of one, so the cap
            // means N samples of evidence and not N frames of wall clock.
            float alpha_temporal = current_spp / max(sample_count, current_spp);

            // Kappa-class floor (minAccumMult): the blend rate never decays
            // past this, so a fully converged pixel still tracks a changing
            // scene instead of being pinned at 1/RTGI_SPP_CAP forever. It is
            // also what bounds ghosting: however high the cap, no history can
            // be older than 1/min_alpha frames.
            float min_alpha = 0.01 * RTGI_MIN_ACCUM;
            alpha_temporal = max(alpha_temporal, min_alpha);
            alpha_temporal = max(alpha_temporal, rejection);

            // The count is deliberately NOT shortened by a rejection. An
            // earlier version set it to spp/alpha, which is self-consistent
            // and wrong in practice: one z spike dropped a converged pixel
            // from 128 samples to 3, and at 1 sample per frame it then took
            // about two seconds to climb back -- the "recovers 1-2 seconds
            // after the camera stops" behaviour, and the clumps that stayed.
            // The count is accumulated evidence; the floor and the rejection
            // are responsiveness overlays on top of it.

            reset_reason = !accumulating
                ? (static_state.projection_static
                    ? PT_RESET_CAMERA
                    : PT_RESET_PROJECTION)
                : (rejected ? PT_RESET_ADAPTIVE : PT_RESET_NONE);

            // Confidence keeps freshly-disoccluded pixels responsive. The
            // rejection survives the mix: a pixel whose geometry is fine but
            // whose lighting changed still has to react.
            alpha = clamp(mix(1.0, alpha_temporal, total_confidence), min_alpha, 1.0);

            accumulated_radiance = mix(prev_rad, current_radiance, alpha);
            accumulated_sky = mix(prev_sky, current_sky_weight, alpha);

            if (!raw_finite) {
                // History is geometrically valid but this frame's sample is
                // poisoned: keep the history rather than the NaN, and say so.
                accumulated_radiance = prev_rad;
                accumulated_sky = prev_sky;
                reset_reason = PT_RESET_NON_FINITE;
            }

            // Second-moment tracking for the à-trous variance: M2 must be an
            // EMA of sample luminance SQUARED. Driving it toward
            // (accumulated luminance)^2 instead would collapse
            // variance = M2 - M1^2 to zero and disable all variance-guided
            // filtering. M1 needs no storage: the accumulated radiance's
            // luminance already is the matched EMA of sample luminance.
            m2 = raw_finite
                ? mix(prev_aux.r, current_lum * current_lum, alpha)
                // A poisoned sample has no second moment to contribute;
                // folding zero in here would understate the variance of a
                // pixel whose history is still perfectly good.
                : prev_aux.r;

#if GI_DEBUG == GI_DEBUG_REJECT
            history_accepted = 1.0;
#endif
        } else {
            // Soft disocclusion instead of a hard reset: keep 10% of the
            // nearest-tap history and take 90% fresh. A hard reset snapped
            // the pixel from a converged field straight to raw single-frame
            // noise — the visible "the light on the wall shifts and
            // recalculates" jump after sustained motion. Age restarts at 2
            // so the new surface re-converges within a few frames.
            ivec2 center_prev = clamp(
                ivec2(prev_framebuffer_uv * vec2(target_res)),
                ivec2(0), ivec2(target_res) - 1
            );
            vec4 soft_prev = ping ? texelFetch(rtgi_history_sampler, center_prev, 0)
                                  : texelFetch(rtgi_accum_sampler, center_prev, 0);
            vec4 soft_aux = ping ? texelFetch(rtgi_sky_history_sampler, center_prev, 0)
                                 : texelFetch(rtgi_sky_accum_sampler, center_prev, 0);
            vec2 soft_sky_count = unpack_sky_count(soft_aux.g);

#if RTGI_SPATIAL_FALLBACK != 0
            // P2 spatial preaccumulation: a pixel with no usable history
            // starts from the current frame's neighbourhood instead of from
            // one raw sample. Falls through to the soft reset below when the
            // gather finds nothing (all sky, or every tap rejected).
            vec4 fb_radiance_sky = vec4(0.0);
            float fb_second_moment = 0.0;
            float fb_weight = 0.0;
            pt_spatial_fallback(
                texel,
                target_res,
                current_dist,
                current_world_normal,
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
                // M2 has to describe the noise of the ESTIMATE, not of one
                // raw sample: the a-trous reads var = M2 - M1^2 as "how
                // noisy is this pixel", and this pixel is an average of
                // total_samples of them. Reporting the single-sample variance
                // here would make the filter treat a freshly gathered pixel as
                // four times noisier than it is and over-blur it.
                float fb_lum = dot(fb_radiance_sky.rgb, luminance_weights);
                float fb_var = max(fb_second_moment - fb_lum * fb_lum, 0.0);
                float estimate_lum = dot(accumulated_radiance, luminance_weights);
                m2 = estimate_lum * estimate_lum + fb_var * inv_total;
                reset_reason = PT_RESET_SPATIAL;
            } else {
                accumulated_radiance = mix(soft_prev.rgb, current_radiance, 0.9);
                accumulated_sky = mix(soft_sky_count.x, current_sky_weight, 0.9);
                // The retained 10% is worth about a tenth of a sample, so the
                // count restarts just above one fresh sample.
                sample_count = current_spp / 0.9;
                alpha = 0.9;
                m2 = mix(soft_aux.r, current_lum * current_lum, 0.9);

                // Distinguish the two ways a reprojection can fail: the
                // previous texel simply is not there (off-screen), or the
                // surface moved (depth/normal disagreed). Both are soft
                // resets.
                if (!center_diagnosed) {
                    reset_reason = PT_RESET_DEPTH;
                }
            }
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

    // Reactive mask: how much of the pixel's history was thrown away this
    // frame. 0 = the full converged field was kept, 1 = nothing survived.
    // (P5 adds the material-driven water/wetness term on top of this.)
    float reactive = 1.0 - clamp01(
        (sample_count - current_spp) / max(float(RTGI_SPP_CAP) - current_spp, 1.0)
    );
    // A pixel that just rejected its history is not converged, whatever its
    // sample count says.
    float converged = step(float(RTGI_SPP_CAP) - 0.5, sample_count)
        * (1.0 - step(0.05, rejection));
    write_state(texel, reset_reason, reactive, valid_path_fraction, converged);
}
