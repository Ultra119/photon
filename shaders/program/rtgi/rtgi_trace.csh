/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI
  program/rtgi/rtgi_trace.csh:
  Trace diffuse indirect GI rays (world-space voxel RT)

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

// Declared only when the diagnostic view is active, so the image is neither
// allocated (see shaders.properties) nor written in normal play.
#if GI_DEBUG == GI_DEBUG_HIT
layout(rgba8) writeonly uniform image2D rtgi_hit_img;
#endif

#include "/include/lighting/rt/voxel_samplers.glsl"
uniform sampler2D shadowtex0;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D colortex1; // gbuffer0
uniform sampler2D colortex2; // gbuffer1
uniform sampler2D colortex4; // sky map & light colors
uniform sampler2D noisetex;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;

uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform int frameCounter;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec3 light_dir;

uniform float near;
uniform float far;
uniform vec2 taa_offset;

#define TEMPORAL_REPROJECTION
#include "/include/utility/color.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "/include/utility/random.glsl"
#include "/include/lighting/rt/rt_gi.glsl"

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

    // uv is a full-framebuffer UV. Under TAAU only the lower-left
    // taau_render_scale x taau_render_scale region contains scene data.
    vec2 uv = (vec2(texel) + 0.5) / vec2(target_res);

    if (taau_uv_outside_viewport(uv)) {
        imageStore(rtgi_raw_img, texel, vec4(0.0));
#if GI_DEBUG == GI_DEBUG_HIT
        imageStore(rtgi_hit_img, texel, vec4(0.0));
#endif
        return;
    }

    ivec2 full_texel = ivec2(uv * view_res);

    float depth = texelFetch(depthtex1, full_texel, 0).x;
    if (depth >= 1.0) {
        imageStore(rtgi_raw_img, texel, vec4(0.0));
#if GI_DEBUG == GI_DEBUG_HIT
        imageStore(rtgi_hit_img, texel, vec4(0.0));
#endif
        return;
    }

    // Unpack surface data
    vec4 gbuf0 = texelFetch(colortex1, full_texel, 0);
    vec3 world_normal = decode_unit_vector(unpack_unorm_2x8(gbuf0.z));
    // Vanilla skylight of the receiver (packed with blocklight in gbuffer0.w).
    // Used to gate sky-origin GI so sealed interiors stay dark.
    float receiver_skylight = unpack_unorm_2x8(gbuf0.w).y;

#if defined NORMAL_MAPPING
    vec4 gbuf1 = texelFetch(colortex2, full_texel, 0);
    vec3 mapped_normal = decode_unit_vector(gbuf1.xy);
#else
    vec3 mapped_normal = world_normal;
#endif

    // Convert the framebuffer UV back to projection UV before inverting the
    // (jittered, TAAU-scaled) projection.
    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    vec3 scene_pos = view_to_scene_space(view_pos);

    // Spatio-temporal dither using channel .b (blue noise, NOT .rg which is 2D Worley cellular noise)
    vec2 dither = vec2(
        texelFetch(noisetex, full_texel & 511, 0).b,
        texelFetch(noisetex, (full_texel + 249) & 511, 0).b
    );
    dither = r2(frameCounter, dither);

    // Direct lighting & ambient colors encoded in colortex4 column 191
    vec3 direct_light_col = texelFetch(colortex4, ivec2(191, 0), 0).rgb;

    // Ray budget (default 2 rays/pixel)
#ifndef RTGI_RAY_COUNT
#define RTGI_RAY_COUNT 2
#endif

    vec4 accum_radiance = vec4(0.0);

#if GI_DEBUG == GI_DEBUG_HIT
    // Counts per estimator, normalised at the end so the view shows a
    // proportion and RTGI_RAY_COUNT does not change the colour.
    vec3 hit_counts = vec3(0.0);
#endif

    for (int r = 0; r < RTGI_RAY_COUNT; ++r) {
        vec2 u = r2(r, dither);
        vec3 ray_dir = sample_cosine_hemisphere(mapped_normal, u);

        // Prevent ray from shooting into geometric surface
        if (dot(ray_dir, world_normal) <= 0.0) {
            ray_dir = reflect(ray_dir, world_normal);
        }

        int hit_source = RTGI_HIT_NONE;
        vec4 radiance = evaluate_rtgi_ray(
            scene_pos,
            world_normal,
            ray_dir,
            dither.x,
            receiver_skylight,
            voxel_sampler,
            voxel_mid_sampler,
            voxel_coarse_sampler,
            colortex4,
            direct_light_col,
            light_dir,
            hit_source
        );

#if GI_DEBUG == GI_DEBUG_HIT
        if (hit_source == RTGI_HIT_VOXEL) {
            hit_counts.g += 1.0;
        } else if (hit_source == RTGI_HIT_SKY) {
            hit_counts.b += 1.0;
        }
#endif

        // Stage 7 Firefly suppression: limit extreme single-ray radiance spikes
        float lum = dot(radiance.rgb, luminance_weights);
#ifndef RTGI_MAX_RADIANCE
#define RTGI_MAX_RADIANCE 8.0
#endif
        if (lum > RTGI_MAX_RADIANCE) {
            radiance.rgb *= RTGI_MAX_RADIANCE / lum;
        }

        accum_radiance += radiance;
    }

    vec4 final_radiance = accum_radiance * (1.0 / float(RTGI_RAY_COUNT));
    final_radiance.a = clamp01(final_radiance.a);

    imageStore(rtgi_raw_img, texel, final_radiance);

#if GI_DEBUG == GI_DEBUG_HIT
    imageStore(rtgi_hit_img, texel, vec4(hit_counts / float(RTGI_RAY_COUNT), 1.0));
#endif
}
