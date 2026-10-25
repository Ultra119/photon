/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_temporal.csh:
  Temporal accumulation with motion reprojection & linear depth validation

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

uniform sampler2D rtgi_raw_sampler;
uniform sampler2D rtgi_history_sampler;
uniform sampler2D rtgi_accum_sampler;
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

    // Exact UV at the mathematical center of this half-resolution texel
    vec2 uv = (vec2(texel) + 0.5) / vec2(target_res);
    ivec2 full_texel = ivec2(uv * view_res);

    float depth = texelFetch(depthtex1, full_texel, 0).x;
    bool ping = (frameCounter & 1) == 0;

    if (depth >= 1.0) {
        if (ping) {
            imageStore(rtgi_accum_img, texel, vec4(0.0));
        } else {
            imageStore(rtgi_history_img, texel, vec4(0.0));
        }
        return;
    }

    vec3 current_radiance = texelFetch(rtgi_raw_sampler, texel, 0).rgb;

    // Reconstruct position in view and scene space (handle_jitter = true because depth buffer is jittered)
    vec3 screen_pos = vec3(uv, depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    float current_dist = -view_pos.z; // Exact metric distance in meters
    vec3 scene_pos = view_to_scene_space(view_pos);

    // Reproject to previous frame screen space
    vec3 prev_screen_pos = reproject_scene_space(scene_pos, false, false);
    bool inside_prev_screen = clamp01(prev_screen_pos.xy) == prev_screen_pos.xy;

    vec4 accumulated = vec4(current_radiance, current_dist);

    if (inside_prev_screen) {
        // Read from alternate buffer written in previous frame
        vec4 prev_sample = ping ? textureLod(rtgi_history_sampler, prev_screen_pos.xy, 0.0)
                                : textureLod(rtgi_accum_sampler, prev_screen_pos.xy, 0.0);

        float prev_dist = prev_sample.a;
        float dist_diff = abs(current_dist - prev_dist);
        float dist_tolerance = max(current_dist * 0.15, 0.40);

        // Valid if distance matches and history was initialized
        if (dist_diff < dist_tolerance && prev_dist > 0.05) {
            // Adaptive accumulation: 0.05 when still (20 frames accumulated), up to 0.25 when moving
            vec2 screen_motion = abs(prev_screen_pos.xy - uv) * view_res;
            float motion_factor = clamp01(length(screen_motion) * 0.03);
            float alpha = mix(0.05, 0.25, motion_factor);

            accumulated.rgb = mix(prev_sample.rgb, current_radiance, alpha);
        }
    }

    if (ping) {
        imageStore(rtgi_accum_img, texel, accumulated);
    } else {
        imageStore(rtgi_history_img, texel, accumulated);
    }
}
