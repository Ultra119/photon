/*
--------------------------------------------------------------------------------

  Photon Shader: RT Mode
  program/rtgi/rtgi_probe_update.csh:
  Toroidal DDGI-style irradiance probe update.

  This pass only writes the probe cache. It does not sample the cache being
  written, because Iris barriers are inter-dispatch, not intra-dispatch.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(8, 1, 1); // 2048 probes/frame, 16-frame full cycle

layout(rgba16f) uniform image3D ddgi_irradiance_img;
layout(rgba16f) uniform image3D ddgi_direction_img;
layout(rgba32i) uniform iimage3D ddgi_cell_img;

uniform usampler3D voxel_sampler;
uniform usampler3D voxel_mid_sampler;
uniform usampler3D voxel_coarse_sampler;
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
uniform float near;
uniform float far;

#include "/include/utility/color.glsl"
#include "/include/utility/random.glsl"
#include "/include/sky/projection.glsl"
#include "/include/lighting/rt/voxel_dda.glsl"
#define DDGI_WRITE_ONLY
#include "/include/lighting/rt/ddgi.glsl"

void main() {
    uint thread_id = gl_GlobalInvocationID.x;
    uint probes_per_frame = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    const uint total_probes = uint(ddgi_probe_dim * ddgi_probe_dim * ddgi_probe_dim);
    uint probe_idx = (uint(frameCounter) * probes_per_frame + thread_id) % total_probes;

    ivec3 offset;
    offset.z = int(probe_idx / uint(ddgi_probe_dim * ddgi_probe_dim));
    offset.y = int((probe_idx / uint(ddgi_probe_dim)) % uint(ddgi_probe_dim));
    offset.x = int(probe_idx % uint(ddgi_probe_dim));

    ivec3 min_cell = get_ddgi_min_cell(cameraPosition);
    ivec3 probe_cell = min_cell + offset;
    ivec3 probe_texel = get_ddgi_texel_coord(probe_cell);

    vec3 probe_world_pos = get_ddgi_probe_world_pos(probe_cell);
    vec3 probe_scene_pos = probe_world_pos - cameraPosition;

    vec3 direct_light_col = texelFetch(colortex4, ivec2(191, 0), 0).rgb;

    // Relocate probes that landed inside solid geometry.
    ivec3 vx_coord = ivec3(floor(scene_to_voxel_space(probe_scene_pos)));
    float relocation_code = 0.0;

    if (is_inside_voxel_grid(vx_coord)) {
        uint vx_data = texelFetch(voxel_sampler, vx_coord, 0).r;
        VoxelSample vs = unpack_voxel_data(vx_data);
        if (vs.block_id != 0u) {
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
                        relocation_code = float(i + 1);
                        found_air = true;
                        break;
                    }
                }
            }

            if (!found_air) {
                for (int i = 0; i < 6; ++i) {
                    ivec3 neighbor_coord = vx_coord + offsets[i] * 2;
                    if (is_inside_voxel_grid(neighbor_coord)) {
                        uint n_data = texelFetch(voxel_sampler, neighbor_coord, 0).r;
                        VoxelSample n_vs = unpack_voxel_data(n_data);
                        if (n_vs.block_id == 0u) {
                            probe_world_pos += vec3(offsets[i]) * 2.5;
                            probe_scene_pos = probe_world_pos - cameraPosition;
                            relocation_code = float(i + 7);
                            found_air = true;
                            break;
                        }
                    }
                }
            }

            if (!found_air) {
                imageStore(ddgi_irradiance_img, probe_texel, vec4(0.0));
                imageStore(ddgi_direction_img, probe_texel, vec4(0.0));
                imageStore(ddgi_cell_img, probe_texel, ivec4(probe_cell, 0));
                return;
            }
        }
    }

    const int num_rays = RTGI_PROBE_RAYS;
    vec2 rand_rot = r2(int(probe_idx ^ uint(frameCounter)), vec2(0.3183, 0.6366));

    vec3 accum_radiance = vec3(0.0);
    vec3 accum_dir = vec3(0.0);
    float accum_sky = 0.0;

    for (int r = 0; r < num_rays; ++r) {
        vec3 ray_dir = get_ddgi_probe_ray_dir(r, num_rays, rand_rot);
        float dither = float(r) * (1.0 / float(num_rays));

        VoxelHit vx_hit = trace_voxel_dda(
            voxel_sampler,
            voxel_mid_sampler,
            voxel_coarse_sampler,
            probe_scene_pos,
            ray_dir,
            ray_dir,
            dither,
            direct_light_col,
            light_dir,
            48.0
        );

        vec3 ray_radiance;
        float ray_sky;

        if (vx_hit.hit) {
            ray_radiance = vx_hit.radiance * vx_hit.transmittance;
            ray_sky = vx_hit.sky_weight;
        } else {
            ray_radiance = texture(colortex4, project_sky(ray_dir)).rgb
                * vx_hit.transmittance;
            ray_sky = 1.0;
        }

        ray_radiance = min(ray_radiance, vec3(16.0));

        accum_radiance += ray_radiance;
        accum_dir += ray_radiance * ray_dir;
        accum_sky += ray_sky;
    }

    // Uniform sphere average radiance -> approximate diffuse irradiance.
    vec3 new_E0 = accum_radiance * (pi / float(num_rays));
    float total_lum = dot(accum_radiance, luminance_weights);
    vec3 new_dir = (total_lum > 1e-4)
        ? (accum_dir / total_lum)
        : vec3(0.0);
    new_dir = clamp(new_dir, vec3(-1.0), vec3(1.0));
    float new_sky = accum_sky * (1.0 / float(num_rays));

    // Scroll invalidation: if this toroidal slot previously belonged to a
    // different world cell, do not blend stale history into the new cell.
    ivec4 prev_cell = imageLoad(ddgi_cell_img, probe_texel);
    bool cell_valid = prev_cell.w > 0 && all(equal(prev_cell.xyz, probe_cell));
    float hysteresis = cell_valid ? RTGI_PROBE_HYSTERESIS : 0.0;

    vec4 prev_irr = imageLoad(ddgi_irradiance_img, probe_texel);
    vec4 prev_dir = imageLoad(ddgi_direction_img, probe_texel);

    vec3 blended_E0 = clamp(mix(new_E0, prev_irr.rgb, hysteresis), vec3(0.0), vec3(64.0));
    vec3 blended_dir = mix(new_dir, prev_dir.xyz, hysteresis);
    float blended_sky = mix(new_sky, prev_irr.a, hysteresis);

    imageStore(ddgi_irradiance_img, probe_texel, vec4(blended_E0, blended_sky));
    imageStore(ddgi_direction_img, probe_texel, vec4(blended_dir, relocation_code));
    imageStore(ddgi_cell_img, probe_texel, ivec4(probe_cell, 1));
}
