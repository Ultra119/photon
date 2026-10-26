#if !defined INCLUDE_LIGHTING_RT_SSGI
#define INCLUDE_LIGHTING_RT_SSGI

// global.glsl included by parent program
#include "/include/misc/raytracer.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"

struct SSGIHit {
    bool hit;
    vec2 hit_uv;
    vec3 hit_pos_scene;
    vec3 radiance;
    float sky_weight;
};

// Screen-space GI raymarcher
SSGIHit trace_screen_space_gi(
    vec3 screen_pos,
    vec3 view_pos,
    vec3 view_normal,
    vec3 ray_dir_view,
    float dither,
    sampler2D scene_color_sampler,
    sampler2D gbuffer0_sampler,
    sampler2D depth_translucent_sampler
) {
    SSGIHit result;
    result.hit = false;
    result.hit_uv = vec2(0.0);
    result.hit_pos_scene = vec3(0.0);
    result.radiance = vec3(0.0);
    result.sky_weight = 0.0;

    // Skip rays that face backwards or are too grazing into the surface
    if (dot(ray_dir_view, view_normal) <= 0.05) {
        return result;
    }

    vec3 hit_screen_pos;
    const uint steps = 16u;
    const uint refinement = 2u;

    // Bias start point along normal to prevent self-intersection with the originating depth surface
    vec3 start_view_pos = view_pos + view_normal * 0.15 + ray_dir_view * 0.05;
    vec3 start_screen_pos = view_to_screen_space(SSRT_PROJECTION_MATRIX, start_view_pos, true);

    bool hit = raymarch_depth_buffer(
        start_screen_pos,
        start_view_pos,
        ray_dir_view,
        dither,
        steps,
        refinement,
        hit_screen_pos
    );

    if (hit) {
        // Border attenuation: fade out rays near the edge of the viewport
        vec2 border = abs(hit_screen_pos.xy * 2.0 - 1.0);
        float edge_fade = clamp01(1.0 - max(border.x, border.y));
        edge_fade = smoothstep(0.0, 0.08, edge_fade);

        if (edge_fade > 0.01) {
            vec3 hit_pos_view = screen_to_view_space(SSRT_PROJECTION_MATRIX_INVERSE, hit_screen_pos, false);
            vec3 hit_pos_scene = view_to_scene_space(hit_pos_view);
            vec3 origin_pos_scene = view_to_scene_space(view_pos);

            // Reject self-intersection (hit within 0.10m of originating surface)
            if (distance(hit_pos_scene, origin_pos_scene) < 0.10) {
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

            // Reproject hit to previous frame color buffer
            vec3 prev_screen_pos = reproject_scene_space(hit_pos_scene, false, false);
            if (clamp01(prev_screen_pos.xy) == prev_screen_pos.xy) {
                vec3 sample_col = textureLod(scene_color_sampler, prev_screen_pos.xy, 0.0).rgb;
                sample_col = max(vec3(0.0), min(sample_col, vec3(6.0)));

                // Validate hit normal opposing ray using current-frame gbuffer at hit screen coord
                vec4 gbuf = textureLod(gbuffer0_sampler, hit_framebuffer_uv, 0.0);
                vec3 hit_normal = decode_unit_vector(unpack_unorm_2x8(gbuf.z));
                vec3 hit_normal_view = mat3(gbufferModelView) * hit_normal;
                vec2 hit_light_levels = unpack_unorm_2x8(gbuf.w);

                if (dot(hit_normal_view, -ray_dir_view) > -0.1) {
                    // Previous-frame color is strongly view-dependent for
                    // local lights. Damp it in low-skylight scenes and let the
                    // voxel point-light field carry the stable bounce instead.
                    float local_light_factor = clamp01(1.0 - sqr(hit_light_levels.y));
                    float ssgi_scale = mix(
                        1.2,
                        RTGI_SSGI_LOCAL_LIGHT_SCALE,
                        local_light_factor
                    );

                    result.hit = true;
                    result.hit_uv = prev_screen_pos.xy;
                    result.hit_pos_scene = hit_pos_scene;
                    result.radiance = sample_col * edge_fade * ssgi_scale;
                    // Previous-frame color from a high-skylight surface is
                    // mostly sun/sky driven; low-skylight hits are treated as
                    // emissive/block-light driven and are never gated indoors.
                    result.sky_weight = clamp01(sqr(hit_light_levels.y));
                }
            }
        }
    }

    return result;
}

#endif // INCLUDE_LIGHTING_RT_SSGI

