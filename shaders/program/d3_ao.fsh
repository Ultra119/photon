/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/d3_ao:
  Calculate ambient occlusion (RTGI pass-through)

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

uniform vec2 view_res;

// ------------
//   Includes
// ------------

#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"

const float ao_render_scale = 0.5;

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

    // With Ray Traced GI enabled, RTGI diffuse rays and 3D voxel traversal
    // naturally provide 100% physically based ambient occlusion and cavity darkening.
    ambient = vec4(1.0, 0.0, view_normal.xy * 0.5 + 0.5);
    ambient_history_data = vec2(1.0 - depth, 1.0);
}
