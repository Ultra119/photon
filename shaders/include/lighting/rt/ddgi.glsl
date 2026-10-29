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

// Active bounding box origin in integer cell units, centered around camera position
ivec3 get_ddgi_min_cell(vec3 cam_pos) {
    return ivec3(floor((cam_pos - vec3(ddgi_grid_extent * 0.5)) * ddgi_rcp_spacing));
}

// World position at the center of probe cell
vec3 get_ddgi_probe_world_pos(ivec3 cell) {
    return (vec3(cell) + 0.5) * ddgi_probe_spacing;
}

// Map any integer world cell coordinate into 3D texture texel coordinate [0..31]^3 via toroidal bitmask
ivec3 get_ddgi_texel_coord(ivec3 cell) {
    return cell & (ddgi_probe_dim - 1);
}

// Grid origin snapped to 4-block steps (retained for backward compatibility)
vec3 get_ddgi_grid_origin(vec3 cam_pos) {
    return vec3(get_ddgi_min_cell(cam_pos)) * ddgi_probe_spacing;
}

// Legacy overload with explicit origin
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

// Relocation offset decoding for probes adjusted away from solid geometry.
// Ensures sampling query calculates exact to_probe vectors and prevents
// backface culling collapse and planar wall seams.
vec3 decode_ddgi_relocation(float code) {
    int idx = int(code + 0.5);
    const vec3 table[13] = vec3[13](
        vec3( 0.0,  0.0,  0.0),
        vec3( 1.5,  0.0,  0.0),
        vec3(-1.5,  0.0,  0.0),
        vec3( 0.0,  1.5,  0.0),
        vec3( 0.0, -1.5,  0.0),
        vec3( 0.0,  0.0,  1.5),
        vec3( 0.0,  0.0, -1.5),
        vec3( 2.5,  0.0,  0.0),
        vec3(-2.5,  0.0,  0.0),
        vec3( 0.0,  2.5,  0.0),
        vec3( 0.0, -2.5,  0.0),
        vec3( 0.0,  0.0,  2.5),
        vec3( 0.0,  0.0, -2.5)
    );
    if (idx >= 1 && idx <= 12) return table[idx];
    return vec3(0.0);
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
    ivec3 min_cell = get_ddgi_min_cell(cam_pos);
    vec3 p_coord = (world_pos - vec3(2.0)) * ddgi_rcp_spacing;
    ivec3 base_cell = ivec3(floor(p_coord));
    vec3 frac_coord = fract(p_coord);

    vec3 accum_irr = vec3(0.0);
    float accum_sky = 0.0;
    float total_weight = 0.0;

    for (int dz = 0; dz <= 1; ++dz) {
        float wz = dz == 1 ? frac_coord.z : (1.0 - frac_coord.z);
        for (int dy = 0; dy <= 1; ++dy) {
            float wy = dy == 1 ? frac_coord.y : (1.0 - frac_coord.y);
            for (int dx = 0; dx <= 1; ++dx) {
                float wx = dx == 1 ? frac_coord.x : (1.0 - frac_coord.x);
                ivec3 probe_c = base_cell + ivec3(dx, dy, dz);

                // Range check against active volume
                ivec3 rel_c = probe_c - min_cell;
                if (any(lessThan(rel_c, ivec3(0))) || any(greaterThanEqual(rel_c, ivec3(ddgi_probe_dim)))) {
                    continue;
                }

                // Skip current updating probe to strictly prevent recursive self-feedback
                if (probe_c == skip_coord) continue;

                ivec3 probe_texel = get_ddgi_texel_coord(probe_c);
                vec4 probe_dir_sample = texelFetch(ddgi_direction_sampler, probe_texel, 0);
                vec3 probe_reloc = decode_ddgi_relocation(probe_dir_sample.w);

                vec3 probe_world_p = get_ddgi_probe_world_pos(probe_c) + probe_reloc;
                vec3 to_probe = probe_world_p - world_pos;
                float normal_dist = dot(normal, to_probe);

                // Normal-distance weighting: probes in front of surface (normal_dist >= 0) are in the same room.
                // Probes behind the surface (normal_dist < 0) smoothly fade out over half a cell to prevent leaks from behind walls.
                // Uses cubic smoothstep to ensure C1 continuity and eliminate planar slope creases.
                float t = clamp01(1.0 + normal_dist * (1.0 / (ddgi_probe_spacing * 0.5)));
                float backface_weight = t * t * (3.0 - 2.0 * t);

                float weight = wx * wy * wz * backface_weight;
                if (weight <= 1e-5) continue;

                vec4 probe_irr_sample = texelFetch(ddgi_irradiance_sampler, probe_texel, 0);

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
