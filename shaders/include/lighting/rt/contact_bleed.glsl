#if !defined INCLUDE_LIGHTING_RT_CONTACT_BLEED
#define INCLUDE_LIGHTING_RT_CONTACT_BLEED

// Screen-space contact diffuse scatter for direct sunlight on coplanar surfaces.

#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "/include/utility/color.glsl"

vec4 gather_contact_diffuse_bleed(
    vec2 uv,
    float depth,
    vec3 scene_pos,
    vec3 world_normal,
    float receiver_skylight,
    vec3 direct_sun_color,
    vec3 l_dir,
    vec2 dither,
    usampler3D voxel_grid
) {
#if !defined WORLD_OVERWORLD || !defined COPLANAR_CONTACT_BLEED
    return vec4(0.0);
#else
    // Direct sunlight coplanar scatter requires sky exposure and active sunlight
    if (receiver_skylight < 0.02 || (direct_sun_color.r + direct_sun_color.g + direct_sun_color.b) <= 0.0) {
        return vec4(0.0);
    }

    // A flat plane can only receive direct sunlight if its normal faces the sun
    float NoL = dot(world_normal, l_dir);
    if (NoL <= 0.0) {
        return vec4(0.0);
    }

    vec3 screen_pos = vec3(taau_projection_uv(uv), depth);
    vec3 view_pos = screen_to_view_space(screen_pos, true);
    float dist_cam = max(-view_pos.z, 0.5);

#ifndef COPLANAR_BLEED_RADIUS
#define COPLANAR_BLEED_RADIUS 1.8
#endif

    // Metric radius projected to screen UV space, clamped to safe pixel bounds
    float search_radius_uv = clamp(
        (COPLANAR_BLEED_RADIUS / dist_cam) * (gbufferProjection[1][1] * 0.5),
        view_pixel_size.y * 3.0,
        view_pixel_size.y * 36.0
    );

    // 6-tap Poisson disc with randomized rotation per pixel
    const vec2 disc_samples[6] = vec2[6](
        vec2( 0.0000,  0.8660),
        vec2( 0.7500,  0.4330),
        vec2( 0.7500, -0.4330),
        vec2( 0.0000, -0.8660),
        vec2(-0.7500, -0.4330),
        vec2(-0.7500,  0.4330)
    );

    float rot_angle = dither.x * 6.28318530718;
    vec2 rot_cs = vec2(cos(rot_angle), sin(rot_angle));
    mat2 rot = mat2(rot_cs.x, -rot_cs.y, rot_cs.y, rot_cs.x);
    vec2 aspect = vec2(view_res.y / view_res.x, 1.0);

    vec3 accum_bleed = vec3(0.0);
    float total_weight = 0.0;

    for (int i = 0; i < 6; ++i) {
        vec2 tap_uv = uv + (rot * disc_samples[i]) * search_radius_uv * aspect;
        if (taau_uv_outside_viewport(tap_uv)) {
            continue;
        }

        ivec2 tap_texel = ivec2(tap_uv * view_res);
        float tap_depth = texelFetch(depthtex1, tap_texel, 0).x;
        if (tap_depth >= 1.0) {
            continue;
        }

        vec4 tap_gbuf0 = texelFetch(colortex1, tap_texel, 0);
        vec3 tap_normal = decode_unit_vector(unpack_unorm_2x8(tap_gbuf0.z));

        // Normal alignment: must be coplanar with the same facing
        if (dot(world_normal, tap_normal) < 0.85) {
            continue;
        }

        // Skylight access check: neighbor must have skylight
        float tap_skylight = unpack_unorm_2x8(tap_gbuf0.w).y;
        if (tap_skylight < 0.02) {
            continue;
        }

        vec3 tap_screen = vec3(taau_projection_uv(tap_uv), tap_depth);
        vec3 tap_view = screen_to_view_space(tap_screen, true);
        vec3 tap_scene = view_to_scene_space(tap_view);

        // Point-to-plane distance: tap must lie on the tangent plane of receiver
        vec3 delta = tap_scene - scene_pos;
        float plane_dist = abs(dot(world_normal, delta));
        if (plane_dist > 0.18) {
            continue;
        }

        // Lateral distance on the surface
        float lateral_dist = length(delta - world_normal * dot(world_normal, delta));
        if (lateral_dist > COPLANAR_BLEED_RADIUS || lateral_dist < 0.04) {
            continue;
        }

        // Check direct sunlight visibility at neighbor
        float tap_NoL = max(0.0, dot(tap_normal, l_dir));
        if (tap_NoL <= 0.0) {
            continue;
        }

        vec3 shadow_start = tap_scene + tap_normal * 0.05 + l_dir * 0.02;
        float tap_sun_vis = trace_sun_visibility(voxel_grid, 0, shadow_start, l_dir);
        if (tap_sun_vis <= 0.0) {
            continue;
        }

        // Neighbor is hit by direct sun: extract albedo and apply dielectric Fresnel & saturation control
        vec2 tap_albedo_rg = unpack_unorm_2x8(tap_gbuf0.x);
        float tap_albedo_b = unpack_unorm_2x8(tap_gbuf0.y).x;
        vec3 tap_albedo = vec3(tap_albedo_rg, tap_albedo_b);
        tap_albedo = srgb_eotf_inv(tap_albedo) * rec709_to_rec2020;

#ifndef GI_BOUNCE_SATURATION
#define GI_BOUNCE_SATURATION 0.75
#endif
        float tap_lum = dot(tap_albedo, luminance_weights);
        tap_albedo = mix(vec3(tap_lum), tap_albedo, GI_BOUNCE_SATURATION);
        tap_albedo = mix(tap_albedo, vec3(1.0), 0.04);

        // Reflected radiance from neighbor tap
        vec3 tap_radiance = tap_albedo * (direct_sun_color * (tap_sun_vis * tap_NoL)) * voxel_bounce_rcp_pi;

        // Diffuse lateral scatter kernel (smooth quadratic falloff with distance)
        float dist_norm = clamp01(lateral_dist / COPLANAR_BLEED_RADIUS);
        float falloff = 1.0 - dist_norm * dist_norm;
        falloff *= falloff;

        accum_bleed += tap_radiance * falloff;
        total_weight += falloff;
    }

#ifndef COPLANAR_BLEED_STRENGTH
#define COPLANAR_BLEED_STRENGTH 0.40
#endif

    if (total_weight > 0.0) {
        vec3 bleed_result = (accum_bleed / (total_weight + 1.5)) * COPLANAR_BLEED_STRENGTH;
        return vec4(bleed_result, 1.0);
    }

    return vec4(0.0);
#endif
}

#endif // INCLUDE_LIGHTING_RT_CONTACT_BLEED
