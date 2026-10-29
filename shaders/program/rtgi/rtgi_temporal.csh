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
    vec3 raw_min = current_radiance;
    vec3 raw_max = current_radiance;
    vec3 raw_m1 = vec3(0.0);
    vec3 raw_m2 = vec3(0.0);

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            ivec2 n_coord = clamp(texel + ivec2(dx, dy), ivec2(0), target_res - 1);
            vec3 n_val = texelFetch(rtgi_raw_sampler, n_coord, 0).rgb;
            raw_min = min(raw_min, n_val);
            raw_max = max(raw_max, n_val);
            raw_m1 += n_val;
            raw_m2 += n_val * n_val;
        }
    }
    raw_m1 *= (1.0 / 9.0);
    raw_m2 *= (1.0 / 9.0);
    vec3 raw_sigma = sqrt(max(vec3(0.0), raw_m2 - raw_m1 * raw_m1));

    // Expand bounding box by 1.25 sigma to prevent color clipping on stationary gradients
    vec3 clamp_box_min = max(vec3(0.0), raw_m1 - raw_sigma * 1.25);
    vec3 clamp_box_max = raw_m1 + raw_sigma * 1.25;

    // Reconstruct position in view and scene space (handle_jitter = true because depth buffer is jittered)
    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    float current_dist = -view_pos.z; // Exact metric distance in meters
    vec3 scene_pos = view_to_scene_space(view_pos);

    // Reproject to previous frame projection space
    vec3 prev_screen_pos = reproject_scene_space(scene_pos, false, false);
    bool inside_prev_screen = clamp01(prev_screen_pos.xy) == prev_screen_pos.xy;
    vec2 prev_framebuffer_uv = taau_framebuffer_uv(prev_screen_pos.xy);

#if GI_DEBUG == GI_DEBUG_REJECT
    float history_accepted = 0.0;
    float history_available = inside_prev_screen ? 1.0 : 0.0;
#endif

    float n_samples = 1.0;
    float alpha = 1.0;
    vec3 accumulated_radiance = current_radiance;
    float accumulated_sky = current_sky_weight;
    float m1 = current_lum;
    float m2 = current_lum * current_lum;

    if (inside_prev_screen) {
        // Read from alternate buffers written in previous frame
        vec4 prev_sample = ping ? textureLod(rtgi_history_sampler, prev_framebuffer_uv, 0.0)
                                : textureLod(rtgi_accum_sampler, prev_framebuffer_uv, 0.0);
        vec4 prev_aux = ping ? textureLod(rtgi_sky_history_sampler, prev_framebuffer_uv, 0.0)
                             : textureLod(rtgi_sky_accum_sampler, prev_framebuffer_uv, 0.0);

        float prev_dist = prev_sample.a;
        float dist_diff = abs(current_dist - prev_dist);

        // SVGF Disocclusion Test 1: Tight metric depth tolerance
        float dist_tolerance = max(current_dist * 0.06, 0.10);
        bool depth_valid = (prev_dist > 0.05) && (dist_diff < dist_tolerance * 2.0);
        float depth_confidence = clamp01(1.0 - max(0.0, dist_diff - dist_tolerance) / dist_tolerance);

        // SVGF Disocclusion Test 2: Normal orientation consistency
        vec3 prev_world_normal = decode_unit_vector(unpack_unorm_2x8(prev_aux.b));
        float normal_dot = dot(current_world_normal, prev_world_normal);
        bool normal_valid = normal_dot > 0.85;
        float normal_confidence = smoothstep(0.70, 0.90, normal_dot);

        bool history_valid = depth_valid && normal_valid;
        float total_confidence = depth_confidence * normal_confidence;

        if (history_valid) {
            // Unpack previous sample age and sky weight
            vec2 prev_sky_age = unpack_unorm_2x8(prev_aux.a);
            float prev_sky = prev_sky_age.x;
            float prev_age = prev_sky_age.y * 64.0;

            n_samples = min(prev_age + 1.0, 64.0);

            // SVGF Disocclusion Test 3: History Variance-Clipping
            vec3 clamped_prev_radiance = clamp(prev_sample.rgb, clamp_box_min, clamp_box_max);

            // Adaptive temporal alpha from sample count clamped by motion:
            // alpha_temporal = 1 / n
            float alpha_temporal = 1.0 / n_samples;

            vec2 screen_motion = abs(prev_framebuffer_uv - uv) * view_res * render_scale;
            float motion_amount = length(screen_motion);
            float motion_alpha = clamp01(motion_amount * 0.08);

            float base_alpha = max(alpha_temporal, motion_alpha);
            alpha = clamp(mix(1.0, base_alpha, total_confidence), 0.03, 1.0);

            accumulated_radiance = mix(clamped_prev_radiance, current_radiance, alpha);
            accumulated_sky = mix(prev_sky, current_sky_weight, alpha);

            // Moment tracking for local variance estimation
            m1 = mix(prev_aux.r, current_lum, alpha);
            m2 = mix(prev_aux.g, current_lum * current_lum, alpha);

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
    // .r = mean luminance M1
    // .g = mean squared luminance M2 (variance = max(0, M2 - M1*M1))
    // .b = packed octahedral world normal
    // .a = packed sky weight + sample age (n in [1, 64])
    vec2 packed_sky_age = vec2(clamp01(accumulated_sky), clamp01(n_samples / 64.0));
    vec4 aux_data = vec4(
        m1,
        m2,
        pack_unorm_2x8(encode_unit_vector(current_world_normal)),
        pack_unorm_2x8(packed_sky_age)
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
