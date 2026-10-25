/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_temporal.csh:
  Temporal accumulation with motion vector reprojection & variance clamping

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

    ivec2 full_texel = ivec2(vec2(texel) / render_scale);
    vec2 uv = (vec2(full_texel) + 0.5) * view_pixel_size;

    float depth = texelFetch(depthtex1, full_texel, 0).x;
    if (depth >= 1.0) {
        imageStore(rtgi_history_img, texel, vec4(0.0));
        imageStore(rtgi_accum_img, texel, vec4(0.0));
        return;
    }

    vec4 current_raw = texelFetch(rtgi_raw_sampler, texel, 0);

    // 3x3 Neighborhood statistics for variance clamping
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    float valid_samples = 0.0;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            ivec2 neighbor_texel = clamp(texel + ivec2(dx, dy), ivec2(0), target_res - 1);
            vec3 neighbor_color = texelFetch(rtgi_raw_sampler, neighbor_texel, 0).rgb;

            m1 += neighbor_color;
            m2 += neighbor_color * neighbor_color;
            valid_samples += 1.0;
        }
    }

    vec3 mu = m1 / valid_samples;
    vec3 sigma = sqrt(max(vec3(0.0), m2 / valid_samples - mu * mu));
    vec3 box_min = max(vec3(0.0), mu - 1.5 * sigma);
    vec3 box_max = mu + 1.5 * sigma;

    // Reproject to previous frame
    vec3 screen_pos = vec3(uv, depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    vec3 scene_pos = view_to_scene_space(view_pos);

    vec3 prev_screen_pos = reproject_scene_space(scene_pos, false, false);
    bool inside_prev_screen = clamp01(prev_screen_pos.xy) == prev_screen_pos.xy;

    vec4 accumulated;
    if (inside_prev_screen) {
        vec4 prev_sample = textureLod(rtgi_history_sampler, prev_screen_pos.xy, 0.0);

        // Clamp history to current neighborhood bounding box to prevent ghosting
        vec3 clamped_history = clamp(prev_sample.rgb, box_min, box_max);

        // Increase accumulation length (up to 32 frames)
        float history_weight = clamp(prev_sample.a, 0.0, 31.0);
        float alpha = 1.0 / (history_weight + 1.0);

        accumulated.rgb = mix(clamped_history, current_raw.rgb, alpha);
        accumulated.a = history_weight + 1.0;
    } else {
        accumulated = vec4(current_raw.rgb, 1.0);
    }

    imageStore(rtgi_history_img, texel, accumulated);
    imageStore(rtgi_accum_img, texel, accumulated);
}
