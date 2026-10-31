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
        float total_confidence = 0.0;
        vec4 prev_sample = vec4(0.0);
        vec4 prev_aux = vec4(0.0);

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

            if (depth_valid && normal_valid) {
                history_valid = true;
                total_confidence = depth_confidence * normal_confidence;
            }
        }

        if (history_valid) {
            // Unpack previous sample age and sky weight
            vec2 prev_sky_age = unpack_sky_age(prev_aux.g);
            float prev_sky = prev_sky_age.x;
            float prev_age = prev_sky_age.y;

            n_samples = min(prev_age + 1.0, 96.0);

            // Pure 1/n blend — NO motion-driven alpha and NO variance clip
            // (both the educational Minecraft-PTGI temporal and SEUS work
            // this way). Motion is handled entirely by the reprojection and
            // the disocclusion tests above: a motion alpha dumped the
            // accumulated light field back to raw dots on every pan (it hit
            // 1.0 at ~22 RTGI px/frame) and forced a full re-convergence
            // after every stop. Ghosting during fast motion is the standard
            // tradeoff for keeping the field intact.
            float alpha_temporal = 1.0 / n_samples;

            // Confidence keeps freshly-disoccluded pixels responsive.
            alpha = clamp(mix(1.0, alpha_temporal, total_confidence), 0.01, 1.0);

            accumulated_radiance = mix(prev_sample.rgb, current_radiance, alpha);
            accumulated_sky = mix(prev_sky, current_sky_weight, alpha);

            // Second-moment tracking for the à-trous variance: M2 must be an
            // EMA of sample luminance SQUARED. Driving it toward
            // (accumulated luminance)^2 instead would collapse
            // variance = M2 - M1^2 to zero and disable all variance-guided
            // filtering. M1 needs no storage: the accumulated radiance's
            // luminance already is the matched EMA of sample luminance.
            m2 = mix(prev_aux.r, current_lum * current_lum, alpha);

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
