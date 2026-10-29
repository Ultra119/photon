#if !defined INCLUDE_LIGHTING_RT_RAY_QUERY
#define INCLUDE_LIGHTING_RT_RAY_QUERY

/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI + SSGI Hybrid
  include/lighting/rt/ray_query.glsl:
  Ray Query Abstraction & Radiometric Energy Accounting Specifications

--------------------------------------------------------------------------------

  RADIOMETRIC CONVENTIONS & ENERGY ACCOUNTING AUDIT (Stage 6):
  =============================================================

  1. Incident Irradiance vs Outgoing Radiance:
     - Outgoing Radiance L_o(p, omega_o) has units [W * sr^-1 * m^-2] (or [lux/sr]).
     - Incident Irradiance E(p) has units [W * m^-2] (or [lux]).
     - For an ideal Lambertian diffuse reflector with albedo rho:
         f_r(p, omega_i, omega_o) = rho / pi
         L_o(p, omega_o) = (rho / pi) * integral_{Omega} L_i(p, omega_i) * (n . omega_i) d_omega_i
                         = (rho / pi) * E_incident

  2. Monte Carlo Estimator for Diffuse Indirect Lighting:
     - Rays are sampled with a cosine-weighted hemisphere distribution:
         p(omega_i) = (n . omega_i) / pi
     - The Monte Carlo estimate of incident irradiance over N cosine samples is:
         <E> = (1/N) * sum_{k=1}^N [ L_i(omega_k) * (n . omega_k) / p(omega_k) ]
             = (1/N) * sum_{k=1}^N [ L_i(omega_k) * (n . omega_k) / ((n . omega_k) / pi) ]
             = pi * (1/N) * sum_{k=1}^N L_i(omega_k)
             = pi * L_mean
     - Therefore:
         E_indirect = pi * L_mean
     - Outgoing reflected radiance at the receiver surface is:
         L_o,indirect = (rho / pi) * E_indirect
                      = (rho / pi) * (pi * L_mean)
                      = rho * L_mean
     - The pi in the cosine PDF and the 1/pi in the Lambertian BRDF cancel exactly.
     - diffuse_lighting.glsl converts incoming radiance L_mean to irradiance via
       `rtgi_indirect * (pi * RTGI_INTENSITY)`. When final_diffuse scales by
       `material.albedo * rcp_pi`, energy is strictly conserved.

  3. Hit Surface Bounces (Single-Bounce Accounting):
     - Direct Sun Irradiance: E_sun = direct_sun_color * (sun_vis * NoL).
     - Hit Reflected Radiance: L_o,sun = bounce_albedo * E_sun * (1 / pi).
       (Scaled by voxel_bounce_rcp_pi = 0.31830988618 in voxel_dda.glsl).
     - Emitter Radiance: L_e = mat.emission.
       Emission is already defined as radiant exitance / radiance; it must NOT
       be divided by pi.
     - Outgoing hit radiance returned to the ray:
         L_hit = L_e + L_o,sun
     - Stained glass transmittance attenuates radiance along the ray:
         L_returned = L_hit * ray_transmittance

--------------------------------------------------------------------------------
*/

#include "voxel_dda.glsl"

// Unified Ray Hit Structure
struct RayHit {
    bool   hit;           // Whether an opaque/sub-box surface was intersected
    vec3   position;      // World-relative scene position of the hit
    vec3   normal;        // Analytic geometric normal of the hit sub-box face
    vec3   albedo;        // Surface albedo of the hit block
    vec3   emission;      // Intrinsic emissive radiance (NOT divided by pi)
    float  distance;      // Ray distance traveled to hit
    vec3   transmittance; // Accumulated transmittance through tinted glass
    uint   block_id;      // Hit block ID
    uint   shape;         // Shape class (cube, slab, stair, fence/pane)
    vec3   radiance;      // Total outgoing radiance (emission + 1st bounce)
    float  sky_weight;    // Fraction of radiance originating from sun/sky
};

// Unified ray trace query: wraps voxel DDA traversal
RayHit trace_ray(
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
    VoxelHit v = trace_voxel_dda(
        voxel_grid,
        shadow_tex,
        shadow_mv,
        shadow_proj,
        ray_origin_scene,
        surface_normal,
        ray_dir,
        dither,
        direct_sun_color,
        sky_ambient_color,
        l_dir,
        max_dist
    );

    RayHit r;
    r.hit = v.hit;
    r.position = v.hit_pos;
    r.normal = v.hit_normal;
    r.distance = v.distance;
    r.transmittance = v.transmittance;
    r.radiance = v.radiance;
    r.sky_weight = v.sky_weight;
    r.albedo = v.albedo;
    r.emission = v.accumulated_light;
    r.block_id = 0u;
    r.shape = 0u;

    return r;
}

#endif // INCLUDE_LIGHTING_RT_RAY_QUERY

