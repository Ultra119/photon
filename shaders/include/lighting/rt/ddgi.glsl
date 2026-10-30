#if !defined INCLUDE_LIGHTING_RT_DDGI
#define INCLUDE_LIGHTING_RT_DDGI

/*
--------------------------------------------------------------------------------

  Photon Shader: RT Mode
  include/lighting/rt/ddgi.glsl:
  Toroidal world-space irradiance probe cache.

  The cache stores diffuse irradiance gathered from voxel-traced direct sun,
  sky misses, and emissive surfaces. It is intentionally not read back inside
  the probe-update dispatch: Iris only guarantees a barrier between compute
  passes, not between invocations of one dispatch. RTGI rays add the cached
  irradiance at their hit surface, giving a second transport bounce without
  same-dispatch feedback.

--------------------------------------------------------------------------------
*/

#include "/include/utility/color.glsl"

const int   ddgi_probe_dim     = 32;
const float ddgi_probe_spacing = 4.0;
const float ddgi_grid_extent   = float(ddgi_probe_dim) * ddgi_probe_spacing;
const float ddgi_rcp_spacing   = 1.0 / ddgi_probe_spacing;

ivec3 get_ddgi_min_cell(vec3 cam_pos) {
    return ivec3(floor((cam_pos - vec3(ddgi_grid_extent * 0.5)) * ddgi_rcp_spacing));
}

vec3 get_ddgi_probe_world_pos(ivec3 cell) {
    return (vec3(cell) + 0.5) * ddgi_probe_spacing;
}

ivec3 get_ddgi_texel_coord(ivec3 cell) {
    return cell & (ddgi_probe_dim - 1);
}

vec3 get_ddgi_grid_origin(vec3 cam_pos) {
    return vec3(get_ddgi_min_cell(cam_pos)) * ddgi_probe_spacing;
}

vec3 get_ddgi_probe_world_pos(ivec3 coord, vec3 origin) {
    return origin + (vec3(coord) + 0.5) * ddgi_probe_spacing;
}

vec3 get_ddgi_probe_ray_dir(int ray_idx, int total_rays, vec2 rand_rot) {
    float y = 1.0 - (float(ray_idx) + 0.5) * (2.0 / float(total_rays));
    float radius = sqrt(max(0.0, 1.0 - y * y));
    float phi = float(ray_idx) * 2.399963229728653 + rand_rot.x * 6.28318530718;
    return vec3(cos(phi) * radius, y, sin(phi) * radius);
}

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

#ifndef DDGI_WRITE_ONLY
uniform sampler3D ddgi_irradiance_sampler;
uniform sampler3D ddgi_direction_sampler;
uniform isampler3D ddgi_cell_sampler;
#endif

#ifndef DDGI_WRITE_ONLY
// Returns diffuse irradiance (RGB) and sky-origin fraction (A).
// Probes whose stored world cell no longer matches the toroidal slot are
// invalid: this is the scroll-invalidation guard for the moving grid.
vec4 sample_ddgi_irradiance(
    vec3 world_pos,
    vec3 normal,
    vec3 cam_pos
) {
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

                ivec3 rel_c = probe_c - min_cell;
                if (any(lessThan(rel_c, ivec3(0))) || any(greaterThanEqual(rel_c, ivec3(ddgi_probe_dim)))) {
                    continue;
                }

                ivec3 probe_texel = get_ddgi_texel_coord(probe_c);
                ivec4 cell_data = texelFetch(ddgi_cell_sampler, probe_texel, 0);
                if (cell_data.w <= 0 || any(notEqual(cell_data.xyz, probe_c))) {
                    continue;
                }

                vec4 probe_dir_sample = texelFetch(ddgi_direction_sampler, probe_texel, 0);
                vec3 probe_reloc = decode_ddgi_relocation(probe_dir_sample.w);

                vec3 probe_world_p = get_ddgi_probe_world_pos(probe_c) + probe_reloc;
                vec3 to_probe = probe_world_p - world_pos;
                float normal_dist = dot(normal, to_probe);

                float t = clamp01(1.0 + normal_dist * (1.0 / (ddgi_probe_spacing * 0.5)));
                float backface_weight = t * t * (3.0 - 2.0 * t);

                float weight = wx * wy * wz * backface_weight;
                if (weight <= 1e-5) continue;

#ifdef DDGI_QUERY_OCCLUSION
                // Reject probes whose segment to the receiver crosses a solid
                // fine-level voxel. Without this, a probe on the other side of
                // a 1-block wall still has positive normal-distance for floor
                // and ceiling receivers, so trilinear blending drags its
                // colour through the wall — the room-corner "backlight" leak.
                // Only meaningfully weighted probes pay for the test.
                if (weight > 0.02) {
                    float seg_len = length(to_probe);
                    if (seg_len > 1e-3
                        && trace_any_hit(
                            voxel_sampler, world_pos - cam_pos, normal,
                            to_probe / seg_len, seg_len
                        )) {
                        continue;
                    }
                }
#endif

                vec4 probe_irr_sample = texelFetch(ddgi_irradiance_sampler, probe_texel, 0);
                // Isotropic probe irradiance. A per-probe mean-direction
                // fudge factor (1 + dot(n, dir)) created 20x brightness
                // swings and axis-aligned seams on the probe grid; real
                // directionality comes from the per-pixel path trace.
                vec3 probe_irradiance = probe_irr_sample.rgb;

                accum_irr += probe_irradiance * weight;
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
}
#endif // DDGI_WRITE_ONLY

#endif // INCLUDE_LIGHTING_RT_DDGI
