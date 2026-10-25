/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  program/rtgi/rtgi_trace.csh:
  Trace diffuse indirect GI rays (Screen-Space + Voxel DDA)

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

layout(rgba16f) writeonly uniform image2D rtgi_raw_img;

uniform usampler3D voxel_sampler;
uniform sampler2D shadowtex0;
uniform sampler2D depthtex1;
uniform sampler2D colortex1; // gbuffer0
uniform sampler2D colortex2; // gbuffer1
uniform sampler2D colortex4; // sky map & light colors
uniform sampler2D colortex5; // previous frame scene color
uniform sampler2D noisetex;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec3 light_dir;

uniform float near;
uniform float far;
uniform vec2 taa_offset;

#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "/include/utility/random.glsl"
#include "/include/lighting/rt/hybrid_rtgi.glsl"

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
    vec2 uv = (vec2(full_texel) + 0.5) * view_pixel_size;

    float depth = texelFetch(depthtex1, full_texel, 0).x;
    if (depth >= 1.0) {
        imageStore(rtgi_raw_img, texel, vec4(0.0));
        return;
    }

    // Unpack surface data
    vec4 gbuf0 = texelFetch(colortex1, full_texel, 0);
    vec3 world_normal = decode_unit_vector(unpack_unorm_2x8(gbuf0.z));

#if defined NORMAL_MAPPING
    vec4 gbuf1 = texelFetch(colortex2, full_texel, 0);
    vec3 mapped_normal = decode_unit_vector(gbuf1.xy);
#else
    vec3 mapped_normal = world_normal;
#endif

    // Reconstruct position
    vec3 screen_pos = vec3(uv, depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    vec3 scene_pos = view_to_scene_space(view_pos);

    // Blue noise jittering
    ivec2 noise_coord = (texel + ivec2(frameCounter * 73, frameCounter * 151)) & 511;
    vec2 blue_noise = texelFetch(noisetex, noise_coord, 0).rg;

    // Direct lighting & ambient colors encoded in colortex4 column 191
    vec3 direct_light_col = texelFetch(colortex4, ivec2(191, 0), 0).rgb;
    vec3 sky_amb_col = texelFetch(colortex4, ivec2(191, 1), 0).rgb;

    // Ray budget (default 2 rays/pixel)
#ifndef RTGI_RAY_COUNT
#define RTGI_RAY_COUNT 2
#endif

    vec3 accum_radiance = vec3(0.0);
    float dither = blue_noise.x;

    for (int r = 0; r < RTGI_RAY_COUNT; ++r) {
        vec2 u = fract(blue_noise + r2(frameCounter + r * 19, blue_noise));
        vec3 ray_dir = sample_cosine_hemisphere(mapped_normal, u);

        vec3 radiance = evaluate_hybrid_rtgi_ray(
            screen_pos,
            view_pos,
            mat3(gbufferModelView) * mapped_normal,
            scene_pos,
            mapped_normal,
            ray_dir,
            dither,
            voxel_sampler,
            shadowtex0,
            shadowModelView,
            shadowProjection,
            colortex5,
            colortex1,
            direct_light_col,
            sky_amb_col,
            light_dir
        );

        accum_radiance += radiance;
    }

    vec3 final_radiance = accum_radiance * (1.0 / float(RTGI_RAY_COUNT));

    imageStore(rtgi_raw_img, texel, vec4(final_radiance, 1.0));
}
