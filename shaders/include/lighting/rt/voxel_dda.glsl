#if !defined INCLUDE_LIGHTING_RT_VOXEL_DDA
#define INCLUDE_LIGHTING_RT_VOXEL_DDA

// global.glsl included by parent program
#include "/include/lighting/voxel/voxel_constants.glsl"
#include "/include/lighting/voxel/voxel_storage.glsl"
#include "/include/lighting/shadows/distortion.glsl"
#include "/include/lighting/colors/blocklight_color.glsl"

struct VoxelHit {
    bool hit;
    vec3 hit_pos;
    vec3 hit_normal;
    vec3 radiance;
    float distance;
    vec3 transmittance;
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
    vec3 direct_sun_color,
    vec3 sky_ambient_color,
    vec3 l_dir,
    float max_dist
) {
    VoxelHit result;
    result.hit = false;
    result.hit_pos = ray_origin_scene + ray_dir * max_dist;
    result.hit_normal = -ray_dir;
    result.radiance = vec3(0.0);
    result.distance = max_dist;
    result.transmittance = vec3(1.0);

    vec3 ray_transmittance = vec3(1.0);

    // Offset ray origin along surface normal and forward to clear starting block boundary
    vec3 start_scene = ray_origin_scene + surface_normal * 0.25 + ray_dir * 0.05;
    vec3 start_voxel = scene_to_voxel_space(start_scene);
    ivec3 current_voxel = ivec3(floor(start_voxel));

    // Voxel containing the origin surface point (must not self-intersect)
    ivec3 origin_voxel = ivec3(floor(scene_to_voxel_space(ray_origin_scene - surface_normal * 0.1)));

    vec3 step_dir = sign(ray_dir);
    vec3 delta_t = abs(1.0 / (ray_dir + vec3(1e-7)));
    vec3 t_max = (step_dir * (vec3(current_voxel) - start_voxel) + step_dir * 0.5 + 0.5) * delta_t;

    vec3 mask = vec3(0.0);
    float t = 0.0;

    const int MAX_STEPS = 80;
    for (int i = 0; i < MAX_STEPS; ++i) {
        if (!is_inside_voxel_grid(current_voxel) || t > max_dist) {
            break;
        }

        // Ignore the origin block to completely eliminate self-intersection
        if (current_voxel != origin_voxel) {
            uvec4 raw = texelFetch(voxel_grid, current_voxel, 0);
            if (raw.r != 0u) {
                // Hit detected!
                VoxelSample sample_data = unpack_voxel_data(raw);
                VoxelMaterial mat = get_voxel_material(sample_data.block_id, sample_data.color);

                // Transparent glass blocks: clear glass passes through, stained glass (81u - 96u) tints transmittance
                if (sample_data.block_id >= 81u && sample_data.block_id <= 96u) {
                    ray_transmittance *= mat.albedo;
                } else if (sample_data.block_id == 80u) {
                    // Clear glass: passes through without tinting
                } else if (mat.is_solid) {
                    result.hit = true;
                    result.hit_normal = (dot(mask, mask) > 0.5) ? (-mask * step_dir) : -sign(ray_dir);
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
                    vec3 sun_radiance = direct_sun_color * (sun_vis * NoL * 3.0);

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

                    // Combined indirect bounce: emission + diffuse bounce of local illumination, tinted by stained glass transmittance
                    result.radiance = (emission_radiance + bounce_albedo * (blocklight_bounce + sun_radiance + sky_radiance)) * ray_transmittance;
                    break;
                }
            }
        }

        // Advance DDA to next boundary
        mask = step(t_max.xyz, min(t_max.yzx, t_max.zxy));
        t = min(min(t_max.x, t_max.y), t_max.z);
        t_max += mask * delta_t;
        current_voxel += ivec3(mask * step_dir);
    }

    result.transmittance = ray_transmittance;
    return result;
}

#endif // INCLUDE_LIGHTING_RT_VOXEL_DDA

