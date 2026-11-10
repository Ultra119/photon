#if !defined INCLUDE_LIGHTING_RT_PATH_TRACE
#define INCLUDE_LIGHTING_RT_PATH_TRACE

// Multi-bounce diffuse path tracer for voxel scene geometry.

#include "/include/utility/color.glsl"
#include "/include/utility/geometry.glsl"
#include "/include/utility/random.glsl"
#include "/include/sky/projection.glsl"
#include "voxel_dda.glsl"

#ifndef PT_BOUNCES
#define PT_BOUNCES 2
#endif

#ifndef RTGI_HIT_NONE
#define RTGI_HIT_NONE  0
#define RTGI_HIT_VOXEL 1
#define RTGI_HIT_SKY   2
#endif

#if !defined SAMPLE_COSINE_HEMISPHERE_FN
#define SAMPLE_COSINE_HEMISPHERE_FN
vec3 sample_cosine_hemisphere(vec3 normal, vec2 u) {
    float r = sqrt(u.x);
    float phi = 6.28318530718 * u.y;

    vec3 local_dir = vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.x)));
    mat3 tbn_basis = build_orthonormal_basis(normal);
    return normalize(tbn_basis * local_dir);
}
#endif

// GGX Visible Normal Distribution Function (VNDF) sampling (Heitz 2018 / Zombye 2023)
vec3 sample_ggx_vndf_local(vec3 viewer_dir, vec2 alpha, vec2 hash) {
    viewer_dir = normalize(vec3(alpha * viewer_dir.xy, viewer_dir.z));
    const float tau = 6.28318530718;
    float phi = tau * hash.x;
    float cos_theta = fma(1.0 - hash.y, 1.0 + viewer_dir.z, -viewer_dir.z);
    float sin_theta = sqrt(clamp(1.0 - cos_theta * cos_theta, 0.0, 1.0));
    vec3 reflected = vec3(vec2(cos(phi), sin(phi)) * sin_theta, cos_theta);
    vec3 halfway = reflected + viewer_dir;
    return normalize(vec3(alpha * halfway.xy, halfway.z));
}

vec3 sample_specular_direction(vec3 normal, vec3 viewer_dir, float roughness, vec2 hash) {
    mat3 tbn = build_orthonormal_basis(normal);
    vec3 local_v = transpose(tbn) * viewer_dir;
    float alpha = max(roughness * roughness, 0.002);
    vec3 local_m = sample_ggx_vndf_local(local_v, vec2(alpha), hash);
    vec3 m = tbn * local_m;
    return reflect(-viewer_dir, m);
}

// Evaluates explicit path tracing for one sample ray.
// Returns vec4(radiance, sky_weight) and writes hit_source (RTGI_HIT_*).
vec4 evaluate_path_trace(
    vec3 scene_pos,
    vec3 world_normal,
    vec3 mapped_normal,
    vec2 dither,
    float receiver_skylight,
    usampler3D voxel_grid,
    usampler3D voxel_mid,
    usampler3D voxel_coarse,
    sampler2D sky_map,
    vec3 direct_sun_color,
    vec3 sky_irradiance,
    vec3 l_dir,
    int ray_index,
    out int hit_source
) {
    hit_source = RTGI_HIT_NONE;

#if defined WORLD_OVERWORLD
    // Gated sky access: prevents escaped rays from leaking sky light in caves/interiors
    float sky_access = smoothstep(0.02, 0.08, receiver_skylight);
#else
    float sky_access = 1.0;
#endif

    vec3 L = vec3(0.0);
    vec3 L_sky = vec3(0.0);
    vec3 throughput = vec3(1.0);

    vec2 u0 = r2(ray_index * PT_BOUNCES, dither);

    // Initial ray direction sampled from primary shading normal
    vec3 current_dir = sample_cosine_hemisphere(mapped_normal, u0);
    if (dot(current_dir, world_normal) <= 0.0) {
        current_dir = reflect(current_dir, world_normal);
    }

    vec3 ray_origin = scene_pos;
    vec3 surf_normal = world_normal;
    float current_dither = dither.x;

    for (int b = 0; b < PT_BOUNCES; ++b) {
        VoxelHit hit = trace_voxel_dda(
            voxel_grid,
            voxel_mid,
            voxel_coarse,
            ray_origin,
            surf_normal,
            current_dir,
            current_dither,
            direct_sun_color * sky_access,
            sky_irradiance * sky_access,
            l_dir,
            rt_scene_max_distance
        );

        // Thin-emitter pass-through gathered along this ray segment (torches, lanterns)
        L += hit.passed_emission * throughput;

        if (!hit.hit) {
            // Escaped ray: sample sky dome if receiver has sky access
            vec3 sky_radiance = texture(sky_map, project_sky(current_dir)).rgb
                * (hit.transmittance * sky_access);

            L += sky_radiance * throughput;
            L_sky += sky_radiance * throughput;

            if (b == 0) {
                hit_source = (sky_access > 0.0) ? RTGI_HIT_SKY : RTGI_HIT_NONE;
            }
            break;
        }

        if (b == 0) {
            hit_source = RTGI_HIT_VOXEL;
        }

        // Direct hit radiance: direct sun (with voxel shadow visibility) + solid block emission + bounced sky light
        vec3 hit_rad = hit.radiance;
        vec3 hit_sky = hit_rad * hit.sky_weight;
        vec3 direct_radiance = hit_rad * hit.transmittance;

        L += direct_radiance * throughput;
        L_sky += hit_sky * hit.transmittance * throughput;

        // Path termination at maximum bounces
        if (b == PT_BOUNCES - 1) {
            break;
        }

        // Diffuse continuation throughput
        vec3 continuation_albedo = clamp01(pow(hit.albedo, vec3(0.8)) * 1.35);
        throughput *= continuation_albedo * hit.transmittance;

        // Russian roulette path termination starting at bounce 2
        if (b >= 1) {
            float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 0.95);
            float rr_rand = hash1(vec3(dither, float(ray_index * PT_BOUNCES + b + 17)));
            if (rr_rand > q) {
                break;
            }
            throughput /= q;
        }

        // Next bounce origin and geometric normal
        ray_origin = hit.hit_pos;
        surf_normal = hit.hit_normal;

        // Generate decorrelated direction for next bounce
        vec2 bounce_seed = hash2(vec3(dither, float(ray_index * PT_BOUNCES + b + 1)));
        vec2 next_u = r2(ray_index * PT_BOUNCES + (b + 1), bounce_seed);

#if defined PT_GLOSSY_TRANSPORT
        // Optional glossy bounce on smooth materials (e.g. water, polished surfaces)
        if (hit.albedo.r > 0.0 && next_u.x < 0.2) {
            vec3 viewer_dir = -current_dir;
            current_dir = sample_specular_direction(surf_normal, viewer_dir, 0.2, next_u);
        } else {
            current_dir = sample_cosine_hemisphere(surf_normal, next_u);
        }
#else
        current_dir = sample_cosine_hemisphere(surf_normal, next_u);
#endif

        if (dot(current_dir, surf_normal) <= 0.0) {
            current_dir = reflect(current_dir, surf_normal);
        }
        current_dither = hash1(vec3(dither.yx, float(ray_index * PT_BOUNCES + b + 1)));
    }

    // Numerical safety guard: reject non-finite or negative values
    if (!all(equal(L, L)) || any(lessThan(L, vec3(0.0)))) {
        return vec4(0.0);
    }

    float total_lum = dot(L, luminance_weights);
    float sky_lum = dot(L_sky, luminance_weights);
    float sky_weight = clamp01(sky_lum / max(total_lum, eps));

    return vec4(L, sky_weight);
}

#endif // INCLUDE_LIGHTING_RT_PATH_TRACE
