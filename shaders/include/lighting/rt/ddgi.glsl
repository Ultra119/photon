#if !defined INCLUDE_LIGHTING_RT_DDGI
#define INCLUDE_LIGHTING_RT_DDGI

/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI
  include/lighting/rt/ddgi.glsl:
  3D Irradiance Probe Radiance Cache (DDGI) for Multi-Bounce Light Transport

--------------------------------------------------------------------------------
*/

#include "/include/utility/color.glsl"

#define RTGI_MULTIBOUNCE_OFF    0
#define RTGI_MULTIBOUNCE_PROBES 1

#ifndef RTGI_MULTIBOUNCE
#define RTGI_MULTIBOUNCE RTGI_MULTIBOUNCE_PROBES
#endif

// Probe grid configuration:
// 32^3 = 32,768 probes at 4.0m spacing = 128m cubic volume, matching the voxel volume extent.
const int   ddgi_probe_dim     = 32;
const float ddgi_probe_spacing = 4.0;
const float ddgi_grid_extent   = float(ddgi_probe_dim) * ddgi_probe_spacing; // 128.0m
const float ddgi_rcp_spacing   = 1.0 / ddgi_probe_spacing;

// Grid origin snapped to 4-block steps so probes never slide relative to world blocks.
// Prevents GI swimming / pumping when moving through the world.
vec3 get_ddgi_grid_origin(vec3 cam_pos) {
    return floor((cam_pos - vec3(ddgi_grid_extent * 0.5)) * ddgi_rcp_spacing) * ddgi_probe_spacing;
}

// World position at the center of probe cell (coord)
vec3 get_ddgi_probe_world_pos(ivec3 coord, vec3 origin) {
    return origin + (vec3(coord) + 0.5) * ddgi_probe_spacing;
}

// Spherical distribution of probe sample rays using the Golden Ratio / Fibonacci sphere
vec3 get_ddgi_probe_ray_dir(int ray_idx, int total_rays, vec2 rand_rot) {
    float y = 1.0 - (float(ray_idx) + 0.5) * (2.0 / float(total_rays));
    float radius = sqrt(max(0.0, 1.0 - y * y));
    // Golden angle = pi * (3.0 - sqrt(5.0)) ~ 2.39996323 rad
    float phi = float(ray_idx) * 2.399963229728653 + rand_rot.x * 6.28318530718;
    return vec3(cos(phi) * radius, y, sin(phi) * radius);
}

#if RTGI_MULTIBOUNCE == RTGI_MULTIBOUNCE_PROBES || (defined GI_DEBUG && GI_DEBUG == 10)
uniform sampler3D ddgi_irradiance_sampler;
uniform sampler3D ddgi_direction_sampler;
#endif

// Query the multi-bounce probe radiance cache at arbitrary world position and surface normal.
// Trilinear interpolation over 8 surrounding probes with backface culling to prevent leaks.
// If skip_coord >= 0, skips the probe that is currently updating to avoid self-feedback.
vec4 sample_ddgi_irradiance_skip(
    vec3 world_pos,
    vec3 normal,
    vec3 cam_pos,
    ivec3 skip_coord
) {
#if RTGI_MULTIBOUNCE == RTGI_MULTIBOUNCE_OFF && (!defined GI_DEBUG || GI_DEBUG != 10)
    return vec4(0.0);
#else
    vec3 origin = get_ddgi_grid_origin(cam_pos);
    vec3 rel_pos = (world_pos - origin) * ddgi_rcp_spacing - vec3(0.5);

    // If outside the active probe grid, return 0 (falls back to sky / direct)
    if (any(lessThan(rel_pos, vec3(0.0))) || any(greaterThanEqual(rel_pos, vec3(float(ddgi_probe_dim - 1))))) {
        return vec4(0.0);
    }

    ivec3 base_coord = ivec3(floor(rel_pos));
    vec3 frac_coord = fract(rel_pos);

    vec3 accum_irr = vec3(0.0);
    float accum_sky = 0.0;
    float total_weight = 0.0;

    for (int dz = 0; dz <= 1; ++dz) {
        float wz = dz == 1 ? frac_coord.z : (1.0 - frac_coord.z);
        for (int dy = 0; dy <= 1; ++dy) {
            float wy = dy == 1 ? frac_coord.y : (1.0 - frac_coord.y);
            for (int dx = 0; dx <= 1; ++dx) {
                float wx = dx == 1 ? frac_coord.x : (1.0 - frac_coord.x);
                ivec3 probe_c = base_coord + ivec3(dx, dy, dz);

                // Skip current updating probe to strictly prevent recursive self-feedback
                if (probe_c == skip_coord) continue;

                vec3 probe_world_p = get_ddgi_probe_world_pos(probe_c, origin);
                vec3 to_probe = probe_world_p - world_pos;
                float dist_to_probe = length(to_probe);
                vec3 dir_to_probe = to_probe / max(dist_to_probe, 1e-4);

                // Backface culling: if the probe lies on the back side of the receiving surface,
                // smoothly fade its weight to 0. This prevents light on the outside of walls/roofs
                // from leaking into interior rooms.
                float backface_dot = dot(normal, dir_to_probe);
                float backface_weight = clamp01((backface_dot + 0.05) * (1.0 / 0.25));

                float weight = wx * wy * wz * backface_weight;
                if (weight <= 1e-5) continue;

                vec4 probe_irr_sample = texelFetch(ddgi_irradiance_sampler, probe_c, 0);
                vec4 probe_dir_sample = texelFetch(ddgi_direction_sampler, probe_c, 0);

                // Directional irradiance response based on dominant incident direction:
                // Normalizes smoothly between [0.1, 2.0] for physical stability.
                float dir_factor = clamp(1.0 + dot(normal, probe_dir_sample.xyz), 0.1, 2.0);
                vec3 probe_radiance = probe_irr_sample.rgb * dir_factor;

                accum_irr += probe_radiance * weight;
                accum_sky += probe_irr_sample.a * weight;
                total_weight += weight;
            }
        }
    }

    if (total_weight > 1e-4) {
        float inv_w = 1.0 / total_weight;
        return vec4(accum_irr * inv_w, clamp01(accum_sky * inv_w));
    }

    return vec4(0.0);
#endif
}

vec4 sample_ddgi_irradiance(
    vec3 world_pos,
    vec3 normal,
    vec3 cam_pos
) {
    return sample_ddgi_irradiance_skip(world_pos, normal, cam_pos, ivec3(-1));
}

#endif // INCLUDE_LIGHTING_RT_DDGI
