/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_filter.csh:
  SVGF Variance-Guided Edge-Avoiding À-Trous Wavelet Filter

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

// Two-pass à-trous (SEUS segment, T4): pass 1 runs at stride 2 on the
// temporal output and writes an intermediate; pass 2 runs at stride 1 on that
// result and writes the buffer deferred4 consumes. Wrappers select the pass.
#ifndef RTGI_FILTER_PASS
#define RTGI_FILTER_PASS 1
#endif

#if RTGI_FILTER_PASS == 1
layout(rgba16f) writeonly uniform image2D rtgi_filter_inter_img;
#else
layout(rgba16f) writeonly uniform image2D rtgi_filtered_img;
#endif

// Pass 2 radiance input (pass-1 output); declared for both passes.
uniform sampler2D rtgi_filter_inter_sampler;

uniform sampler2D rtgi_accum_sampler;
uniform sampler2D rtgi_history_sampler;
uniform sampler2D rtgi_sky_accum_sampler;
uniform sampler2D rtgi_sky_history_sampler;
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
#include "/include/utility/color.glsl"

vec4 sample_accum_data(ivec2 t, bool ping) {
    return ping ? texelFetch(rtgi_accum_sampler, t, 0)
                : texelFetch(rtgi_history_sampler, t, 0);
}

vec4 sample_aux_data(ivec2 t, bool ping) {
    return ping ? texelFetch(rtgi_sky_accum_sampler, t, 0)
                : texelFetch(rtgi_sky_history_sampler, t, 0);
}

// 1D cubic B-spline filter kernel weights: [1/16, 4/16, 6/16, 4/16, 1/16]
const float bspline_kernel[5] = float[5](
    0.0625, 0.25, 0.375, 0.25, 0.0625
);

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

    vec2 target_pixel_size = 1.0 / vec2(target_res);
    vec2 center_uv = (vec2(texel) + 0.5) * target_pixel_size;
    ivec2 active_res = max(ivec2(1), ivec2(vec2(target_res) * taau_render_scale));

    if (taau_uv_outside_viewport(center_uv)) {
        #if RTGI_FILTER_PASS == 1
        imageStore(rtgi_filter_inter_img, texel, vec4(0.0));
        #else
        imageStore(rtgi_filtered_img, texel, vec4(0.0));
        #endif
        return;
    }

    ivec2 center_full = ivec2(center_uv * view_res);

    float center_depth = texelFetch(depthtex1, center_full, 0).x;
    if (center_depth >= 1.0) {
        #if RTGI_FILTER_PASS == 1
        imageStore(rtgi_filter_inter_img, texel, vec4(0.0));
        #else
        imageStore(rtgi_filtered_img, texel, vec4(0.0));
        #endif
        return;
    }

    bool ping = (frameCounter & 1) == 0;

    vec3 center_screen_pos = vec3(taau_projection_uv(center_uv), center_depth);
    vec3 center_view_pos = screen_to_view_space(center_screen_pos, true);
    float center_dist = -center_view_pos.z;

    #if RTGI_FILTER_PASS == 2
    vec4 center_sample = texelFetch(rtgi_filter_inter_sampler, texel, 0);
    #else
    vec4 center_sample = sample_accum_data(texel, ping);
    #endif
    vec3 center_radiance = center_sample.rgb;

    vec4 center_aux = sample_aux_data(texel, ping);
    float center_m1 = dot(center_radiance, luminance_weights);
    float center_m2 = center_aux.r;
    float center_var = max(0.0, center_m2 - center_m1 * center_m1);
    float center_std = sqrt(center_var);

    vec3 center_world_normal = decode_unit_vector(center_aux.ba);
    vec3 center_view_normal = mat3(gbufferModelView) * center_world_normal;
    float center_sky_weight = clamp01(unpack_sky_age(center_aux.g).x);

    // SVGF edge-stopping parameter scaling
    // Variance-guided normal exponent: tight (128) when converged, wide (8) when noisy
    float var_normalized = clamp01(center_std / (center_m1 + 0.02));
    float sigma_n = mix(128.0, 8.0, var_normalized);

    // Depth tolerance: 5% of metric distance. Pass 1 covers the field at
    // stride 2; pass 2 refines at stride 1 (standard SVGF pyramid; SEUS runs
    // the same idea eight times with variance-scaled steps).
    #if RTGI_FILTER_PASS == 1
    const int step_size = 2;
    #else
    const int step_size = 1;
    #endif
    float sigma_z = max(center_dist * 0.05, 0.10) * float(step_size);

    // Luminance tolerance: scaled by measured standard deviation, clamped to avoid smearing outliers into dark regions
    float sigma_l = clamp(4.0 * center_std + 0.005, 0.01, max(center_m1 * 1.0 + 0.05, 0.35));

    vec3 sum_radiance = vec3(0.0);
    float sum_sky_weight = 0.0;
    float sum_weights = 0.0;

    for (int dy = -2; dy <= 2; ++dy) {
        float wy = bspline_kernel[dy + 2];

        for (int dx = -2; dx <= 2; ++dx) {
            float wx = bspline_kernel[dx + 2];
            float weight_spatial = wx * wy;

            ivec2 neighbor_texel = clamp(texel + ivec2(dx, dy) * step_size, ivec2(0), active_res - 1);
            vec2 n_uv = (vec2(neighbor_texel) + 0.5) * target_pixel_size;

            if (taau_uv_outside_viewport(n_uv)) {
                continue;
            }

            ivec2 neighbor_full = ivec2(n_uv * view_res);

            float n_depth = texelFetch(depthtex1, neighbor_full, 0).x;
            vec3 n_view_pos = screen_to_view_space(
                vec3(taau_projection_uv(n_uv), n_depth), true
            );

            #if RTGI_FILTER_PASS == 2
            vec4 n_sample = texelFetch(rtgi_filter_inter_sampler, neighbor_texel, 0);
            #else
            vec4 n_sample = sample_accum_data(neighbor_texel, ping);
            #endif
            vec3 n_color = n_sample.rgb;

            vec4 n_aux = sample_aux_data(neighbor_texel, ping);
            float n_m1 = dot(n_color, luminance_weights);
            vec3 n_world_normal = decode_unit_vector(n_aux.ba);
            float n_sky_weight = clamp01(unpack_sky_age(n_aux.g).x);

            // 1. Tangent-plane depth weight: zero on flat surfaces regardless of view angle
            vec3 pos_diff = n_view_pos - center_view_pos;
            float plane_signed = dot(pos_diff, center_view_normal);
            float plane_dist = abs(plane_signed);
            float weight_depth = exp(-plane_dist / sigma_z);

            // 2. Variance-guided normal weight
            float normal_dot = max(0.0, dot(center_world_normal, n_world_normal));

            // 4. Anti-bleed rule (SEUS PathTraceDenoiser concept, section 6
            // item 4): a tap that sits BEHIND the centre's tangent plane,
            // faces back toward the centre, and is DARKER than the centre
            // bypasses the normal penalty and gets a bounded boost instead —
            // dark occluded geometry keeps its value at corners and edges, so
            // bright regions cannot smear across them. The boost only applies
            // once the signal has converged (variance-driven, like SEUS's
            // 4/variance) and fades out on noisy pixels.
            vec3 n_view_normal = mat3(gbufferModelView) * n_world_normal;
            bool darker_behind = plane_signed < -0.05
                && n_m1 < center_m1
                && dot(-pos_diff, n_view_normal) > 0.0;
            float weight_normal = darker_behind
                ? mix(4.0, 1.0, var_normalized)
                : pow(normal_dot, sigma_n);

            // 3. Variance-guided luminance weight (preserves high-confidence indirect contrast)
            float luma_diff = abs(n_m1 - center_m1);
            float weight_luma = exp(-luma_diff / sigma_l);

            float weight = weight_spatial * weight_depth * weight_normal * weight_luma;

            sum_radiance += n_color * weight;
            sum_sky_weight += n_sky_weight * weight;
            sum_weights += weight;
        }
    }

    vec3 filtered = (sum_weights > 1e-4) ? (sum_radiance / sum_weights) : center_radiance;
    float filtered_sky = (sum_weights > 1e-4) ? (sum_sky_weight / sum_weights) : center_sky_weight;

    #if RTGI_FILTER_PASS == 1
    imageStore(rtgi_filter_inter_img, texel, vec4(filtered, clamp01(filtered_sky)));
    #else
    imageStore(rtgi_filtered_img, texel, vec4(filtered, clamp01(filtered_sky)));
    #endif
}
