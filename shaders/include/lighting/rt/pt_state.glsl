#if !defined INCLUDE_LIGHTING_RT_PT_STATE
#define INCLUDE_LIGHTING_RT_PT_STATE

// Temporal accumulation state packing and reset definitions.

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
#define PT_RESET_ADAPTIVE    9.0 // Adaptive test rejected stale history
#define PT_RESET_SPATIAL    10.0 // Spatial fallback used

// Number of reset reasons
#define PT_RESET_COUNT      11.0

// Spatial preaccumulation fallback weight cap for disoccluded pixels
#define PT_SPATIAL_MAX_WEIGHT 12.0

// Adaptive rejection thresholds for lighting changes
#define RTGI_ADAPT_LO         2.0
#define RTGI_ADAPT_HI         8.0
#define RTGI_ADAPT_SIGMA_EPS  0.05
#define RTGI_ADAPT_MIN_SAMPLES   16.0
#define RTGI_ADAPT_MIN_CONFIDENCE 0.9


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

// Static-state detector: detect camera translation, rotation, and projection changes
#define PT_STATIC_TRANSLATION_EPS 1e-3
#define PT_STATIC_ROTATION_EPS    1e-6
#define PT_STATIC_PROJECTION_EPS  1e-6

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
    bool identical = all(equal(camera_position, previous_camera_position))
        && pt_mat4_equal(model_view, previous_model_view)
        && pt_mat4_equal(projection, previous_projection);

    float translation = length(camera_position - previous_camera_position);

    vec3 view_forward = normalize(mat3(model_view)[2]);
    vec3 prev_view_forward = normalize(mat3(previous_model_view)[2]);
    float rotation_delta = 1.0 - dot(view_forward, prev_view_forward);

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
