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
// 7 bits on the sample count (0..127) and 4 on the sky fraction (16 levels).
// The sky fraction currently has no lighting consumer — the cave leak gate is
// applied per ray in rt_gi.glsl, not at composition — so 4 bits is enough for
// the preserved sky/local split; P4 (SH) must revisit it if it starts driving
// shading from this channel.

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

// Number of reasons above; also the debug view's colour count.
#define PT_RESET_COUNT       9.0

// --- packing ----------------------------------------------------------------

// 7-bit sample count + 4-bit sky fraction in one exactly-representable half.
float pack_sky_count(float sky, float count) {
    float sky_i = round(clamp01(sky) * 15.0);
    float count_i = clamp(round(count), 0.0, 127.0);
    return sky_i + count_i * 16.0;
}

vec2 unpack_sky_count(float packed) {
    float count = floor(packed * (1.0 / 16.0));
    float sky = (packed - count * 16.0) * (1.0 / 15.0);
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
struct PtStaticState {
    bool camera_static;
    bool projection_static;
};

PtStaticState pt_static_state(
    vec3 camera_position,
    vec3 previous_camera_position,
    mat4 model_view,
    mat4 previous_model_view,
    mat4 projection,
    mat4 previous_projection
) {
    // Translation: sub-millimetre in blocks.
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
    state.camera_static = translation < 1e-4 && rotation_delta < 1e-7;
    state.projection_static = projection_delta < 1e-6;
    return state;
}

#endif // INCLUDE_LIGHTING_RT_PT_STATE
