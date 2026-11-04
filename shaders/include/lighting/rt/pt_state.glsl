#if !defined INCLUDE_LIGHTING_RT_PT_STATE
#define INCLUDE_LIGHTING_RT_PT_STATE

// ---------------------------------------------------------------------------
//   PT reconstruction state contract (P1)
// ---------------------------------------------------------------------------
//
// One place that defines what the reconstruction chain stores, so the trace,
// temporal, filter and debug passes cannot drift apart. Two carriers:
//
//   1. rtgi_history_img / rtgi_accum_img (ping-pong, rgba16f)
//        .rgb accumulated radiance (M1: the matched EMA of sample luminance)
//        .a   linear view distance of the surface, for the depth test
//
//   2. rtgi_sky_history_img / rtgi_sky_accum_img (ping-pong, rgba16f)
//        .r   M2, the EMA of sample luminance SQUARED
//        .g   pack_sky_count(sky fraction, accumulated sample count)
//        .ba  octahedral world normal (exact, two channels)
//
//   3. rtgi_state_img (single buffered, rgba16f, rewritten every frame)
//        .r   reset reason (PT_RESET_*)
//        .g   reactive mask: how much history this pixel dropped this frame
//        .b   valid path fraction of this frame's raw samples
//        .a   converged flag (accumulated count reached the SPP cap)
//
// Carrier 3 is single buffered on purpose: it is written by rtgi_temporal and
// read by the filter chain and the debug views of the SAME frame, and by
// nothing else. A pass must never read a channel it writes in the same
// dispatch, so the cross-frame state (count, sky, M2, normal) stays in the
// ping-pong pair where it belongs.
//
// Packing budget: a half float stores integers exactly up to 2048, so every
// packed field below is laid out to stay inside that. pack_sky_count spends
// 8 bits on the sample count (0..255) and 3 on the sky fraction (8 levels),
// which is what lets P2 raise the accumulation cap from 32 to 255 samples.
//
// The sky fraction pays for that: 4 bits before P2, 3 now. It still has no
// lighting consumer — the cave leak gate is applied per ray in rt_gi.glsl, not
// at composition — but P4 (SH) has to buy the bit back (from the octahedral
// normal, which is the only other field with precision to spare) if it starts
// driving shading from this channel.

// Reset reasons. Ordered by how expensive the recovery is: NONE keeps a
// converged field, the disocclusion reasons keep part of it, DETECTOR_* and
// NON_FINITE discard it.
#define PT_RESET_NONE        0.0 // history accepted, camera and scene static
#define PT_RESET_NO_SURFACE  1.0 // sky or outside the viewport this frame
#define PT_RESET_OFFSCREEN   2.0 // reprojection left the previous viewport
#define PT_RESET_DEPTH       3.0 // depth disocclusion (soft, keeps 10%)
#define PT_RESET_NORMAL      4.0 // normal disocclusion (soft, keeps 10%)
#define PT_RESET_CAMERA      5.0 // static-state detector: camera moved
#define PT_RESET_PROJECTION  6.0 // static-state detector: FOV/projection changed
#define PT_RESET_NON_FINITE  7.0 // guard: raw sample was NaN/Inf or negative
#define PT_RESET_FIRST       8.0 // no usable history yet (resize, first frame)
#define PT_RESET_ADAPTIVE    9.0 // P2: the adaptive test rejected stale history
#define PT_RESET_SPATIAL   10.0 // P2: history invalid, spatial fallback used

// Number of reasons above; also the debug view's colour count.
#define PT_RESET_COUNT      11.0

// --- P2 spatial preaccumulation fallback ------------------------------------
//
// When the history is invalid the pixel used to start from ~1.1 samples (90%
// raw plus 10% of a stale, geometrically wrong history), which is the raw-dot
// flash on newly revealed surfaces. This gathers the current frame's raw
// neighbourhood instead -- the same trick that lets Kappa look clean
// immediately -- and starts the pixel from a real estimate.
//
// The effective sample count is clamped well below the tap count because
// neighbouring pixels are not independent: at 1 ray per pixel they are
// independent *samples*, but they are samples of a signal that varies across
// the neighbourhood, so treating 16 taps as 16 samples would overstate the
// evidence and under-report the variance to the a-trous filter.
#define PT_SPATIAL_MAX_WEIGHT 6.0

// --- P2 adaptive rejection thresholds --------------------------------------
//
// These are statistics, not art, and they are deliberately NOT exported as
// shader options: tuning them by eye is how an adaptive term turns into a
// noise amplifier. RTGI_ADAPT_STRENGTH in settings.glsl is the one dial, and 0
// turns the whole thing off.
//
// The sigma below is the noise of the 3x3 neighbourhood MEAN, which is three
// times quieter than a single sample -- so 2/8 here is 6/24 in single-sample
// units. That matters: the first version tested a single raw sample, and with
// one sample per frame the sample's own sigma is comparable to the signal, so
// no threshold can separate "the light changed" from "Monte-Carlo". Measured
// on the CPU model in pt_state_test.py, with 4000 frames of sampled noise
// (Gaussian, 5% heavy tail, sigma 0.25 on a 0.60 signal):
//
//   single raw sample, 2/6 sigma:   noise x9.8 at full strength  (what shipped
//                                   first, and what put clumps and dots all
//                                   over the image in-game)
//   3x3 mean, 1.5/6 sigma:          noise x1.12, 5 false fires per 1200 frames
//   3x3 mean, 2/8 sigma:            noise x1.00, 0 false fires  <-- shipped
//   3x3 mean, 4/12 sigma:           noise x1.00, 0 false fires, but only a
//                                   1.6x responsiveness gain
//
// 2/8 keeps the whole responsiveness win that is available without paying for
// it: 272 frames to absorb a step change disabled, 156 at strength 0.25, 130
// at 0.5, 57 at 1.0.
#define RTGI_ADAPT_LO         2.0 // sigma of the 3x3 mean: below this, noise
#define RTGI_ADAPT_HI         8.0 // sigma of the 3x3 mean: full rejection
#define RTGI_ADAPT_SIGMA_EPS 0.05 // luminance: keeps a zero-variance history
                                  // (a pitch-dark corner) from dividing by 0

// Gates on the test itself. All three exist because the statistic cannot tell
// "the light changed" from "this pixel is not measuring the same thing any
// more", and answering the second question with the first answer is exactly
// the motion alpha that dumps the accumulated field into raw dots on a pan.
#define RTGI_ADAPT_MIN_SAMPLES   16.0 // a shorter history is still converging,
                                      // so its own mean is noise: do not test
                                      // against it (it also stops the
                                      // reject -> short history -> reject loop)
#define RTGI_ADAPT_MIN_CONFIDENCE 0.9 // reprojection must be trusted

// --- packing ----------------------------------------------------------------

// 8-bit sample count (0..255) + 3-bit sky fraction (0..7), packed into one
// exactly-representable half: the largest value is 7 + 255*8 = 2047.
float pack_sky_count(float sky, float count) {
    float sky_i = round(clamp01(sky) * 7.0);
    float count_i = clamp(round(count), 0.0, 255.0);
    return sky_i + count_i * 8.0;
}

vec2 unpack_sky_count(float packed) {
    float count = floor(packed * (1.0 / 8.0));
    float sky = (packed - count * 8.0) * (1.0 / 7.0);
    return vec2(sky, count);
}

vec4 pt_state_pack(float reset_reason, float reactive, float valid_fraction, float converged) {
    return vec4(reset_reason, clamp01(reactive), clamp01(valid_fraction), step(0.5, converged));
}

float pt_state_reset(vec4 state) { return state.r; }
float pt_state_reactive(vec4 state) { return state.g; }
float pt_state_valid_fraction(vec4 state) { return state.b; }
bool pt_state_converged(vec4 state) { return state.a > 0.5; }

// --- static-state detector --------------------------------------------------
//
// The accumulation must survive everything that does not change the light
// transport, and must reset on everything that does. Signals Iris gives us
// every frame:
//
//   camera translation  cameraPosition vs previousCameraPosition
//   camera rotation     gbufferModelView vs gbufferPreviousModelView
//   FOV / projection    gbufferProjection vs gbufferPreviousProjection
//
// A TAA jitter advance or a frameCounter increment is deliberately NOT a
// signal: both happen on a perfectly static frame and resetting on either
// would throw away the accumulation every frame.
//
// Not detectable from Iris uniforms, and therefore not claimed: per-block
// scene revisions and emitter edits. A block edit changes the depth buffer at
// the edited pixels, which the depth disocclusion test already catches; an
// emitter edit changes only radiance, so it is absorbed by the blend. Both
// cases are visible as the matching reason code in the reset debug view.
//
// # Thresholds: measure, do not guess
//
// The first version of this detector used `rotation_delta < 1e-7`, which is
// inside the rounding error of the expression it guards. For a camera at rest
// the two matrices are the same numbers, so `dot(normalize(v), normalize(v))`
// is a float32 self-dot: over 40k sampled camera orientations 67% of them
// returned exactly 1.0, 29.1% returned slightly MORE than 1.0, and 3.9%
// returned slightly LESS, by up to 1.79e-7. The 3.9% therefore failed the
// test: at those orientations the sample count was frozen forever even though
// nothing was moving, which is exactly the "sometimes it stays in an
// intermediate state until I jiggle the camera a couple of degrees" report.
//
// Two guards instead of one:
//
//   1. Bit-exact equality of the previous and current matrices. At rest Iris
//      hands the pack the matrices it built last frame, so this is the normal
//      path and rounding cannot touch it.
//   2. A tolerance an order of magnitude above the measured noise, for the
//      frames where the matrices are merely very close.

// Blocks per frame. 1 mm/frame is 6 cm/s, well below anything a player can
// hold, and it clears the float32 spacing of cameraPosition out to +/-8192
// blocks (9.5e-4 there), which covers every coordinate reached in normal play.
#define PT_STATIC_TRANSLATION_EPS 1e-3

// `1 - dot` of the two view-forward vectors. 1e-6 is 5.6x the worst measured
// self-dot error (1.79e-7) and corresponds to 0.08 degrees per frame, about
// 1.7 pixels at 1080p and 90 degrees of FOV. A pan slower than that still
// counts as static, which is deliberate: the reprojection moves the history
// by well under a texel there, so treating it as new evidence costs nothing.
#define PT_STATIC_ROTATION_EPS 1e-6

// The two projection terms that carry FOV and aspect (both around 1.0, so the
// same absolute tolerance applies).
#define PT_STATIC_PROJECTION_EPS 1e-6

struct PtStaticState {
    bool camera_static;
    bool projection_static;
};

// GLSL's equal() does not take matrices, so compare the columns.
bool pt_mat4_equal(mat4 a, mat4 b) {
    return all(equal(a[0], b[0])) && all(equal(a[1], b[1]))
        && all(equal(a[2], b[2])) && all(equal(a[3], b[3]));
}

PtStaticState pt_static_state(
    vec3 camera_position,
    vec3 previous_camera_position,
    mat4 model_view,
    mat4 previous_model_view,
    mat4 projection,
    mat4 previous_projection
) {
    // Bit-exact path: nothing about the camera changed at all.
    bool identical = all(equal(camera_position, previous_camera_position))
        && pt_mat4_equal(model_view, previous_model_view)
        && pt_mat4_equal(projection, previous_projection);

    // Translation, in blocks.
    float translation = length(camera_position - previous_camera_position);

    // Rotation: compare the view basis, not the translation that also lives in
    // the modelview matrix. Any of the three basis vectors is enough.
    vec3 view_forward = normalize(mat3(model_view)[2]);
    vec3 prev_view_forward = normalize(mat3(previous_model_view)[2]);
    float rotation_delta = 1.0 - dot(view_forward, prev_view_forward);

    // Projection: the two terms that carry FOV and aspect.
    float projection_delta = abs(projection[0][0] - previous_projection[0][0])
        + abs(projection[1][1] - previous_projection[1][1]);

    PtStaticState state;
    state.camera_static = identical
        || (translation < PT_STATIC_TRANSLATION_EPS
            && rotation_delta < PT_STATIC_ROTATION_EPS);
    state.projection_static = identical
        || (projection_delta < PT_STATIC_PROJECTION_EPS);
    return state;
}

#endif // INCLUDE_LIGHTING_RT_PT_STATE
