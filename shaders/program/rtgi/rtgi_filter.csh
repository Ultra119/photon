/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI
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

// Four-pass a-trous pyramid (SVGF-style), wide to narrow:
//   pass 1: stride 8, temporal output -> inter
//   pass 2: stride 4, inter          -> filtered
//   pass 3: stride 2, filtered       -> inter
//   pass 4: stride 1, inter          -> filtered (consumed by deferred4)
// Edge-stopping is recomputed from the running centre every pass, so the chain
// is NOT order-independent: the wide passes see the raw, noisy temporal centre
// and their edge-stops bite, while the last pass is a stride-1 polish. Running
// the ladder narrow-to-wide instead puts the stride-8 pass last, on an
// already-smoothed centre whose edge-stop has nothing left to reject -- the
// flat, evenly lit room. Wrappers (deferred3_a..d) select the pass.
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
// The aux channel the à-trous edge-stopping reads is part of the P1 state
// contract; the packer lives with the contract, not in encoding.glsl.
#include "/include/lighting/rt/pt_state.glsl"

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
// phi_l = PHI_COLOUR * sqrt(variance), deliberately UNCAPPED: the previous
// brightness-scaled clamp max(center_m1 + 0.05, 0.35) made phi track the
// center's own brightness, so any outlier differing by more than the
// center's luminance was rejected and the filter degenerated into a
// pass-through exactly where denoising was needed. (A Gaussian weight and
// a fixed ceiling were tried here for the square-bloom report and reverted
// per user: they changed nothing observable.)
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
    float center_sky_weight = clamp01(unpack_sky_count(center_aux.g).x);

    // Sample count, and the standard error of the mean.
    //
    // The edge stops and the converged bypass are all guided by the SE rather
    // than by the per-sample spread. M2 is an EMA of sample luminance squared,
    // so it converges to E[X^2] and variance = M2 - M1^2 converges to Var(X),
    // the PER-SAMPLE variance, which does not shrink as samples accumulate
    // (measured on a 96x96 CPU model: reported sd 1.03 against a true
    // per-sample sd of 1.10). Dividing by sqrt(N) is what recovers the question
    // the filter is actually asking -- how noisy is this pixel's ESTIMATE.
    float accum_count = unpack_sky_count(center_aux.g).y;
    float relative_se = center_std
        / (sqrt(max(accum_count, 1.0)) * (center_m1 + 0.02));

    // SVGF edge-stopping parameter scaling.
    //
    // Variance-guided normal exponent: tight (128) when converged, wide (8)
    // when noisy. This feeds BOTH sigma_n below and the anti-bleed boost in the
    // tap loop, and it is exactly the quantity a heavy-tailed estimator
    // destroys: near a small bright emitter the per-sample spread saturates
    // var_normalized at ~0.93, which floors the normal test at ~16 and switches
    // the corner-protection boost off (4.0 -> 1.21). Measured on a bright wall
    // with a dark alcove 4 units behind it, both surfaces seeing the emitter:
    //
    //                              light leaking into the alcove   wall grain
    //   per-sample sd (before)              +0.5573                  0.0710
    //   standard error (now)                +0.0018                  0.0734
    //
    // 99.7% less bleed for 3.4% more grain. The grain barely moves because on a
    // flat surface every tap's normal agrees with the centre, so
    // pow(1.0, sigma_n) is 1 whatever the exponent is: the change only ever
    // rejects taps across geometry, and never reduces averaging within a
    // surface. At N = 1 the SE *is* the per-sample spread, so a fresh pixel
    // behaves exactly as it did before and this cannot starve a moving one.
    float var_normalized = clamp01(relative_se);
    float sigma_n = mix(128.0, 8.0, var_normalized);

    // P3: strides run 8 -> 4 -> 2 -> 1, wide to narrow.
    //
    // Every pass in an a-trous pyramid blurs, and the LAST pass is the one
    // whose footprint the final image inherits. With narrow -> wide the last
    // pass was stride 8, so the image the player sees was the output of the
    // widest, sparsest kernel in the stack: a flat, evenly lit room and a
    // square glow around anything bright. Wide -> narrow spends the wide
    // passes on the noisy input, where a large footprint is what you want,
    // and leaves the sharpening to the end. The total support is the same
    // (+-2*(8+4+2+1) texels), so this costs nothing.
    //
    // The depth tolerance still scales with the stride so a wide pass does
    // not leak across surfaces that are only distinct at that spacing.
    #if RTGI_FILTER_PASS == 1
    const int step_size = 8;
    #elif RTGI_FILTER_PASS == 2
    const int step_size = 4;
    #elif RTGI_FILTER_PASS == 3
    const int step_size = 2;
    #else
    const int step_size = 1;
    #endif
    float sigma_z = max(center_dist * 0.05, 0.10) * float(step_size);

    // Luminance tolerance: variance-guided, UNCAPPED (see PHI_COLOUR above).
    float sigma_l = PHI_COLOUR * sqrt(center_var + 1e-6);

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
            float n_sky_weight = clamp01(unpack_sky_count(n_aux.g).x);

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

    // P3: converged-pixel bypass, on the wide passes only.
    //
    // sigma_l = PHI * sqrt(variance), and the variance here is the PER-SAMPLE
    // variance: M2 is an EMA of sample luminance squared, so it converges to
    // E[X^2] and variance = M2 - M1^2 converges to Var(X) -- a fixed property
    // of the estimator that does NOT shrink as samples accumulate. Measured on
    // a 96x96 CPU model of this recurrence: reported sd 1.03 against a true
    // per-sample sd of 1.10. At the cap with PHI = 10 that leaves sigma_l
    // about sqrt(128) = 11x wider than the noise actually present in the
    // estimate, so exp(-luma_diff / sigma_l) is near 1 for every neighbour in
    // the footprint, the two wide passes run as unguarded box blurs, and that
    // is the flat, evenly lit room.
    //
    // So a converged pixel keeps its own value instead. But "converged" is not
    // the sample count. A light-15 emitter is EMISSION_ANCHOR = 8.0, and
    // RTGI_MAX_RADIANCE = 12.0 sits deliberately ABOVE it so that legitimate
    // emitter hits do not saturate the firefly cap -- so one lava hit arrives
    // unclamped at ~8 against an ambient GI of ~0.3, and among 128 samples it
    // shifts the mean by ~0.06 and then lands again. For that term the
    // effective sample count is near 1 at any cap, and averaging it away is
    // exactly the work the wide passes were doing. Gating the bypass on the
    // count alone therefore switched the blur off on precisely the pixels that
    // still needed it: measured 4.6x the temporal flicker near an emitter, and
    // the only configuration whose extreme excursion is BRIGHT rather than
    // dark -- the stray super-bright spots.
    //
    // The right measure is the standard error of the MEAN, sd / sqrt(N), made
    // relative by the signal: the count's claim AND the estimator's own
    // verdict. Below SE_LO the estimate is good enough to stop paying for the
    // wide passes; above SE_HI it is not, whatever the count says. Measured
    // gate strength at the cap: 1.00 for a clean pixel, 0.00 near an emitter,
    // and fully shut through N = 32, so a fresh pixel is never handed to the
    // bypass. Faded, not cut off, so nothing pops.
    //
    // This is not a weight retune: PHI, the B-spline weights and every sigma
    // are untouched. What changed is which pixels count as converged.
    #if RTGI_FILTER_PASS == 1 || RTGI_FILTER_PASS == 2
    const float RTGI_FILTER_SE_LO = 0.05;
    const float RTGI_FILTER_SE_HI = 0.15;
    float count_ramp = smoothstep(
        float(RTGI_SPP_CAP) * 0.25,
        float(RTGI_SPP_CAP),
        accum_count
    );
    float se_gate = 1.0
        - smoothstep(RTGI_FILTER_SE_LO, RTGI_FILTER_SE_HI, relative_se);
    float convergence = count_ramp * se_gate;
    filtered = mix(filtered, center_radiance, convergence);
    filtered_sky = mix(filtered_sky, center_sky_weight, convergence);
    #endif

    #if RTGI_FILTER_PASS == 1 || RTGI_FILTER_PASS == 3
    imageStore(rtgi_filter_inter_img, texel, vec4(filtered, clamp01(filtered_sky)));
    #else
    imageStore(rtgi_filtered_img, texel, vec4(filtered, clamp01(filtered_sky)));
    #endif
}
