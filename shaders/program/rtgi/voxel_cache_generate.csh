/*
--------------------------------------------------------------------------------

  Photon Shader: RT / PT Mode
  program/rtgi/voxel_cache_generate.csh:
  Voxel Irradiance Volume: Ray Generation & Lighting Evaluation Pass.

  Traces 1 ray per air cell through the clipmap voxel scene.
  Solid cells early-exit immediately.
  Hit evaluation: direct sun/moon + voxel emitters + recursive multi-bounce
  from the flipped previous cache. Incoming radiance is projected to directional
  L1 Spherical Harmonics and blended temporally.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
#if RT_CLIPMAP_SIZE == 64
const ivec3 workGroups = ivec3(16, 16, 16);
#elif RT_CLIPMAP_SIZE == 96
const ivec3 workGroups = ivec3(24, 24, 24);
#else
const ivec3 workGroups = ivec3(32, 32, 32);
#endif

layout(rgba16f) writeonly uniform image3D voxel_cache_sh_img;
layout(rgba16f) writeonly uniform image3D voxel_cache_aux_img;

// P6.1 emitter list. Built here, not during voxelization: voxel_update.glsl
// is included by nine different vertex programs, so the image was previously
// written from ~9 passes a frame with unverifiable ordering and clear
// semantics. This pass has exactly one invocation per clipmap cell, so every
// emitter is seen once by construction and no dedup is needed.
#if defined RT_EMITTER_LIST
layout(r32ui) uniform uimage2D emitter_list_img;
#endif

uniform sampler3D voxel_cache_flip_sh_sampler;
uniform sampler3D voxel_cache_flip_aux_sampler;

#include "/include/lighting/rt/voxel_samplers.glsl"
uniform sampler2D shadowtex0;
uniform sampler2D colortex4; // sky map & direct light colors
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

#define VOXEL_CACHE_WRITE_ONLY
#include "/include/lighting/rt/voxel_cache.glsl"

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
    if (any(greaterThanEqual(cell, rt_clipmap_size))) return;

    vec3 cell_scene_pos = rt_clip_origin_scene(0) + vec3(cell) + 0.5;

#if defined RT_EMITTER_LIST
    // Must run before the solid-cell early exit below: an emitter is solid, so
    // placing this after it would skip every emitter in the scene.
    {
        ivec3 list_vx = ivec3(floor(scene_to_voxel_space(cell_scene_pos)));
        if (is_inside_voxel_grid(list_vx)) {
            uint list_packed = texelFetch(voxel_sampler, list_vx, 0).r;
            VoxelSample list_vs = unpack_voxel_data(list_packed);
            if (list_vs.is_emitter && list_vs.shape_class != VOXEL_SHAPE_CUBE) {
                uint slot = imageAtomicAdd(emitter_list_img, rt_emitter_texel(0), 1u);
                if (slot < RT_EMITTER_LIST_CAPACITY) {
                    int base = 1 + int(slot) * 4;
                    imageAtomicExchange(emitter_list_img, rt_emitter_texel(base), uint(cell.x));
                    imageAtomicExchange(emitter_list_img, rt_emitter_texel(base + 1), uint(cell.y));
                    imageAtomicExchange(emitter_list_img, rt_emitter_texel(base + 2), uint(cell.z));
                    imageAtomicExchange(emitter_list_img, rt_emitter_texel(base + 3), list_packed);
                }
            }
        }
    }
#endif

    // Check occupancy: solid cells do not store air irradiance and early-exit immediately
    ivec3 vx_coord = ivec3(floor(scene_to_voxel_space(cell_scene_pos)));
    if (is_inside_voxel_grid(vx_coord)) {
        uint vx_data = texelFetch(voxel_sampler, vx_coord, 0).r;
        VoxelSample vs = unpack_voxel_data(vx_data);
        if (vs.block_id != 0u && vs.shape_class != VOXEL_SHAPE_PLANT) {
            imageStore(voxel_cache_sh_img, cell, vec4(0.0));
            imageStore(voxel_cache_aux_img, cell, vec4(0.0));
            return;
        }
    }

    vec3 direct_light_col = texelFetch(colortex4, ivec2(191, 0), 0).rgb;
    vec3 sky_irradiance_col = texelFetch(colortex4, ivec2(191, 1), 0).rgb;

    // Uniform sphere ray generation using low-discrepancy sequence
    uint seed = uint(cell.x + cell.y * rt_clipmap_dim + cell.z * rt_clipmap_dim * rt_clipmap_dim)
              ^ (uint(frameCounter) * 1664525u + 1013904223u);
    vec2 rand = r2(int(seed & 0x7FFFFFFF), vec2(0.3183, 0.6366));

    float z = rand.x * 2.0 - 1.0;
    float phi = rand.y * tau;
    float r = sqrt(max(0.0, 1.0 - z * z));
    vec3 ray_dir = vec3(r * cos(phi), z, r * sin(phi));

    float dither = rand.x;

    // Trace ray through voxel clipmap DDA
    VoxelHit vx_hit = trace_voxel_dda(
        voxel_sampler,
        voxel_mid_sampler,
        voxel_coarse_sampler,
        cell_scene_pos,
        ray_dir,
        ray_dir,
        dither,
        direct_light_col,
        sky_irradiance_col,
        light_dir,
        rt_scene_max_distance
    );

    vec3 ray_radiance;
    float ray_sky;

    if (vx_hit.hit) {
        ray_radiance = vx_hit.radiance * vx_hit.transmittance + vx_hit.passed_emission;
        ray_sky = vx_hit.sky_weight;

        // Recursive multi-bounce: query previous-frame flipped cache at hit point
#if defined VOXEL_CACHE_MULTIBOUNCE
        vec3 hit_query_pos = vx_hit.hit_pos + vx_hit.hit_normal * 0.2;
        vec3 hit_voxel = scene_to_voxel_space(hit_query_pos);

        if (all(greaterThanEqual(hit_voxel, vec3(0.0))) && all(lessThan(hit_voxel, rt_clipmap_size_f))) {
            ivec3 hit_cell = ivec3(floor(hit_voxel));
            vec4 prev_cache_aux = texelFetch(voxel_cache_flip_aux_sampler, hit_cell, 0);

            if (prev_cache_aux.a >= 0.5) {
                vec4 prev_cache_sh = texelFetch(voxel_cache_flip_sh_sampler, hit_cell, 0);
                float E_Y = project_l1_sh_irradiance(prev_cache_sh, vx_hit.hit_normal);
                float dc_Y = max(1e-4, prev_cache_sh.w * sh_conv0);
                float dir_ratio = clamp(E_Y / dc_Y, 0.15, 2.5);
                vec3 bounce_irr = prev_cache_aux.rgb * dir_ratio;

                // Secondary bounce reflection: radiance = irradiance * albedo / pi
                vec3 bounce_radiance = (bounce_irr * vx_hit.albedo * rcp_pi) * 0.85;
                float prev_sky = fract(prev_cache_aux.a) * (1.0 / 0.99);

                ray_radiance += bounce_radiance * vx_hit.transmittance;
                ray_sky = mix(ray_sky, prev_sky, 0.5);
            }
        }
#endif
    } else {
        ray_radiance = texture(colortex4, project_sky(ray_dir)).rgb
            * vx_hit.transmittance + vx_hit.passed_emission;
        ray_sky = 1.0;
    }

    // Clamp fireflies
    ray_radiance = min(ray_radiance, vec3(16.0));

    // Convert incoming sample to directional L1 Spherical Harmonics
    vec4 new_sh = radiance_to_l1_sh(ray_radiance, ray_dir);

    // Temporal accumulation with reprojected flip cache
    vec4 prev_aux = texelFetch(voxel_cache_flip_aux_sampler, cell, 0);
    vec4 prev_sh = texelFetch(voxel_cache_flip_sh_sampler, cell, 0);

    // How long a cell's history lives. The only thing that ever invalidates a
    // cell is the camera-scroll reprojection, so this is also how long the
    // volume takes to notice that a light was removed: at 128 samples a torch
    // going out faded over ~2 s, and the recursive multi-bounce -- which reads
    // last frame's cache back through the flip images at 0.85 * albedo / pi --
    // stretched the tail to 3-4 s. The volume is spatially filtered every
    // frame (six-neighbour air-constrained blur) and it only feeds the second
    // bounce, so it does not need the deep history the screen-space
    // accumulator does; 24 samples converge in under half a second at the cost
    // of a noisier bounce that the a-trous already smooths.
    const float voxel_cache_history = 24.0;
    float prev_samples = floor(prev_aux.a);
    float new_samples = clamp(prev_samples + 1.0, 1.0, voxel_cache_history);
    float alpha = 1.0 / new_samples;

    vec4 blended_sh = mix(prev_sh, new_sh, alpha);
    vec3 blended_rgb = mix(prev_aux.rgb, ray_radiance, alpha);
    float prev_sky = fract(prev_aux.a) * (1.0 / 0.99);
    float blended_sky = mix(prev_sky, ray_sky, alpha);

    float packed_aux_a = new_samples + clamp01(blended_sky) * 0.99;

    imageStore(voxel_cache_sh_img, cell, blended_sh);
    imageStore(voxel_cache_aux_img, cell, vec4(blended_rgb, packed_aux_a));
}
