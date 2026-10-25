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
};

// Screen-space GI raymarcher
SSGIHit trace_screen_space_gi(
    vec3 screen_pos,
    vec3 view_pos,
    vec3 view_normal,
    vec3 ray_dir_view,
    float dither,
    sampler2D scene_color_sampler,
    sampler2D gbuffer0_sampler
) {
    SSGIHit result;
    result.hit = false;
    result.hit_uv = vec2(0.0);
    result.hit_pos_scene = vec3(0.0);
    result.radiance = vec3(0.0);

    // Skip rays that face backwards into the surface
    if (dot(ray_dir_view, view_normal) <= 0.001) {
        return result;
    }

    vec3 hit_screen_pos;
    const uint steps = 16u;
    const uint refinement = 2u;

    bool hit = raymarch_depth_buffer(
        screen_pos,
        view_pos,
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

            // Reproject hit to previous frame color buffer
            vec3 prev_screen_pos = reproject_scene_space(hit_pos_scene, false, false);
            if (clamp01(prev_screen_pos.xy) == prev_screen_pos.xy) {
                vec3 sample_col = textureLod(scene_color_sampler, prev_screen_pos.xy, 0.0).rgb;

                // Validate hit normal is opposing ray
                vec4 gbuf = textureLod(gbuffer0_sampler, prev_screen_pos.xy, 0.0);
                vec3 hit_normal = decode_unit_vector(unpack_unorm_2x8(gbuf.z));
                vec3 hit_normal_view = mat3(gbufferModelView) * hit_normal;

                if (dot(hit_normal_view, -ray_dir_view) > -0.1) {
                    result.hit = true;
                    result.hit_uv = prev_screen_pos.xy;
                    result.hit_pos_scene = hit_pos_scene;
                    result.radiance = sample_col * edge_fade;
                }
            }
        }
    }

    return result;
}

#endif // INCLUDE_LIGHTING_RT_SSGI

