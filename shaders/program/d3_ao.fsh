/*
--------------------------------------------------------------------------------

  Photon Shader: RT Mode

  program/d3_ao:
  Short voxel-ray contact occlusion for direct lighting

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(
    location = 0
) out vec4 ambient; // R: contact visibility, G: reserved zero, BA: reserved neutral
layout(location = 1) out vec2 ambient_history_data; // depth, pixel age

/* RENDERTARGETS: 6,14 */

in vec2 uv;

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;

uniform sampler2D colortex1; // gbuffer 0
uniform sampler2D colortex6; // ambient lighting data
uniform sampler2D colortex14; // ambient lighting history data

uniform sampler2D depthtex1;
uniform usampler3D voxel_sampler;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

uniform float near;
uniform float far;
uniform float eyeAltitude;

uniform int frameCounter;

uniform vec3 light_dir;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;
uniform vec2 clouds_offset;

uniform bool world_age_changed;

// ------------
//   Includes
// ------------

#define TEMPORAL_REPROJECTION
#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/bicubic.glsl"
#include "/include/utility/dithering.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/space_conversion.glsl"

#include "/include/lighting/rt/rt_ao.glsl"

const float ao_render_scale = 0.5;

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 view_texel
        = ivec2(gl_FragCoord.xy * (taau_render_scale / ao_render_scale));

    if (clamp(view_texel, ivec2(0), ivec2(view_res)) != view_texel) {
        return;
    }

    float depth = texelFetch(combined_depth_tex, view_texel, 0).x;

    vec4 gbuffer_data = texelFetch(colortex1, view_texel, 0);
    vec2 dither = vec2(
        texelFetch(noisetex, texel & 511, 0).b,
        texelFetch(noisetex, (texel + 249) & 511, 0).b
    );

    // Distant Horizons support

#ifdef LOD_MOD_ACTIVE
    float depth_mc = texelFetch(depthtex1, view_texel, 0).x;
#else
#define depth_mc depth
#endif

    bool is_hand;
    fix_hand_depth(depth_mc, is_hand);

    vec3 screen_pos = vec3(uv, depth);
    vec3 view_pos = screen_to_view_space(
        combined_projection_matrix_inverse,
        screen_pos,
        true
    );
    vec3 scene_pos = view_to_scene_space(view_pos);

    vec3 previous_screen_pos = reproject_scene_space(scene_pos, false, false);

    if (depth == 1.0) {
        ambient = vec4(1.0, 0.0, 0.0, 0.0);
        ambient_history_data = vec2(0.0);
        return;
    }

    // Contact rays use geometric visibility. Normal-map detail must not
    // redirect rays below the raster surface or into its own voxel cell.
    vec3 world_normal = decode_unit_vector(unpack_unorm_2x8(gbuffer_data.z));
    vec3 view_normal = mat3(gbufferModelView) * world_normal;

    dither = r2(frameCounter, dither);

    // The hand is not in world-space voxel coordinates. Uncovered/LOD
    // surfaces likewise remain neutral when their rays leave the volume.
    if (is_hand || RT_AO_STRENGTH <= 0.0) {
        ambient = vec4(1.0, 0.0, 0.5, 0.5);
        ambient_history_data = vec2(1.0 - depth, 0.0);
        return;
    }

    float ao = compute_rt_ao(scene_pos, world_normal, dither, voxel_sampler);
    // G is reserved for ambient SSS compatibility; RT AO does not invent an
    // analytic ambient-SSS term or a bent-normal lighting substitute.
    vec2 ao_sample = vec2(ao, 0.0);

    // Temporal accumulation

    const float max_accumulated_frames = 10.0;
    const float depth_rejection_strength = 16.0;
    const float offcenter_rejection_strength = 0.25;

    vec4 history = max0(
        catmull_rom_filter_fast(colortex6, previous_screen_pos.xy, 0.65)
    );
    vec2 history_data = max0(texture(colortex14, previous_screen_pos.xy).xy);

    if (clamp01(previous_screen_pos.xy) == previous_screen_pos.xy) {
        // Unpack history data
        float history_depth = 1.0 - history_data.x;
        float pixel_age = min(history_data.y, max_accumulated_frames);

        // Depth rejection
        float view_norm = rcp_length(view_pos);
        float NoV = abs(dot(view_normal, view_pos))
            * view_norm; // NoV / sqrt(length(view_pos))
        float z0 = screen_to_view_space_depth(
            combined_projection_matrix_inverse,
            depth
        );
        float z1 = screen_to_view_space_depth(
            combined_projection_matrix_inverse,
            history_depth
        );
        float depth_weight
            = exp2(-abs(z0 - z1) * depth_rejection_strength * NoV * view_norm);

        // Offcenter rejection from Jessie, which is originally by Zombye
        // Reduces blur in motion
        vec2 pixel_offset = 1.0
            - abs(2.0
                      * fract(
                          view_res * ao_render_scale * previous_screen_pos.xy
                      )
                  - 1.0);
        float offcenter_rejection = sqrt(pixel_offset.x * pixel_offset.y)
                * offcenter_rejection_strength
            + (1.0 - offcenter_rejection_strength);

        pixel_age
            *= depth_weight * offcenter_rejection * float(history_depth != 1.0);

        // Blend with history
        float history_weight = pixel_age / (pixel_age + 1.0);

        ao_sample = mix(ao_sample, history.xy, history_weight);
        ambient = vec4(ao_sample, 0.5, 0.5);
        ambient_history_data = vec2(1.0 - depth, pixel_age + 1.0);
    } else {
        ambient = vec4(ao_sample, 0.5, 0.5);
        ambient_history_data = vec2(0.0);
    }

}
