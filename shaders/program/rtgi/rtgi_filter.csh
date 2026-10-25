/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_filter.csh:
  Edge-aware cross-bilateral spatial filter for noise-free indirect radiance

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

    vec4 center_gbuf = texelFetch(colortex1, full_texel, 0);
    vec3 center_normal = decode_unit_vector(unpack_unorm_2x8(center_gbuf.z));
    vec4 center_radiance = sample_accum_data(texel, ping);
    float center_lin_depth = linearize_depth(center_depth, near, far);

    // 13-tap cross + diagonal bilateral filter kernel
    const ivec2 offsets[13] = ivec2[13](
        ivec2( 0,  0),
        ivec2(-1,  0), ivec2( 1,  0),
        ivec2( 0, -1), ivec2( 0,  1),
        ivec2(-1, -1), ivec2( 1, -1),
        ivec2(-1,  1), ivec2( 1,  1),
        ivec2(-2,  0), ivec2( 2,  0),
        ivec2( 0, -2), ivec2( 0,  2)
    );

    const float spatial_weights[13] = float[13](
        0.24,
        0.12, 0.12,
        0.12, 0.12,
        0.06, 0.06,
        0.06, 0.06,
        0.02, 0.02,
        0.02, 0.02
    );

    vec3 sum_radiance = vec3(0.0);
    float sum_weights = 0.0;

    for (int i = 0; i < 13; ++i) {
        ivec2 neighbor_texel = clamp(texel + offsets[i], ivec2(0), target_res - 1);
        ivec2 neighbor_full = ivec2(vec2(neighbor_texel) / render_scale);

        float n_depth = texelFetch(depthtex1, neighbor_full, 0).x;
        vec4 n_gbuf = texelFetch(colortex1, neighbor_full, 0);
        vec3 n_normal = decode_unit_vector(unpack_unorm_2x8(n_gbuf.z));
        vec3 n_color = sample_accum_data(neighbor_texel, ping).rgb;

        // Metric depth bilateral weight (0.30 tolerance ensures flat surfaces and gentle slopes filter smoothly)
        float n_lin_depth = linearize_depth(n_depth, near, far);
        float depth_diff = abs(center_lin_depth - n_lin_depth) / (max(center_lin_depth, 0.5) * 0.30);
        float weight_depth = exp(-depth_diff * depth_diff);

        // Normal bilateral weight (quadratic falloff preserves sharp geometric edges while filtering micro-variations)
        float normal_diff = max(0.0, dot(center_normal, n_normal));
        float weight_normal = normal_diff * normal_diff;

        float weight = spatial_weights[i] * weight_depth * weight_normal;

        sum_radiance += n_color * weight;
        sum_weights += weight;
    }

    vec3 filtered = (sum_weights > 1e-5) ? (sum_radiance / sum_weights) : center_radiance.rgb;

    imageStore(rtgi_filtered_img, texel, vec4(filtered, 1.0));
}
