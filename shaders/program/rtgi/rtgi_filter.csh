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

// Four-pass à-trous pyramid in SVGF order (narrow to wide), mirroring the
// 1-2-4-8 ladder of the educational Minecraft-PTGI pack:
//   pass 1: stride 1, temporal output -> inter
//   pass 2: stride 2, inter          -> filtered
//   pass 3: stride 4, filtered       -> inter
//   pass 4: stride 8, inter          -> filtered (consumed by deferred4)
// The previous two-pass (2, 1) chain had an effective radius of ~4 texels —
// far too small to dissolve emitter confetti into a light field. Wrappers
// (deferred3_a..d) select the pass.
#ifndef RTGI_FILTER_PASS
#define RTGI_FILTER_PASS 1
#endif

#if RTGI_FILTER_PASS == 1 || RTGI_FILTER_PASS == 3
layout(rgba16f) writeonly uniform image2D rtgi_filter_inter_img;
#else
layout(rgba16f) writeonly uniform image2D rtgi_filtered_img;
#endif

// Pass-2/4 radiance input (intermediate) and pass-3 radiance input (previous
// filtered output). Declared unconditionally; unused ones are pruned.
uniform sampler2D rtgi_filter_inter_sampler;
uniform sampler2D rtgi_filtered_sampler;

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

// Luminance edge-stopping constant (educational Minecraft-PTGI: 10.0).
// phi_l = PHI_COLOUR * sqrt(variance), capped by a fixed ceiling at the
// use site. Two past regressions bracket the design: the brightness-scaled
// clamp max(center_m1 + 0.05, 0.35) made phi track the center's own
// brightness, so any outlier differing by more than the center's luminance
// was rejected and the filter became a pass-through exactly where denoising
// was needed; a fully UNCAPPED phi instead erased edge stopping during
// variance spikes and bloomed bright blocks. The fixed ceiling keeps
// confetti smoothing while restoring hard-edge stopping.
// Value exposed as RTGI_FILTER_PHI in settings.glsl (test knob).
#define PHI_COLOUR RTGI_FILTER_PHI

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
        #if RTGI_FILTER_PASS == 1 || RTGI_FILTER_PASS == 3
        imageStore(rtgi_filter_inter_img, texel, vec4(0.0));
        #else
        imageStore(rtgi_filtered_img, texel, vec4(0.0));
        #endif
        return;
    }

    ivec2 center_full = ivec2(center_uv * view_res);

    float center_depth = texelFetch(depthtex1, center_full, 0).x;
    if (center_depth >= 1.0) {
        #if RTGI_FILTER_PASS == 1 || RTGI_FILTER_PASS == 3
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

    #if RTGI_FILTER_PASS == 1
    vec4 center_sample = sample_accum_data(texel, ping);
    #elif RTGI_FILTER_PASS == 3
    vec4 center_sample = texelFetch(rtgi_filtered_sampler, texel, 0);
    #else
    vec4 center_sample = texelFetch(rtgi_filter_inter_sampler, texel, 0);
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

    // Pass strides: 1 -> 2 -> 4 -> 8 (narrow to wide). The depth tolerance
    // scales with the stride so a wide pass does not leak across surfaces
    // that are still distinct at that spacing.
    #if RTGI_FILTER_PASS == 1
    const int step_size = 1;
    #elif RTGI_FILTER_PASS == 2
    const int step_size = 2;
    #elif RTGI_FILTER_PASS == 3
    const int step_size = 4;
    #else
    const int step_size = 8;
    #endif
    float sigma_z = max(center_dist * 0.05, 0.10) * float(step_size);

    // Luminance tolerance: variance-guided, with a fixed ceiling. The old
    // brightness-scaled clamp is still rejected (it made phi track the
    // center's own luminance and killed exactly the smoothing confetti
    // dots needed), but a pure UNCAPPED phi lets variance spikes — camera
    // motion, fresh history, emitter contrast — blow sigma_l up until every
    // weight_luma ~ 1, and the à-trous kernel then paints a symmetric
    // square bloom around bright blocks (spreads equally outward and
    // inward; the footprint scales with the BUFFER texel size, so it
    // halves at RTGI_RESOLUTION full and doubles at half — the reported
    // behaviour). Ceiling 1.0: a bright-block edge of a few radiance units
    // dies as exp(-(dL/1)^2), while same-surface noise (dL ~ 1.4*sigma_n)
    // still passes when PHI*sqrt(var) sits at the floor.
    float sigma_l = min(PHI_COLOUR * sqrt(center_var + 1e-6), 1.0);

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

            #if RTGI_FILTER_PASS == 1
            vec4 n_sample = sample_accum_data(neighbor_texel, ping);
            #elif RTGI_FILTER_PASS == 3
            vec4 n_sample = texelFetch(rtgi_filtered_sampler, neighbor_texel, 0);
            #else
            vec4 n_sample = texelFetch(rtgi_filter_inter_sampler, neighbor_texel, 0);
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

            // 3. Variance-guided luminance weight. Gaussian form instead of
            // exp(-d/sigma): same noise throughput (pairwise noise diff ~1.4
            // sigma_noise, sigma_l = PHI*sqrt(var) ~ 2x that) but the tail
            // dies as exp(-(d/sigma)^2), so strong edges — bright window /
            // emitter blocks against dark rooms — are stopped hard while
            // same-surface noise still merges. The exponential form needed
            // sigma_l far below the noise floor to stop an edge, which is
            // exactly the static symmetric bloom (inside darkens, outside
            // brightens) reported around bright blocks.
            float luma_diff = abs(n_m1 - center_m1);
            float weight_luma = exp(-(luma_diff * luma_diff) / max(sigma_l * sigma_l, 1e-8));

            float weight = weight_spatial * weight_depth * weight_normal * weight_luma;

            sum_radiance += n_color * weight;
            sum_sky_weight += n_sky_weight * weight;
            sum_weights += weight;
        }
    }

    vec3 filtered = (sum_weights > 1e-4) ? (sum_radiance / sum_weights) : center_radiance;
    float filtered_sky = (sum_weights > 1e-4) ? (sum_sky_weight / sum_weights) : center_sky_weight;

    #if RTGI_FILTER_PASS == 1 || RTGI_FILTER_PASS == 3
    imageStore(rtgi_filter_inter_img, texel, vec4(filtered, clamp01(filtered_sky)));
    #else
    imageStore(rtgi_filtered_img, texel, vec4(filtered, clamp01(filtered_sky)));
    #endif
}
