#if !defined INCLUDE_LIGHTING_RT_VOXEL_DDA
#define INCLUDE_LIGHTING_RT_VOXEL_DDA

// global.glsl included by parent program
#include "/include/lighting/voxel/voxel_constants.glsl"
#include "/include/lighting/voxel/voxel_storage.glsl"
#include "/include/lighting/shadows/distortion.glsl"
#include "/include/lighting/colors/blocklight_color.glsl"

// Lambertian surfaces convert irradiance to radiance with 1/pi. Voxel DDA
// only stores irradiance-like sun/sky/blocklight terms, so the bounce must be
// divided by pi before being accumulated as GI radiance.
const float voxel_bounce_rcp_pi = 0.31830988618;

// Hemisphere samples can land exactly on a voxel face/corner seam. A tiny
// deterministic perturbation keeps the DDA ray from traveling forever along
// that plane and sampling sunlight or point lights through solid walls.
vec3 rtgi_voxel_ray_jitter(float dither, vec3 ray_dir) {
    vec3 seed = ray_dir + vec3(dither);
    return vec3(
        fract(sin(dot(seed, vec3(12.9898, 78.233, 37.719))) * 43758.5453),
        fract(sin(dot(seed, vec3(39.3468, 11.135, 83.155))) * 24634.6345),
        fract(sin(dot(seed, vec3(73.156, 52.235, 9.151))) * 91245.9421)
    ) - 0.5;
}

struct VoxelHit {
    bool hit;
    vec3 hit_pos;
    vec3 hit_normal;
    vec3 radiance;
    float distance;
    vec3 transmittance;
    float sky_weight;
    vec3 accumulated_light;
};

// Check if voxel point is in sunlight shadow using shadow map
float sample_voxel_sun_shadow(
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    vec3 scene_pos,
    vec3 normal,
    vec3 l_dir
) {
    float NoL = dot(normal, l_dir);
    if (NoL <= 0.0) return 0.0;

    vec3 bias = normal * 0.15;
    vec3 shadow_view = mat3(shadow_mv) * (scene_pos + bias) + shadow_mv[3].xyz;
    vec4 shadow_clip = shadow_proj * vec4(shadow_view, 1.0);
    vec3 shadow_ndc = shadow_clip.xyz / shadow_clip.w;
    shadow_ndc = distort_shadow_space(shadow_ndc);
    vec3 shadow_screen = shadow_ndc * 0.5 + 0.5;

    if (clamp01(shadow_screen) != shadow_screen) {
        return 1.0; // Outside shadow map
    }

    float shadow_depth = texture(shadow_tex, shadow_screen.xy).r;
    return float(shadow_depth >= shadow_screen.z - 0.001);
}

// 3D Amanatides-Woo DDA voxel traversal
VoxelHit trace_voxel_dda(
    usampler3D voxel_grid,
    sampler2D shadow_tex,
    mat4 shadow_mv,
    mat4 shadow_proj,
    vec3 ray_origin_scene,
    vec3 surface_normal,
    vec3 ray_dir,
    float dither,
    vec3 direct_sun_color,
    vec3 sky_ambient_color,
    vec3 l_dir,
    float max_dist
) {
    VoxelHit result;
    vec3 dda_dir = normalize(ray_dir + rtgi_voxel_ray_jitter(dither, ray_dir) * 0.05);
    result.hit = false;
    result.hit_pos = ray_origin_scene + dda_dir * max_dist;
    result.hit_normal = -dda_dir;
    result.radiance = vec3(0.0);
    result.distance = max_dist;
    result.transmittance = vec3(1.0);
    result.sky_weight = 0.0;
    result.accumulated_light = vec3(0.0);

    vec3 ray_transmittance = vec3(1.0);
    vec3 accumulated_light = vec3(0.0);

    // Offset ray origin along surface normal and forward to clear starting block boundary
    vec3 start_scene = ray_origin_scene + surface_normal * 0.25 + dda_dir * 0.05;
    vec3 start_voxel = scene_to_voxel_space(start_scene);
    ivec3 current_voxel = ivec3(floor(start_voxel));

    // Voxels containing the origin surface point (must not self-intersect).
    // Use both the geometric normal and the traced ray so mapped normals or
    // exact seams cannot leave an unignored solid voxel at the ray start.
    ivec3 origin_voxel = ivec3(floor(scene_to_voxel_space(ray_origin_scene - surface_normal * 0.1)));
    ivec3 origin_voxel_ray = ivec3(floor(scene_to_voxel_space(ray_origin_scene - dda_dir * 0.1)));

    vec3 step_dir = sign(dda_dir);
    vec3 delta_t = abs(1.0 / (dda_dir + vec3(1e-7)));
    vec3 t_max = (step_dir * (vec3(current_voxel) - start_voxel) + step_dir * 0.5 + 0.5) * delta_t;

    vec3 mask = vec3(0.0);
    float t = 0.0;

    const int MAX_STEPS = voxel_dda_max_steps;
    for (int i = 0; i < MAX_STEPS; ++i) {
        if (!is_inside_voxel_grid(current_voxel) || t > max_dist) {
            break;
        }

        float next_t = min(min(t_max.x, t_max.y), t_max.z);
        float clamped_next_t = min(next_t, max_dist);
        float segment_length = max(clamped_next_t - t, 0.0);
        float segment_mid = 0.5 * (t + clamped_next_t);

        // Ignore the origin block to completely eliminate self-intersection
        if (current_voxel != origin_voxel && current_voxel != origin_voxel_ray) {
            uint packed = texelFetch(voxel_grid, current_voxel, 0).r;
            VoxelSample sample_data = unpack_voxel_data(packed);

            // Light-only voxel: block_id == 0, block_light > 0. Accumulate it
            // as a camera-independent emissive medium instead of stopping the ray.
            // NB: RTGI_POINT_LIGHT_STRENGTH is a float slider; it must be tested
            // with a runtime if (constant-folded by the driver), never with #if,
            // because float literals are illegal in GLSL preprocessor expressions.
            if (RTGI_POINT_LIGHT_STRENGTH > 0.0 && sample_data.block_id == 0u && sample_data.block_light > 0.0) {
                float scatter = 1.0 - exp(-0.22 * segment_length);
                float distance_falloff = exp(-0.16 * segment_mid);
                accumulated_light += sample_data.color
                    * (sample_data.block_light * blocklight_scale)
                    * scatter * distance_falloff * ray_transmittance;
            }

            if (sample_data.block_id != 0u) {
                VoxelMaterial mat = get_voxel_material(sample_data.block_id, sample_data.color);

                // Stained glass tints transmittance but does not stop the ray.
                if (sample_data.block_id >= 81u && sample_data.block_id <= 96u) {
                    ray_transmittance *= mat.albedo;
                } else if (sample_data.block_id == 80u) {
                    // Clear glass: passes through without tinting
                } else if (RTGI_POINT_LIGHT_STRENGTH > 0.0 && sample_data.is_emitter && is_point_light_emitter(sample_data.block_id)) {
                    // Small emitters are transparent light sources when radial point-light
                    // accumulation is active.
                    vec3 emitter_pos = voxel_to_scene_space(vec3(current_voxel) + 0.5);
                    float emitter_dist = length(emitter_pos - ray_origin_scene);
                    float emitter_attenuation = exp(-0.30 * emitter_dist)
                        * RTGI_POINT_LIGHT_STRENGTH;
                    accumulated_light += mat.emission
                        * emitter_attenuation * 0.20 * ray_transmittance;
                } else if (mat.is_solid || sample_data.is_emitter) {
                    result.hit = true;
                    result.hit_normal = (dot(mask, mask) > 0.5) ? (-mask * step_dir) : -sign(dda_dir);
                    result.distance = t;
                    result.transmittance = ray_transmittance;

                    vec3 hit_voxel_scene = voxel_to_scene_space(vec3(current_voxel) + 0.5);
                    result.hit_pos = hit_voxel_scene;

                    // 1. Direct Sun / Moonlight bounce
                    float sun_vis = sample_voxel_sun_shadow(
                        shadow_tex,
                        shadow_mv,
                        shadow_proj,
                        hit_voxel_scene,
                        result.hit_normal,
                        l_dir
                    );
                    float NoL = max(0.0, dot(result.hit_normal, l_dir));
                    // Direct light is already scaled by SUN_I / exposure. The
                    // old 3.0 multiplier double-counted it in the GI bounce.
                    vec3 sun_radiance = direct_sun_color * (sun_vis * NoL);

                    // 2. Skylight bounce (diffuse irradiance from sky hemisphere; 0.0 in caves/interiors)
                    float sky_factor = clamp01(result.hit_normal.y * 0.5 + 0.5);
                    vec3 sky_radiance = sky_ambient_color * (sky_factor * sqr(sample_data.sky_light));

                    // 3. Blocklight bounce (light from torches, lanterns, lamps illuminating this surface)
                    vec3 blocklight_bounce = blocklight_color * (sqr(sample_data.block_light) * blocklight_scale);

                    // 4. Emissive radiance from block itself
                    vec3 emission_radiance = mat.emission;

                    // Organic foliage (leaves & plants): absorb light rather than concentrating it inside canopy
                    vec3 bounce_albedo = mat.albedo;
                    if (sample_data.block_id == 5u || sample_data.block_id == 14u || sample_data.block_id == 2u) {
                        bounce_albedo *= 0.35;
                        blocklight_bounce *= 0.50;
                    }

                    // Split sky/sun-origin radiance from emission/block-light radiance.
                    // The radial point-light field is local and is included in
                    // local_lit so sky leaks can still be gated independently.
                    vec3 bounce_irradiance = blocklight_bounce + sun_radiance + sky_radiance;
                    vec3 bounce_radiance = bounce_albedo * bounce_irradiance * voxel_bounce_rcp_pi;

                    vec3 sky_lit = bounce_albedo * (sun_radiance + sky_radiance) * voxel_bounce_rcp_pi;
                    vec3 local_lit = emission_radiance
                        + bounce_albedo * blocklight_bounce * voxel_bounce_rcp_pi
                        + accumulated_light;
                    float sky_lum = dot(sky_lit, luminance_weights);
                    float local_lum = dot(local_lit, luminance_weights);
                    result.sky_weight = clamp01(sky_lum / max(sky_lum + local_lum, eps));

                    // Combined indirect bounce from the solid hit, tinted by
                    // stained glass transmittance. accumulated_light is added
                    // by the caller so it also appears on sky-miss rays.
                    result.radiance = (
                        emission_radiance + bounce_radiance
                    ) * ray_transmittance;
                    break;
                }
            }
        }

        // Advance DDA strictly one axis per step to prevent diagonal corner slipping
        if (t_max.x < t_max.y) {
            if (t_max.x < t_max.z) {
                mask = vec3(1.0, 0.0, 0.0);
            } else {
                mask = vec3(0.0, 0.0, 1.0);
            }
        } else {
            if (t_max.y < t_max.z) {
                mask = vec3(0.0, 1.0, 0.0);
            } else {
                mask = vec3(0.0, 0.0, 1.0);
            }
        }
        t = next_t;
        t_max += mask * delta_t;
        current_voxel += ivec3(mask * step_dir);
    }

    result.transmittance = ray_transmittance;
    result.accumulated_light = accumulated_light;
    return result;
}

#endif // INCLUDE_LIGHTING_RT_VOXEL_DDA
