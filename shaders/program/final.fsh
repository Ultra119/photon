/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/program/final.glsl:
  CAS, dithering, debug views

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(location = 0) out vec3 fragment_color;

in vec2 uv;

// ------------
//   Uniforms
// ------------

uniform sampler2D colortex0; // Scene color

#if DEBUG_VIEW == DEBUG_VIEW_SAMPLER
uniform sampler2D DEBUG_SAMPLER;
#endif

uniform float viewHeight;
uniform float frameTimeCounter;

#if LIGHTING_MODE == LIGHTING_MODE_RT && (defined WORLD_NETHER || !defined SHADOW)
uniform sampler2D shadowtex0;
#endif

#include "/include/utility/bicubic.glsl"
#include "/include/utility/color.glsl"
#include "/include/utility/dithering.glsl"
#include "/include/utility/text_rendering.glsl"

#ifdef DISTANCE_VIEW
uniform sampler2D depthtex0;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec2 view_res;
uniform vec2 taa_offset;

uniform float near;
uniform float far;

#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/space_conversion.glsl"
#endif

#if DEBUG_VIEW == DEBUG_VIEW_GI
// space_conversion.glsl refers to its uniforms inside function bodies, so every
// one of them must be declared even for functions this view never calls, and a
// uniform may only be declared once in a translation unit. The DISTANCE_VIEW
// block above declares exactly this set, so mirror it under the opposite
// condition rather than duplicating it.
#ifndef DISTANCE_VIEW
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec2 view_res;
uniform vec2 taa_offset;

uniform float near;
uniform float far;
#endif

uniform vec3 cameraPosition;
uniform int frameCounter;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;

#include "/include/utility/space_conversion.glsl"

// The RTGI images and voxel scene are only declared in shaders.properties
// under RT Mode (every view here except the voxel ones needs the radiance
// buffers), so the whole debug path is gated on the same condition. Without it
// the view renders a flat magenta rather than sampling an unbound sampler.
#if LIGHTING_MODE == LIGHTING_MODE_RT
uniform usampler3D voxel_sampler;
#if GI_DEBUG == GI_DEBUG_COVERAGE
uniform usampler3D voxel_mid_sampler;
uniform usampler3D voxel_coarse_sampler;
#endif

uniform sampler2D rtgi_raw_sampler;
uniform sampler2D rtgi_history_sampler;
uniform sampler2D rtgi_accum_sampler;
uniform sampler2D rtgi_filtered_sampler;
#if GI_DEBUG == GI_DEBUG_HIT
uniform sampler2D rtgi_hit_sampler;
#endif
#if GI_DEBUG == GI_DEBUG_REJECT
uniform sampler2D rtgi_reject_sampler;
#endif
#if GI_DEBUG == GI_DEBUG_VARIANCE
uniform sampler2D rtgi_sky_accum_sampler;
uniform sampler2D rtgi_sky_history_sampler;
#endif

#include "/include/debug/gi_debug.glsl"
#endif
#endif

const int debug_text_scale = 2;
ivec2 debug_text_position = ivec2(0, int(viewHeight) / debug_text_scale);

#if DEBUG_VIEW == DEBUG_VIEW_WEATHER
#include "/include/misc/debug_weather.glsl"
#endif

vec3 min_of(vec3 a, vec3 b, vec3 c, vec3 d, vec3 f) {
    return min(a, min(b, min(c, min(d, f))));
}

vec3 max_of(vec3 a, vec3 b, vec3 c, vec3 d, vec3 f) {
    return max(a, max(b, max(c, max(d, f))));
}

// FidelityFX contrast-adaptive sharpening filter
// https://github.com/GPUOpen-Effects/FidelityFX-CAS
vec3 cas_filter(sampler2D sampler, ivec2 texel, const float sharpness) {
#ifndef CAS
    return display_eotf(texelFetch(sampler, texel, 0).rgb);
#endif

    // Fetch 3x3 neighborhood
    // a b c
    // d e f
    // g h i
    vec3 a = texelFetch(sampler, texel + ivec2(-1, -1), 0).rgb;
    vec3 b = texelFetch(sampler, texel + ivec2(0, -1), 0).rgb;
    vec3 c = texelFetch(sampler, texel + ivec2(1, -1), 0).rgb;
    vec3 d = texelFetch(sampler, texel + ivec2(-1, 0), 0).rgb;
    vec3 e = texelFetch(sampler, texel, 0).rgb;
    vec3 f = texelFetch(sampler, texel + ivec2(1, 0), 0).rgb;
    vec3 g = texelFetch(sampler, texel + ivec2(-1, 1), 0).rgb;
    vec3 h = texelFetch(sampler, texel + ivec2(0, 1), 0).rgb;
    vec3 i = texelFetch(sampler, texel + ivec2(1, 1), 0).rgb;

    // Convert to sRGB before performing CAS
    a = display_eotf(a);
    b = display_eotf(b);
    c = display_eotf(c);
    d = display_eotf(d);
    e = display_eotf(e);
    f = display_eotf(f);
    g = display_eotf(g);
    h = display_eotf(h);
    i = display_eotf(i);

    // Soft min and max. These are 2x bigger (factored out the extra multiply)
    vec3 min_color = min_of(d, e, f, b, h);
    min_color += min_of(min_color, a, c, g, i);

    vec3 max_color = max_of(d, e, f, b, h);
    max_color += max_of(max_color, a, c, g, i);

    // Smooth minimum distance to the signal limit divided by smooth max
    vec3 w = clamp01(min(min_color, 2.0 - max_color) / max_color);
    w = 1.0 - sqr(1.0 - w); // Shaping amount of sharpening
    w *= -1.0 / mix(8.0, 5.0, sharpness);

    // Filter shape:
    // 0 w 0
    // w 1 w
    // 0 w 0
    vec3 weight_sum = 1.0 + 4.0 * w;
    return clamp01((b + d + f + h) * w + e) / weight_sum;
}


void main() {

    ivec2 texel = ivec2(gl_FragCoord.xy);

    if (abs(MC_RENDER_QUALITY - 1.0) < 0.01) {
        fragment_color
            = cas_filter(colortex0, texel, CAS_INTENSITY * 2.0 - 1.0);
    } else {
        fragment_color = catmull_rom_filter_fast_rgb(colortex0, uv, 0.6);
        fragment_color = display_eotf(fragment_color);
    }

    fragment_color = dither_8bit(fragment_color, bayer16(vec2(texel)));

#if DEBUG_VIEW == DEBUG_VIEW_SAMPLER
    if (clamp(texel, ivec2(0), ivec2(textureSize(DEBUG_SAMPLER, 0))) == texel) {
        fragment_color = texelFetch(DEBUG_SAMPLER, texel, 0).rgb;
        fragment_color = display_eotf(fragment_color);
    }
#elif DEBUG_VIEW == DEBUG_VIEW_WEATHER
    debug_weather(fragment_color);
#elif DEBUG_VIEW == DEBUG_VIEW_GI
#if LIGHTING_MODE == LIGHTING_MODE_RT
    fragment_color = gi_debug_view(texel, uv, fragment_color);
    fragment_color = gi_debug_stamp_swatch(fragment_color, texel);
#else
    // Magenta is not a bug report about the scene: it means the GI debug views
    // have nothing to read because ray-traced GI is disabled.
    fragment_color = vec3(0.6, 0.0, 0.6);
#endif
#endif

#ifdef DISTANCE_VIEW
    float depth
        = texelFetch(depthtex0, ivec2(uv * view_res * taau_render_scale), 0).x;

    vec3 position_screen = vec3(uv, depth);
    vec3 position_view
        = screen_to_view_space(gbufferProjectionInverse, position_screen, true);

    bool is_sky = depth == 1.0;

#ifdef LOD_MOD_ACTIVE
    float depth_lod = texelFetch(lod_depth_tex, texel, 0).x;
    bool is_lod = is_lod_terrain(depth, depth_lod);

    if (is_lod) {
        position_view = screen_to_view_space(
            dhProjectionInverse,
            vec3(uv, depth_lod),
            true
        );
    }

    is_sky = is_sky && depth_lod == 1.0;
#endif

#if DISTANCE_VIEW_METHOD == DISTANCE_VIEW_DISTANCE
    float dist = length(position_view);
#elif DISTANCE_VIEW_METHOD == DISTANCE_VIEW_DEPTH
    float dist = -position_view.z;
#endif

    fragment_color = is_sky
        ? vec3(1.0)
        : vec3(clamp01(dist * rcp(DISTANCE_VIEW_MAX_DISTANCE)));
#endif

#if LIGHTING_MODE == LIGHTING_MODE_RT && (defined WORLD_NETHER || !defined SHADOW)
    // Must sample shadowtex0 so that the shadow map is rendered
    if (uv.x < 0.0) {
        fragment_color = texture(shadowtex0, uv).rgb;
    }
#endif
}

#include "/include/buffers.glsl"
