/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_filter.csh:
  25-tap tangent-plane edge-avoiding bilateral filter (SEUS GFME / SVGF style)

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

layout(rgba16f) writeonly uniform image2D rtgi_filtered_img;

uniform sampler2D rtgi_accum_sampler;
uniform sampler2D rtgi_history_sampler;
uniform sampler2D depthtex1;
uniform sampler2D colortex1; // gbuffer0

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;
uniform int frameCounter;

uniform vec2 view_res;
uniform vec2 view_pixel_size;

uniform float near;
uniform float far;
uniform vec2 taa_offset;

#include "/include/utility/color.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"

vec4 sample_accum_data(ivec2 t, bool ping) {
    return ping ? texelFetch(rtgi_accum_sampler, t, 0)
                : texelFetch(rtgi_history_sampler, t, 0);
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

    ivec2 full_texel = ivec2(vec2(texel) / render_scale);
    float center_depth = texelFetch(depthtex1, full_texel, 0).x;
    if (center_depth >= 1.0) {
        imageStore(rtgi_filtered_img, texel, vec4(0.0));
        return;
    }

    bool ping = (frameCounter & 1) == 0;

    vec2 center_uv = (vec2(full_texel) + 0.5) * view_pixel_size;
    vec3 center_screen_pos = vec3(center_uv, center_depth);
    vec3 center_view_pos = screen_to_view_space(center_screen_pos, false);

    vec4 center_gbuf = texelFetch(colortex1, full_texel, 0);
    vec3 center_world_normal = decode_unit_vector(unpack_unorm_2x8(center_gbuf.z));
    vec3 center_view_normal = mat3(gbufferModelView) * center_world_normal;

    vec4 center_sample = sample_accum_data(texel, ping);
    vec3 center_radiance = center_sample.rgb;
    float center_lum = dot(center_radiance, luminance_weights);
    float center_lum_reinhard = center_lum / (1.0 + center_lum);

    // 25-tap edge-avoiding bilateral filter with tangent-plane depth projection
    vec3 sum_radiance = vec3(0.0);
    float sum_weights = 0.0;

    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            ivec2 neighbor_texel = clamp(texel + ivec2(dx, dy), ivec2(0), target_res - 1);
            ivec2 neighbor_full = ivec2(vec2(neighbor_texel) / render_scale);

            float n_depth = texelFetch(depthtex1, neighbor_full, 0).x;
            vec2 n_uv = (vec2(neighbor_full) + 0.5) * view_pixel_size;
            vec3 n_view_pos = screen_to_view_space(vec3(n_uv, n_depth), false);

            vec4 n_gbuf = texelFetch(colortex1, neighbor_full, 0);
            vec3 n_world_normal = decode_unit_vector(unpack_unorm_2x8(n_gbuf.z));
            vec3 n_color = sample_accum_data(neighbor_texel, ping).rgb;

            // 1. Spatial gaussian weight (sigma ~ 1.5)
            float dist_sq = float(dx * dx + dy * dy);
            float weight_spatial = exp(-0.5 * dist_sq * (1.0 / 2.25));

            // 2. Tangent-plane depth weight (SEUS / SVGF style)
            // Measures perpendicular distance from center surface plane: 0 on flat floors/walls!
            vec3 pos_diff = n_view_pos - center_view_pos;
            float plane_dist = abs(dot(pos_diff, center_view_normal));
            float weight_depth = exp(-plane_dist * plane_dist * 35.0);

            // 3. Normal weight (rejects surfaces facing different directions)
            float normal_dot = max(0.0, dot(center_world_normal, n_world_normal));
            float weight_normal = pow(normal_dot, 16.0);

            // 4. Soft Reinhard luminance weight (prevents fireflies from spreading without rejecting diffuse light)
            float n_lum = dot(n_color, luminance_weights);
            float n_lum_reinhard = n_lum / (1.0 + n_lum);
            float lum_diff = abs(center_lum_reinhard - n_lum_reinhard);
            float weight_lum = exp(-lum_diff * lum_diff * 4.0);

            float weight = weight_spatial * weight_depth * weight_normal * weight_lum;

            sum_radiance += n_color * weight;
            sum_weights += weight;
        }
    }

    vec3 filtered = (sum_weights > 1e-4) ? (sum_radiance / sum_weights) : center_radiance;

    imageStore(rtgi_filtered_img, texel, vec4(filtered, 1.0));
}
