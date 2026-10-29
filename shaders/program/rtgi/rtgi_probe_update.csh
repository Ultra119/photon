/*
--------------------------------------------------------------------------------

  Photon Shader: Native Voxel RTGI
  program/rtgi/rtgi_probe_update.csh:
  DDGI Probe Radiance Cache Update - Fixed-Point Multi-Bounce Light Gathering

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(2, 1, 1); // 512 probes updated per frame (full cycle in 64 frames)

#if RTGI_MULTIBOUNCE == RTGI_MULTIBOUNCE_PROBES
layout(rgba16f) uniform image3D ddgi_irradiance_img;
layout(rgba16f) uniform image3D ddgi_direction_img;

uniform sampler3D ddgi_irradiance_sampler;
uniform sampler3D ddgi_direction_sampler;
uniform usampler3D voxel_sampler;
uniform sampler2D shadowtex0;
uniform sampler2D colortex4; // sky map & light colors
uniform sampler2D noisetex;

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 gbufferModelViewInverse;

uniform vec3 cameraPosition;
uniform int frameCounter;
uniform vec3 light_dir;

#include "/include/utility/color.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/space_conversion.glsl"
#include "/include/utility/random.glsl"
#include "/include/lighting/rt/voxel_dda.glsl"
#include "/include/lighting/rt/ddgi.glsl"
#endif

void main() {
#if RTGI_MULTIBOUNCE == RTGI_MULTIBOUNCE_OFF
    return;
#else
    uint thread_id = gl_GlobalInvocationID.x;
    uint probes_per_frame = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    const uint total_probes = uint(ddgi_probe_dim * ddgi_probe_dim * ddgi_probe_dim);
    uint probe_idx = (uint(frameCounter) * probes_per_frame + thread_id) % total_probes;

    // Decode 1D index to 3D grid coordinate (X, Y, Z in [0, 31])
    ivec3 probe_coord;
    probe_coord.z = int(probe_idx / uint(ddgi_probe_dim * ddgi_probe_dim));
    probe_coord.y = int((probe_idx / uint(ddgi_probe_dim)) % uint(ddgi_probe_dim));
    probe_coord.x = int(probe_idx % uint(ddgi_probe_dim));

    vec3 origin = get_ddgi_grid_origin(cameraPosition);
    vec3 probe_world_pos = get_ddgi_probe_world_pos(probe_coord, origin);
    vec3 probe_scene_pos = probe_world_pos - cameraPosition;

    // Direct lighting & ambient colors from colortex4
    vec3 direct_light_col = texelFetch(colortex4, ivec2(191, 0), 0).rgb;
    vec3 sky_amb_col = texelFetch(colortex4, ivec2(191, 1), 0).rgb;

    // Probe relocation: check if probe is inside a solid voxel
    ivec3 vx_coord = ivec3(floor(scene_to_voxel_space(probe_scene_pos)));

    if (is_inside_voxel_grid(vx_coord)) {
        uint vx_data = texelFetch(voxel_sampler, vx_coord, 0).r;
        VoxelSample vs = unpack_voxel_data(vx_data);
        if (vs.block_id != 0u) {
            // Relocate: step in cardinal directions to find nearest open air block
            bool found_air = false;
            const ivec3 offsets[6] = ivec3[6](
                ivec3( 1, 0, 0), ivec3(-1, 0, 0),
                ivec3( 0, 1, 0), ivec3( 0,-1, 0),
                ivec3( 0, 0, 1), ivec3( 0, 0,-1)
            );
            for (int i = 0; i < 6; ++i) {
                ivec3 neighbor_coord = vx_coord + offsets[i];
                if (is_inside_voxel_grid(neighbor_coord)) {
                    uint n_data = texelFetch(voxel_sampler, neighbor_coord, 0).r;
                    VoxelSample n_vs = unpack_voxel_data(n_data);
                    if (n_vs.block_id == 0u) {
                        probe_world_pos += vec3(offsets[i]) * 1.5;
                        probe_scene_pos = probe_world_pos - cameraPosition;
                        found_air = true;
                        break;
                    }
                }
            }
            if (!found_air) {
                // Completely surrounded by solid geometry (deep underground / bedrock)
                imageStore(ddgi_irradiance_img, probe_coord, vec4(0.0));
                imageStore(ddgi_direction_img, probe_coord, vec4(0.0));
                return;
            }
        }
    }

    // Cast probe sample rays across the spherical environment
    const int num_rays = RTGI_PROBE_RAYS;
    vec2 rand_rot = r2(int(probe_idx ^ uint(frameCounter)), vec2(0.3183, 0.6366));

    vec3 accum_irr = vec3(0.0);
    vec3 accum_dir = vec3(0.0);
    float accum_sky = 0.0;

    for (int r = 0; r < num_rays; ++r) {
        vec3 ray_dir = get_ddgi_probe_ray_dir(r, num_rays, rand_rot);
        float dither = float(r) * (1.0 / float(num_rays));

        VoxelHit vx_hit = trace_voxel_dda(
            voxel_sampler,
            shadowtex0,
            shadowModelView,
            shadowProjection,
            probe_scene_pos,
            ray_dir,
            ray_dir,
            dither,
            direct_light_col,
            sky_amb_col,
            light_dir,
            24.0 // 24-meter probe trace reach
        );

        vec3 ray_radiance = vec3(0.0);
        float ray_sky = 0.0;

        if (vx_hit.hit) {
            // Direct reflection + emission at the hit surface
            ray_radiance = vx_hit.radiance + vx_hit.accumulated_light;
            ray_sky = vx_hit.sky_weight;

            // Multi-bounce recursion: query the previous probe cache at the hit position
            // Skip self-probe by passing probe_coord
            vec3 hit_world_pos = vx_hit.hit_pos + cameraPosition;
            vec4 prev_cache = sample_ddgi_irradiance_skip(
                hit_world_pos + vx_hit.hit_normal * 0.15,
                vx_hit.hit_normal,
                cameraPosition,
                probe_coord
            );
            // Diffuse reflected bounce 2+ radiance: L2 = (albedo / pi) * E_cache
            ray_radiance += (vx_hit.albedo * voxel_bounce_rcp_pi) * prev_cache.rgb;
        } else {
            // Ray escaped to the sky
            float sky_hemi = clamp01(ray_dir.y * 0.5 + 0.5);
            ray_radiance = sky_amb_col * sky_hemi * vx_hit.transmittance;
            ray_sky = 1.0;
        }

        // Stability clamp per ray to prevent fireflies / diverging feedback
        ray_radiance = min(ray_radiance, vec3(16.0));

        accum_irr += ray_radiance;
        accum_dir += ray_radiance * ray_dir;
        accum_sky += ray_sky;
    }

    vec3 new_E0 = accum_irr * (1.0 / float(num_rays));
    float total_lum = dot(new_E0, luminance_weights);
    vec3 new_dir = (total_lum > 1e-4) ? (accum_dir / (total_lum * float(num_rays))) : vec3(0.0);
    new_dir = clamp(new_dir, vec3(-1.0), vec3(1.0));
    float new_sky = accum_sky * (1.0 / float(num_rays));

    // Temporal Hysteresis: Exponential Moving Average across frames
    vec4 prev_irr = imageLoad(ddgi_irradiance_img, probe_coord);
    vec4 prev_dir = imageLoad(ddgi_direction_img, probe_coord);

    const float hysteresis = RTGI_PROBE_HYSTERESIS;
    vec3 blended_E0 = clamp(mix(new_E0, prev_irr.rgb, hysteresis), vec3(0.0), vec3(16.0));
    vec3 blended_dir = mix(new_dir, prev_dir.xyz, hysteresis);
    float blended_sky = mix(new_sky, prev_irr.a, hysteresis);

    imageStore(ddgi_irradiance_img, probe_coord, vec4(blended_E0, blended_sky));
    imageStore(ddgi_direction_img, probe_coord, vec4(blended_dir, 1.0));
#endif
}
