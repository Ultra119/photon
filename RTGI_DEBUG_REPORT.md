# Comprehensive Diagnostic & Bug Report: RTGI & Added Photonics Features
**Project:** Photon Shader Fork (`shaders/photon`)  
**Date of Audit:** October 29, 2026  
**Test Environment:** Minecraft 26.3, Iris Shader Pipeline, Viewfinder MCP Server (`dev.xirreal.viewfinder`), World `PTGISM` (Overworld)  
**Verification Method:** 100% In-Game GPU Verification & Framebuffer Diagnostics via Viewfinder MCP. (Zero CPU/Python mock testing per project guidelines).

---

## 1. Executive Summary & Scope of Audit

This audit evaluates all features, stages, and architectural additions implemented in the Photon shader fork, spanning Stages 1 through 8 of the Ray-Traced Global Illumination (RTGI) and photonics pipeline. 

Testing was performed directly against the live OpenGL GPU pipeline in Minecraft 26.3 using the `minecraft-viewfinder` MCP server and in-game frame captures. All diagnostic views (`GI_DEBUG` 1 through 10), tracing modes (`RTGI_TRACER_VOXEL` vs `RTGI_TRACER_HYBRID`), multi-bounce probe caching (`RTGI_MULTIBOUNCE_PROBES`), SVGF filtering passes, and optical transmission buffers were exercised under live gameplay conditions.

### Policy & Constraint Adherence
- **Strictly Non-Destructive**: In accordance with the prompt directives, **no shader files were modified, patched, or fixed**.
- **No Python/CPU Simulation**: All observations, numbers, and behavior logs originate exclusively from GPU hardware execution and framebuffer inspects.
- **Scope of Coverage**: Multi-pass voxelization, voxel storage packing, analytic AABB DDA raymarching, hybrid SSGI/Voxel dispatch, DDGI probe radiance caching, SVGF temporal moment reconstruction, SVGF à-trous wavelet filtering, specular RT fallback, stained glass transmission, and diagnostic visualization encoders.

---

## 2. Architecture & Pipeline Map of Added Features

The added RTGI framework operates across compute passes and G-buffer vertex/fragment hooks:

```mermaid
flowchart TD
    subgraph Scene Voxelization
        S_VSH["shadow.vsh / shadow_water.vsh"] -->|imageAtomicMax| VX_IMG["voxel_img (R32UI 3D Volume)"]
        G_VSH["gbuffers_all_solid.vsh"] -->|imageAtomicMax| VX_IMG
    end

    subgraph DDGI Multi-Bounce Cache
        D_A["deferred_a.csh (rtgi_probe_update)"] -->|Voxel DDA + Prev Cache| PROBE_IRR["ddgi_irradiance_img (RGBA16F 3D)"]
        D_A --> PROBE_DIR["ddgi_direction_img (RGBA16F 3D)"]
    end

    subgraph Primary Indirect Tracing
        VX_IMG --> D1_A["deferred1_a.csh (rtgi_trace)"]
        PROBE_IRR -.->|Multi-Bounce Query| D1_A
        SSGI["trace_screen_space_gi (ssgi.glsl)"] -->|Hybrid MIS| D1_A
        D1_A --> RAW_IMG["rtgi_raw_img (RGBA16F 2D)"]
    end

    subgraph SVGF Denoising Pipeline
        RAW_IMG --> D2_A["deferred2_a.csh (rtgi_temporal)"]
        D2_A -->|Ping-Pong History| HIST_IMG["rtgi_accum_img / rtgi_history_img (RGBA16F)"]
        D2_A -->|Variance Moments| SKY_HIST["rtgi_sky_accum_img / rtgi_sky_history_img (RGBA16F)"]
        HIST_IMG --> D3_A["deferred3_a.csh (rtgi_filter)"]
        SKY_HIST --> D3_A
        D3_A --> FILT_IMG["rtgi_filtered_img (RGBA16F 2D)"]
    end

    subgraph Composition & Fallbacks
        FILT_IMG --> D4_FSH["d4_deferred_shading.fsh (diffuse_lighting.glsl)"]
        VX_IMG -.->|Specular Fallback| REFL["rt_reflections.glsl"]
        GLASS["gbuffers_all_translucent.fsh"] -->|colortex17| C1_FSH["c1_blend_layers.fsh"]
    end
```

### Registered Passes & Attachments:
1. `deferred_a.csh` (`program/rtgi/rtgi_probe_update.csh`): Computes 512 DDGI irradiance probes per frame across a $32^3$ probe volume ($128\text{m}^3$).
2. `deferred1_a.csh` (`program/rtgi/rtgi_trace.csh`): Dispatches 2 primary cosine-weighted hemisphere rays per pixel into screen-space and voxel grid.
3. `deferred2_a.csh` (`program/rtgi/rtgi_temporal.csh`): Reprojects previous frame radiance, performs 3-way disocclusion tests, and accumulates second-order luminance moments ($M_2$).
4. `deferred3_a.csh` (`program/rtgi/rtgi_filter.csh`): Variance-guided edge-avoiding 5x5 à-trous wavelet filter.
5. `d4_deferred_shading.fsh`: Computes direct lighting, writes direct radiance to `colortex18`, and combines indirect diffuse irradiance scaled by $\pi \times \text{RTGI\_INTENSITY}$.
6. `final.fsh`: Resolves post-processing and diagnostic debug views (`GI_DEBUG` 1-10).

---

## 3. In-Game GPU Verification & Diagnostic Views Log

Each diagnostic view was activated in the live engine via `set_shader_options` and recorded via Viewfinder GPU frame captures.

| Option Value | Name | Swatch Color | Observed Visual Behavior | Verification Status |
| :--- | :--- | :--- | :--- | :--- |
| `GI_DEBUG = 1` | `GI_DEBUG_VOXEL_ID` | Cyan | Solid geometry rendered with palette colors. Stained glass rendered 100% black (air). Geometry behind glass was penetrated. | **Verified (Defect detected)** |
| `GI_DEBUG = 2` | `GI_DEBUG_VOXEL_LIGHT` | Yellow | Emissive sources (torches, lanterns) rendered with vivid emission. Non-emitter surfaces rendered 100% pitch black across the entire view. | **Verified (Defect detected)** |
| `GI_DEBUG = 3` | `GI_DEBUG_VOXEL_ALBEDO` | Grey | All solid walls, floors, and ceilings rendered as flat 100% pure white (`#FFFFFF`). No diffuse block texture color was visible. | **Verified (Defect detected)** |
| `GI_DEBUG = 4` | `GI_DEBUG_RAW` | Orange | Raw 2-ray Monte Carlo noisy radiance. Distinct diagonal persistent firefly dots along room corner floor seams. | **Verified (Defect detected)** |
| `GI_DEBUG = 5` | `GI_DEBUG_HISTORY` | Cyan-Blue | Temporally accumulated radiance. Firefly dots along room corners persist across hundreds of frames without decay. | **Verified (Defect detected)** |
| `GI_DEBUG = 6` | `GI_DEBUG_FILTERED` | Green | Smooth denoised diffuse irradiance with geometric edges preserved. Fireflies smeared into irregular bright blur patches. | **Verified (Defect detected)** |
| `GI_DEBUG = 7` | `GI_DEBUG_HIT` | Magenta | Under `RTGI_TRACER_VOXEL`: 100% green (all rays resolved by Voxel DDA). Under `RTGI_TRACER_HYBRID`: Red (SSGI) up-close, Green (Voxel) at distance and occlusions. | **Verified** |
| `GI_DEBUG = 8` | `GI_DEBUG_REJECT` | White | Yellow throughout static scenes (history accepted). Crisp red edges during camera rotation/movement (disocclusion rejection). | **Verified** |
| `GI_DEBUG = 9` | `GI_DEBUG_VARIANCE` | Red-Orange | Deep blue across flat converged surfaces. Bright orange/red variance streak corresponding exactly to the corner firefly seam. | **Verified (Defect detected)** |
| `GI_DEBUG = 10`| `GI_DEBUG_PROBE` | Magenta-Pink | 3D probe cache irradiance reconstruction. Distinct circular/spherical scallops on flat planar walls; slow 15-30s convergence lag. | **Verified (Defect detected)** |

---

## 4. Exhaustive Defect & Bug Catalog

### Bug 1: Voxel Albedo Palette Mismatch & White Solid Block RTGI Bounces
- **Source Files**: 
  - [`voxel_update.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/voxel/voxel_update.glsl#L128)
  - [`shadow.vsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/shadow.vsh#L89)
  - [`gbuffers_all_solid.vsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/gbuffers_all_solid.vsh#L112)
- **Code Reference**:
  ```glsl
  // voxel_update.glsl line 128:
  vec3 voxel_albedo = is_emitter ? get_voxel_light_color(block_id) : vertex_tint;
  ```
- **Root Cause**:
  In Minecraft, `gl_Color.rgb` (`vertex_tint` / `tint`) only conveys biome colorization for biome-tinted blocks (grass, leaves, water). For all standard solid blocks (stone, cobblestone, wood planks, concrete, bricks, terracotta, sand, wool), `gl_Color.rgb` is hardcoded by the vanilla engine to `vec3(1.0, 1.0, 1.0)`. 
  `update_rt_voxel_grid()` packs `voxel_albedo` directly into the 15-bit RGB555 field of `voxel_img`. Because `vertex_tint` is `(1.0, 1.0, 1.0)`, every non-biome solid block stores maximum white albedo.
- **Symptom & Visual Evidence**:
  In `GI_DEBUG_VOXEL_ALBEDO`, every single solid wall, ceiling, and floor renders as pure, untextured white (`vec3(1.0)`). During diffuse ray tracing, secondary bounces off colored walls (e.g. Red terracotta or oak planks) reflect uncolored white light rather than the material's actual diffuse color.

---

### Bug 2: Missing Translucent / Stained Glass Voxelization in G-Buffers
- **Source Files**: 
  - [`gbuffers_all_translucent.vsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/gbuffers_all_translucent.vsh#L1-L80)
  - [`voxel_update.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/voxel/voxel_update.glsl#L82-L91)
- **Code Reference**:
  ```glsl
  // voxel_update.glsl lines 88-91:
  bool is_stained_glass = (block_id >= 81u && block_id <= 96u);
  return (!is_non_solid || is_emitter || is_stained_glass)
      && !is_transparent_block
      && is_voxel_terrain_stage();
  ```
- **Root Cause**:
  `should_voxelize()` explicitly accommodates stained glass (`block_id >= 81u && block_id <= 96u`). However, `update_rt_voxel_grid()` is only invoked inside [`gbuffers_all_solid.vsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/gbuffers_all_solid.vsh#L117) and [`shadow.vsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/shadow.vsh#L92). It is **completely absent** from [`gbuffers_all_translucent.vsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/gbuffers_all_translucent.vsh) (which does not even bind `voxel_img`).
- **Symptom & Visual Evidence**:
  Stained glass is never voxelized during the G-buffer pass. If shadows are disabled (`SHADOW = false`) or if the glass falls outside the shadow cascade frustum, stained glass blocks are completely absent from `voxel_img` (registered as empty air `block_id == 0`). In `GI_DEBUG_VOXEL_ID`, stained glass blocks render pitch black.

---

### Bug 3: Translucent Penetration in Voxel Diagnostic Views
- **Source Files**:
  - [`gi_debug.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/debug/gi_debug.glsl#L251-L255)
- **Code Reference**:
  ```glsl
  // gi_debug.glsl line 252:
  ivec2 depth_texel = ivec2(taau_framebuffer_uv(uv) * view_res);
  float depth = texelFetch(depthtex1, depth_texel, 0).x;
  if (depth >= 1.0) {
      return vec3(0.0); // sky
  }
  ```
- **Root Cause**:
  All voxel diagnostic views (`GI_DEBUG_VOXEL_ID`, `GI_DEBUG_VOXEL_LIGHT`, `GI_DEBUG_VOXEL_ALBEDO`, `GI_DEBUG_PROBE`) reconstruct the world-space inspection position from `depthtex1`. In the Iris pipeline, `depthtex1` is the opaque solid depth buffer; translucent geometry (glass, water, ice) is only written to `depthtex0`.
- **Symptom & Visual Evidence**:
  When the player looks at a stained glass pane or water surface, the diagnostic ray punches straight through the translucent surface and reads the voxel of whatever solid block (or sky void) lies behind it, preventing visual inspection of translucent voxels in-game.

---

### Bug 4: Pitch-Black Non-Emitter Voxel Light Diagnostic View
- **Source Files**:
  - [`gi_debug.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/debug/gi_debug.glsl#L62-L68)
  - [`voxel_update.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/voxel/voxel_update.glsl#L129-L133)
  - [`voxel_storage.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/voxel/voxel_storage.glsl#L73-L74)
- **Code Reference**:
  ```glsl
  // gi_debug.glsl lines 64-67:
  if (voxel.is_emitter) {
      return max(voxel.color, vec3(0.2)) * 2.0;
  }
  return vec3(voxel.block_light, voxel.sky_light, 0.0);

  // voxel_update.glsl line 133:
  float voxel_block_light = is_emitter ? 1.0 : 0.0;
  ```
- **Root Cause**:
  To prevent light leakage from roof-mounted torches into dark rooms below, commit `6eb88b9` disabled packing vanilla block light into solid voxels (`voxel_block_light = is_emitter ? 1.0 : 0.0`). Additionally, `voxel.sky_light` is hardcoded to `0.0` in `unpack_voxel_data`. 
- **Symptom & Visual Evidence**:
  For all non-emissive blocks, `voxel.block_light == 0.0` and `voxel.sky_light == 0.0`. In `GI_DEBUG_VOXEL_LIGHT`, every non-emitter surface renders 100% pitch black, making the light diagnostic view completely uninformative in non-emissive environments.

---

### Bug 5: Persistent Firefly Clusters & Smearing in SVGF Filter
- **Source Files**:
  - [`rtgi_temporal.csh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/rtgi/rtgi_temporal.csh#L124-L141)
  - [`rtgi_filter.csh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/rtgi/rtgi_filter.csh#L126-L128)
  - [`rtgi_trace.csh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/rtgi/rtgi_trace.csh#L201-L208)
- **Code Reference**:
  ```glsl
  // rtgi_temporal.csh lines 139-140:
  vec3 clamp_box_min = max(vec3(0.0), raw_m1 - raw_sigma * 1.25);
  vec3 clamp_box_max = raw_m1 + raw_sigma * 1.25;

  // rtgi_filter.csh line 127:
  float sigma_l = 4.0 * center_std + 0.005;
  ```
- **Root Cause**:
  At geometric interior floor seams, grazing rays occasionally penetrate sub-block seams or sample extreme specular/sunlight radiance spikes. While `rtgi_trace.csh` caps single rays at `RTGI_MAX_RADIANCE = 64.0`, a 64.0 spike in a 2-ray budget creates severe variance. In `rtgi_temporal.csh`, the 3x3 variance bounding box expands drastically ($M_1 + 1.25\sigma$), allowing high firefly radiance to enter `accumulated_radiance` and driving $M_2$ to extreme values. 
  In `rtgi_filter.csh`, `sigma_l` scales directly with `center_std`. When `center_std` is blown out by a firefly, `sigma_l` becomes huge, causing the edge-avoiding filter to treat the firefly as valid signal and blurring it into adjacent pixels.
- **Symptom & Visual Evidence**:
  In `GI_DEBUG_RAW` and `GI_DEBUG_HISTORY`, persistent high-luminance white fireflies align diagonally along room corner seams. In `GI_DEBUG_VARIANCE`, these pixels show extreme red variance. In `GI_DEBUG_FILTERED`, they form large, blurry, bright splotches.

---

### Bug 6: DDGI Probe Cache Convergence Latency (15–30 Seconds) & Origin Snapping Artifacts
- **Source Files**:
  - [`rtgi_probe_update.csh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/rtgi/rtgi_probe_update.csh#L13-L15)
  - [`ddgi.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/rt/ddgi.glsl#L25-L35)
  - [`settings.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/settings.glsl#L70)
- **Code Reference**:
  ```glsl
  // rtgi_probe_update.csh line 14:
  const ivec3 workGroups = ivec3(2, 1, 1); // 512 probes updated per frame

  // ddgi.glsl line 25:
  const int ddgi_probe_dim = 32; // 32^3 = 32,768 probes

  // settings.glsl line 70:
  #define RTGI_PROBE_HYSTERESIS 0.85
  ```
- **Root Cause**:
  1. **Convergence Time**: $32,768 \text{ probes} / 512 \text{ probes/frame} = 64 \text{ frames}$ per full grid update cycle. With an exponential moving average hysteresis of 0.85, reaching 90% convergence requires $\approx 14.16$ cycles:
     $$\text{Convergence Frames} = 14.16 \times 64 = 906 \text{ frames}$$
     At 30 FPS, this equals **30.2 seconds**; at 60 FPS, **15.1 seconds**.
  2. **Grid Origin Snapping without Toroidal Scrolling**:
     `get_ddgi_grid_origin()` snaps in discrete 4.0-meter increments (`floor(...) * 4.0`). When the player crosses a 4-meter threshold, the probe origin shifts by 4 meters. However, `ddgi_irradiance_img` is a non-scrolling 3D image; texel $(x, y, z)$ still stores old irradiance data from 4 meters away.
- **Symptom & Visual Evidence**:
  Whenever lighting changes (sun rising, light switched, or moving into a dark cavern), indirect multi-bounce irradiance takes up to 30 seconds to adjust. Moving across 4-meter block boundaries causes probe lighting across rooms and walls to abruptly jump and pop.

---

### Bug 7: Probe Trilinear Normalization Scalloping Artifacts on Planar Surfaces
- **Source Files**:
  - [`ddgi.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/rt/ddgi.glsl#L101-L105)
- **Code Reference**:
  ```glsl
  float backface_dot = dot(normal, dir_to_probe);
  float backface_weight = clamp01((backface_dot + 0.05) * (1.0 / 0.25));
  float weight = wx * wy * wz * backface_weight;
  ...
  float inv_w = 1.0 / total_weight;
  return vec4(accum_irr * inv_w, clamp01(accum_sky * inv_w));
  ```
- **Root Cause**:
  To prevent light leaking through walls, `sample_ddgi_irradiance_skip` aggressively cuts off probes behind the receiver surface (`backface_dot < -0.05`). On flat walls, as the receiver position moves between probe centers, probes behind the wall plane suddenly drop to zero weight. Because the remaining probe weights are normalized by $1 / \text{total\_weight}$, the interpolated irradiance exhibits sharp, circular transitions between probe domains.
- **Symptom & Visual Evidence**:
  In `GI_DEBUG_PROBE`, flat walls display prominent circular, scallop-like light patches rather than smooth continuous irradiance gradients.

---

### Bug 8: Hardcoded Specular RT Fallback Distance Beyond Voxel Boundaries
- **Source Files**:
  - [`rt_reflections.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/rt/rt_reflections.glsl#L22)
  - [`voxel_constants.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/voxel/voxel_constants.glsl#L17)
- **Code Reference**:
  ```glsl
  // rt_reflections.glsl line 22:
  const float max_reflection_dist = 80.0;

  // voxel_constants.glsl line 17:
  const float voxel_distance = float(VOXEL_VOLUME_SIZE) * 0.5;
  ```
- **Root Cause**:
  `trace_voxel_specular_fallback` hardcodes `max_reflection_dist = 80.0;`, completely ignoring `voxel_distance`. When `VOXEL_VOLUME_SIZE` is set to 64, the voxel volume only spans 32.0 meters from the camera; at 128, it spans 64.0 meters.
- **Symptom & Visual Evidence**:
  Specular rays continue marching through empty space after exiting the voxel bounding box until they hit the hardcoded 80m limit, burning unnecessary DDA iterations and creating inconsistent fallback behavior when changing voxel volume sizes.

---

### Bug 9: Dummy Value Override in Unified `RayHit` Query Struct
- **Source Files**:
  - [`ray_query.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/rt/ray_query.glsl#L113-L116)
- **Code Reference**:
  ```glsl
  RayHit r;
  r.hit = v.hit;
  r.position = v.hit_pos;
  r.normal = v.hit_normal;
  r.distance = v.distance;
  r.transmittance = v.transmittance;
  r.radiance = v.radiance;
  r.sky_weight = v.sky_weight;
  r.albedo = vec3(1.0);
  r.emission = vec3(0.0);
  r.block_id = 0u;
  r.shape = 0u;
  ```
- **Root Cause**:
  `RayHit` was specified in Stage 6 to unify voxel and screen-space hit data. Although `trace_voxel_dda()` provides hit albedo, `trace_ray()` discards it and overrides `r.albedo = vec3(1.0)`, `r.emission = vec3(0.0)`, `r.block_id = 0u`, and `r.shape = 0u`.
- **Symptom & Visual Evidence**:
  Any consumer relying on `trace_ray()` receives pure white albedo and zero emission for all hits, losing the physical material properties.

---

### Bug 10: Screen-Space GI Skylight Leakage Inconsistency in Hybrid Mode
- **Source Files**:
  - [`ssgi.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/rt/ssgi.glsl#L154)
  - [`voxel_dda.glsl`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/include/lighting/rt/voxel_dda.glsl#L270-L274)
- **Code Reference**:
  ```glsl
  // ssgi.glsl line 154:
  vec3 direct_sky = sky_ambient_color * sqr(hit_light_levels.y);

  // voxel_dda.glsl lines 270-274:
  // Skylight bounce: solid voxels DO NOT inject ambient sky light.
  vec3 sky_radiance = vec3(0.0);
  ```
- **Root Cause**:
  Commit `f924ac5` eliminated ambient skylight injection from solid voxels in `voxel_dda.glsl` to prevent daylight from leaking into enclosed rooms through roof vertices. However, `ssgi.glsl` was left unaligned and still injects `direct_sky = sky_ambient_color * sqr(hit_light_levels.y)`.
- **Symptom & Visual Evidence**:
  In enclosed rooms with window sills or corners with residual vertex skylight, setting `RTGI_TRACER` to `RTGI_TRACER_HYBRID` causes immediate blue skylight leakage into the interior. Switching to `RTGI_TRACER_VOXEL` completely removes the leak, confirming an architectural inconsistency between the two estimators.

---

### Bug 11: Non-Multiplicative Transmittance Blending for Stained Glass
- **Source Files**:
  - [`shaders.properties`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/shaders.properties#L373)
  - [`c1_blend_layers.fsh`](file:///C:/Users/pasas/Desktop/minecraft/mods_src/shaders/photon/shaders/program/c1_blend_layers.fsh#L206-L216)
- **Code Reference**:
  ```properties
  # shaders.properties line 373:
  blend.gbuffers_water.colortex17 = SRC_ALPHA ONE_MINUS_SRC_ALPHA SRC_ALPHA ONE_MINUS_SRC_ALPHA
  ```
- **Root Cause**:
  `colortex17` stores the stained glass optical filter tint. In OpenGL framebuffer operations, physical multi-layer optical transmission requires multiplicative blending ($T_{\text{net}} = T_1 \times T_2$, or `DST_COLOR ZERO`). The shader configuration uses standard alpha blending (`SRC_ALPHA ONE_MINUS_SRC_ALPHA`).
- **Symptom & Visual Evidence**:
  When two differently colored stained glass panes overlap (e.g. Red glass in front of blue glass), the front pane's color overwrites the rear pane's tint rather than producing the physical multiplicative combination (magenta/purple).

---

### Bug 12: Viewfinder MCP `get_diagnostics` Tool Crash on Unbound Shadow Attachments
- **Source Files**:
  - `dev.xirreal.viewfinder.mcp.DiagnosticsSnapshot.java:231` (inside `viewfinder-26.3-2.1.4+26.3.jar`)
- **Error Log**:
  ```
  java.lang.NullPointerException: Cannot invoke "net.irisshaders.iris.targets.RenderTarget.getMainTexture()" 
  because the return value of "net.irisshaders.iris.shadows.ShadowRenderTargets.get(int)" is null
  at dev.xirreal.viewfinder.mcp.DiagnosticsSnapshot.recordPass(DiagnosticsSnapshot.java:231)
  ```
- **Root Cause**:
  `DiagnosticsSnapshot.recordPass()` in the Viewfinder mod iterates through all shadow render target indices (0 to 7) without verifying if the target exists in Iris. Because the Photon pack does not declare `shadowcolor` render targets, Iris leaves entries in `ShadowRenderTargets` null, causing an unhandled `NullPointerException` whenever `get_diagnostics` is called.

---

## 5. Summary Table of Discovered Defects

| Defect ID | Feature / Component | Severity | Description |
| :--- | :--- | :--- | :--- |
| **BUG-01** | Voxel Albedo / RTGI Bounces | **High** | `gl_Color.rgb` is `1.0` for solid blocks; all solid voxels store pure white albedo; bounces reflect uncolored light. |
| **BUG-02** | Translucent Voxelization | **High** | `gbuffers_all_translucent.vsh` lacks voxelization code; stained glass voxels are empty air when shadow pass is off. |
| **BUG-03** | Diagnostic View Depth Buffer | **Medium** | `gi_debug.glsl` samples `depthtex1` (solid depth); debug views penetrate through glass and water. |
| **BUG-04** | Voxel Light Diagnostic View | **Medium** | Non-emitters store `0.0` light; `GI_DEBUG_VOXEL_LIGHT` renders 100% black in non-emissive scenes. |
| **BUG-05** | SVGF Filter / Fireflies | **High** | High-radiance seam hits expand $M_1, M_2$ moments and variance; à-trous filter smears fireflies into large bright blotches. |
| **BUG-06** | DDGI Probe Cache Convergence | **High** | 512 updates/frame with 0.85 hysteresis takes 15–30 seconds to converge; 4m origin snap causes abrupt cache jumps. |
| **BUG-07** | DDGI Irradiance Reconstruction | **Medium** | Abrupt backface culling and $1/\sum w$ weight normalization creates spherical light scallops on flat walls. |
| **BUG-08** | Specular RT Fallback | **Low** | Hardcoded 80.0m trace distance exceeds actual voxel grid boundaries (32m/64m). |
| **BUG-09** | Ray Query Abstraction | **Low** | `trace_ray()` in `ray_query.glsl` hardcodes `r.albedo = vec3(1.0)` and `r.emission = vec3(0.0)`. |
| **BUG-10** | Hybrid SSGI vs Voxel RT | **High** | `ssgi.glsl` injects vertex skylight while `voxel_dda.glsl` does not; causes interior daylight leaks in Hybrid mode. |
| **BUG-11** | Stained Glass Transmission | **Medium** | `colortex17` uses alpha blending rather than multiplicative blending; multi-layer glass fails to filter correctly. |
| **BUG-12** | Viewfinder Diagnostic MCP | **External** | Null pointer exception in `DiagnosticsSnapshot.java` when shaderpack lacks shadowcolor attachments. |

---
*End of Report. Prepared exclusively via live GPU verification on Minecraft 26.3 with Viewfinder MCP.*
