/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/d3_ao:
  Calculate screen-space contact AO for RTGI

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(location = 0) out vec4 ambient; // ao, ambient SSS, octahedrally encoded bent normal
layout(location = 1) out vec2 ambient_history_data; // depth, pixel age

/* RENDERTARGETS: 6,14 */

in vec2 uv;

// ------------
//   Uniforms
// ------------

uniform sampler2D colortex1; // gbuffer 0
uniform sampler2D colortex2; // gbuffer 1

uniform sampler2D depthtex1;

uniform mat4 gbufferModelView;
uniform mat4 gbufferProjectionInverse;

uniform vec2 view_res;
uniform vec2 taa_offset;

// ------------
//   Includes
// ------------

#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"

const float ao_render_scale = 0.5;

// Reconstruct a view-space position from a full-resolution depth texel. This
// is a compact version of screen_to_view_space() without the extra include
// dependencies; it still removes TAA jitter and respects the TAAU viewport.
vec3 reconstruct_view_pos(ivec2 texel, float depth) {
    vec2 framebuffer_uv = (vec2(texel) + 0.5) / view_res;
    vec2 projection_uv = taau_projection_uv(framebuffer_uv);
    vec2 ndc = projection_uv * 2.0 - 1.0;

#ifdef TAA
#ifdef TAAU
    ndc -= taa_offset * rcp(taau_render_scale);
#else
    ndc -= taa_offset * 0.66;
#endif
#endif

    return project_and_divide(
        gbufferProjectionInverse,
        vec3(ndc, depth * 2.0 - 1.0)
    );
}

// Mild 8-tap horizon/contact AO. It only sees near geometry; RTGI remains
// responsible for large-scale occlusion and indirect lighting.
float compute_contact_ao(ivec2 texel, float depth, vec3 view_normal) {
#if defined RAYTRACED_GI
    if (RTGI_CONTACT_AO_STRENGTH <= 0.0) {
        return 1.0;
    }

    vec3 center_pos = reconstruct_view_pos(texel, depth);
    ivec2 active_res = max(ivec2(1), ivec2(view_res * taau_render_scale));

    const ivec2 offsets[8] = ivec2[8](
        ivec2( 1,  0), ivec2(-1,  0),
        ivec2( 0,  1), ivec2( 0, -1),
        ivec2( 2,  0), ivec2(-2,  0),
        ivec2( 0,  2), ivec2( 0, -2)
    );

    float occlusion = 0.0;

    for (int i = 0; i < 8; ++i) {
        ivec2 sample_texel = clamp(
            texel + offsets[i] * 2,
            ivec2(0),
            active_res - 1
        );

        float sample_depth = texelFetch(combined_depth_tex, sample_texel, 0).x;
        if (sample_depth >= 1.0) {
            continue;
        }

        vec3 sample_pos = reconstruct_view_pos(sample_texel, sample_depth);
        vec3 delta = sample_pos - center_pos;
        float dist = length(delta);
        float NoD = dot(view_normal, delta / max(dist, eps));

        // Ignore nearly coplanar samples and distant geometry.
        occlusion += max(0.0, NoD - 0.10) * exp(-dist * 0.35);
    }

    return clamp01(1.0 - RTGI_CONTACT_AO_STRENGTH * occlusion * 0.125);
#else
    return 1.0;
#endif
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 view_texel = ivec2(gl_FragCoord.xy * (taau_render_scale / ao_render_scale));

    if (clamp(view_texel, ivec2(0), ivec2(view_res)) != view_texel) {
        return;
    }

    float depth = texelFetch(combined_depth_tex, view_texel, 0).x;

    if (depth == 1.0) {
        ambient = vec4(1.0, 0.0, 0.5, 0.5);
        ambient_history_data = vec2(0.0);
        return;
    }

#ifndef NORMAL_MAPPING
    vec4 gbuffer_data = texelFetch(colortex1, view_texel, 0);
#else
    vec4 gbuffer_data = texelFetch(colortex2, view_texel, 0);
#endif

    // Distant Horizons support
#ifdef LOD_MOD_ACTIVE
    float depth_mc = texelFetch(depthtex1, view_texel, 0).x;
    float depth_lod = texelFetch(lod_depth_tex_shading, view_texel, 0).x;
    bool is_lod = is_lod_terrain(depth_mc, depth_lod);
#else
    const bool is_lod = false;
#endif

#ifdef NORMAL_MAPPING
    vec3 world_normal = decode_unit_vector(gbuffer_data.xy);

#ifdef LOD_MOD_ACTIVE
    if (is_lod) {
        vec4 gbuffer_data_0 = texelFetch(colortex1, view_texel, 0);
        world_normal = decode_unit_vector(unpack_unorm_2x8(gbuffer_data_0.z));
    }
#endif
#else
    vec3 world_normal = decode_unit_vector(unpack_unorm_2x8(gbuffer_data.z));
#endif

    vec3 view_normal = mat3(gbufferModelView) * world_normal;
    float ao = compute_contact_ao(view_texel, depth, view_normal);

    ambient = vec4(ao, 0.0, view_normal.xy * 0.5 + 0.5);
    ambient_history_data = vec2(1.0 - depth, 1.0);
}
