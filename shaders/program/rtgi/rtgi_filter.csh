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
uniform sampler2D depthtex1;
uniform sampler2D colortex1; // gbuffer0

uniform mat4 gbufferModelView;
uniform mat4 gbufferProjectionInverse;

uniform vec2 view_res;
uniform vec2 view_pixel_size;

uniform float near;
uniform float far;
uniform vec2 taa_offset;

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
    float center_depth = texelFetch(depthtex1, full_texel, 0).x;
    if (center_depth >= 1.0) {
        imageStore(rtgi_filtered_img, texel, vec4(0.0));
        return;
    }

    vec4 center_gbuf = texelFetch(colortex1, full_texel, 0);
    vec3 center_normal = decode_unit_vector(unpack_unorm_2x8(center_gbuf.z));
    vec4 center_radiance = texelFetch(rtgi_accum_sampler, texel, 0);

    // 5x5 separable cross-bilateral kernel
    const ivec2 offsets[9] = ivec2[9](
        ivec2( 0,  0),
        ivec2(-1,  0), ivec2( 1,  0),
        ivec2( 0, -1), ivec2( 0,  1),
        ivec2(-2,  0), ivec2( 2,  0),
        ivec2( 0, -2), ivec2( 0,  2)
    );

    const float spatial_weights[9] = float[9](
        0.30,
        0.15, 0.15,
        0.15, 0.15,
        0.025, 0.025,
        0.025, 0.025
    );

    vec3 sum_radiance = vec3(0.0);
    float sum_weights = 0.0;

    for (int i = 0; i < 9; ++i) {
        ivec2 neighbor_texel = clamp(texel + offsets[i], ivec2(0), target_res - 1);
        ivec2 neighbor_full = ivec2(vec2(neighbor_texel) / render_scale);

        float n_depth = texelFetch(depthtex1, neighbor_full, 0).x;
        vec4 n_gbuf = texelFetch(colortex1, neighbor_full, 0);
        vec3 n_normal = decode_unit_vector(unpack_unorm_2x8(n_gbuf.z));
        vec3 n_color = texelFetch(rtgi_accum_sampler, neighbor_texel, 0).rgb;

        // Bilateral weights
        float depth_diff = abs(center_depth - n_depth) / (max(center_depth, 1e-4) * 0.02 + 1e-4);
        float weight_depth = exp(-depth_diff * depth_diff);

        float normal_diff = max(0.0, dot(center_normal, n_normal));
        float weight_normal = normal_diff * normal_diff * normal_diff * normal_diff;

        float weight = spatial_weights[i] * weight_depth * weight_normal;

        sum_radiance += n_color * weight;
        sum_weights += weight;
    }

    vec3 filtered = (sum_weights > 1e-5) ? (sum_radiance / sum_weights) : center_radiance.rgb;

    imageStore(rtgi_filtered_img, texel, vec4(filtered, 1.0));
}
