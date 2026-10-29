#if !defined INCLUDE_LIGHTING_RT_SSGI
#define INCLUDE_LIGHTING_RT_SSGI

// global.glsl included by parent program
#include "/include/misc/raytracer.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "voxel_dda.glsl"

struct SSGIHit {
    bool hit;
    vec2 hit_uv;
    vec3 hit_pos_scene;
    vec3 radiance;
    float sky_weight;
    float edge_fade;
};

// Screen-space GI raymarcher (Stage 6 C.1: current-frame analytic radiance)
SSGIHit trace_screen_space_gi(
    vec3 screen_pos,
    vec3 view_pos,
    vec3 view_normal,
    vec3 ray_dir_view,
    float dither,
    float surface_skylight,
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    vec3 direct_sun_color,
    vec3 sky_ambient_color,
    vec3 l_dir,
    sampler2D gbuffer0_sampler,
    sampler2D depth_translucent_sampler
) {
    SSGIHit result;
    result.hit = false;
    result.hit_uv = vec2(0.0);
    result.hit_pos_scene = vec3(0.0);
    result.radiance = vec3(0.0);
    result.sky_weight = 0.0;
    result.edge_fade = 0.0;

    // When local-light SSGI is disabled, do not consume the ray in cave /
    // low-skylight scenes. Returning a zero-radiance hit here would block the
    // camera-independent voxel DDA fallback and recreate view dependence.
    if (RTGI_SSGI_LOCAL_LIGHT_SCALE <= 0.0 && surface_skylight < 0.25) {
        return result;
    }

    // Skip rays that face backwards or are too grazing into the surface
    if (dot(ray_dir_view, view_normal) <= 0.05) {
        return result;
    }

    // A tiny direction perturbation keeps screen-space rays off exact depth
    // seams. The raymarch dither alone only offsets steps, not the ray plane.
    vec3 ssgi_seed = ray_dir_view + vec3(dither);
    vec3 ssgi_jitter = vec3(
        fract(sin(dot(ssgi_seed, vec3(12.9898, 78.233, 37.719))) * 43758.5453),
        fract(sin(dot(ssgi_seed, vec3(39.3468, 11.135, 83.155))) * 24634.6345),
        fract(sin(dot(ssgi_seed, vec3(73.156, 52.235, 9.151))) * 91245.9421)
    ) - 0.5;
    vec3 march_dir_view = normalize(ray_dir_view + ssgi_jitter * 0.02);

    vec3 hit_screen_pos;
    const uint steps = 16u;
    const uint refinement = 2u;

    // Bias start point along normal to prevent self-intersection with the originating depth surface
    vec3 start_view_pos = view_pos + view_normal * 0.15 + march_dir_view * 0.05;
    vec3 start_screen_pos = view_to_screen_space(SSRT_PROJECTION_MATRIX, start_view_pos, true);

    bool hit = raymarch_depth_buffer(
        start_screen_pos,
        start_view_pos,
        march_dir_view,
        dither,
        steps,
        refinement,
        hit_screen_pos
    );

    if (hit) {
        // Border attenuation: fade out rays near the edge of the viewport
        vec2 border = abs(hit_screen_pos.xy * 2.0 - 1.0);
        float edge_dist = clamp01(1.0 - max(border.x, border.y));
        float edge_fade = smoothstep(0.0, 0.08, edge_dist);

        if (edge_fade > 0.01) {
            vec3 hit_pos_view = screen_to_view_space(SSRT_PROJECTION_MATRIX_INVERSE, hit_screen_pos, false);
            vec3 hit_pos_scene = view_to_scene_space(hit_pos_view);
            vec3 origin_pos_scene = view_to_scene_space(view_pos);

            // Reject self-intersection and adjacent faces of the same world
            // block. Otherwise a pale sunlit/lamp-lit block can sample its own
            // color through a seam and create a glowing loop.
            if (distance(hit_pos_scene, origin_pos_scene) < 0.10) {
                return result;
            }

            // Compare in camera-relative block space: only the camera's
            // fractional offset is needed, avoiding precision loss at large
            // world coordinates.
            vec3 camera_block_offset = fract(cameraPosition);
            ivec3 origin_block = ivec3(floor(origin_pos_scene + camera_block_offset));
            ivec3 hit_block = ivec3(floor(hit_pos_scene + camera_block_offset));
            if (origin_block == hit_block) {
                return result;
            }

            // hit_screen_pos is in projection space; convert to full-framebuffer
            // texel coordinates before fetching depth/G-buffer data.
            vec2 hit_framebuffer_uv = taau_framebuffer_uv(hit_screen_pos.xy);
            ivec2 hit_texel = clamp(
                ivec2(hit_framebuffer_uv * view_res),
                ivec2(0),
                ivec2(view_res) - 1
            );

            // Check if the hit surface is behind translucent geometry (glass/water)
            float d_trans = texelFetch(depth_translucent_sampler, hit_texel, 0).x;
            float d_solid = texelFetch(SSRT_DEPTH_SAMPLER, hit_texel, 0).x;
            if (d_trans < d_solid - 1e-4) {
                // Target is behind translucent geometry: bypass SSGI and let 3D Voxel DDA
                // trace through the glass voxels for 100% physically accurate colored transmission!
                return result;
            }

            // Stage 6 C.1: Current-Frame Direct Lighting Evaluation
            // Fetch hit G-buffer normal, albedo and light levels from colortex1 (gbuffer0_sampler)
            vec4 gbuf = textureLod(gbuffer0_sampler, hit_framebuffer_uv, 0.0);
            vec2 rg = unpack_unorm_2x8(gbuf.x);
            vec2 b_mask = unpack_unorm_2x8(gbuf.y);
            vec3 hit_albedo = vec3(rg, b_mask.x);
            vec3 hit_normal = decode_unit_vector(unpack_unorm_2x8(gbuf.z));
            vec3 hit_normal_view = mat3(gbufferModelView) * hit_normal;
            vec2 hit_light_levels = unpack_unorm_2x8(gbuf.w);

            if (dot(hit_normal_view, -march_dir_view) > 0.05) {
                // 1. Direct Sun / Moon incident irradiance [W/m^2]
                float sun_vis = sample_voxel_sun_shadow(
                    shadow_tex,
                    shadow_mv,
                    shadow_proj,
                    hit_pos_scene,
                    hit_normal,
                    l_dir
                );
                float NoL = max(0.0, dot(hit_normal, l_dir));
                vec3 direct_sun = direct_sun_color * (sun_vis * NoL);

                // 2. Direct Sky incident irradiance [W/m^2]
                // Aligned with voxel_dda.glsl: solid surfaces do not inject ambient skylight from lightmap,
                // as vertex skylight leaks through walls/ceilings into interiors. Skylight enters only when rays escape to sky.
                vec3 direct_sky = vec3(0.0);

                // 3. Direct Blocklight incident irradiance [W/m^2]
                float blocklight_falloff = pow8(hit_light_levels.x) + 0.18 * sqr(hit_light_levels.x) + 0.5 * pow4(hit_light_levels.x);
                vec3 direct_block = blocklight_falloff * (blocklight_scale * blocklight_color);

                // Total direct irradiance at the hit surface
                vec3 direct_irradiance = direct_sun + direct_sky + direct_block;

                // Outgoing reflected radiance towards the ray: L_o = (albedo / pi) * E
                vec3 hit_radiance = hit_albedo * direct_irradiance * voxel_bounce_rcp_pi;

                result.hit = true;
                result.hit_uv = hit_framebuffer_uv;
                result.hit_pos_scene = hit_pos_scene;
                result.radiance = hit_radiance;
                result.edge_fade = edge_fade;

                float sun_sky_lum = dot(direct_sun + direct_sky, luminance_weights);
                float total_lum = dot(direct_irradiance, luminance_weights);
                result.sky_weight = clamp01(sun_sky_lum / max(total_lum, eps));
            }
        }
    }

    return result;
}

#endif // INCLUDE_LIGHTING_RT_SSGI
