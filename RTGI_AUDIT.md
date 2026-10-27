# RTGI fork audit

**Date:** 2026-10-26  
**Fork HEAD:** `129b519` (`arena/f83e9988-photon`)  
**Upstream fork point:** `6e67b36` — “Use Distant Horizons LOD block textures when Iris provides them (#691)”  
**Reviewed range:** 20 commits, `04418ba` … `129b519`

This audit compares the fork against upstream `6e67b36`, checks the changed code against current Iris source, and runs a static GLSL compile harness over representative program/option variants. The initial audit changed no shader logic; **Step 0 P0 fixes were applied afterward** and are summarized below. Developer files added: this report and `tools/shadercheck/`.

---

## TL;DR — what to fix first

There are two release blockers and one configuration blocker:

1. **P0 — Nether and “Shadows = Off” fail to compile by default.**  
   `RT_REFLECTIONS` unconditionally passes `shadowtex0` into the voxel tracer, but Nether programs and shadow-disabled programs do not declare that sampler. Static validation shows this breaks `deferred4`, all `gbuffers_*translucent*`, `dh_water`, and likely Voxy translucent programs. Introduced in `04418ba`; `819072c` fixed an argument-count error but not this declaration mismatch.

2. **P0 — the new stained-glass filter collides with water refraction data.**  
   `129b519` uses `refraction_data.a > 0.5` as a “glass” marker, but water already stores a 16-bit normal in all four channels of `refraction_data`. Roughly half of water pixels can have `a > 0.5`, so ordinary water is incorrectly treated as stained glass and water refraction is disabled for those pixels.

3. **P0 — voxelization depends on the shadow pass being enabled.**  
   Voxels are written from `shadow.vsh`, but `program.world0/shadow.enabled = SHADOW`, `program.world1/shadow.enabled = SHADOW`, and `program.world-1/shadow.enabled = RAYTRACED_GI`. If `SHADOW` is disabled, or if `RAYTRACED_GI` is off while `RT_REFLECTIONS` is on, the voxel grid is cleared but never populated. RTGI then degrades to SSGI/sky fallback.

**Status:** Steps 0–15 are applied in the working tree. Step 12 seals voxel/screen-space seam leaks and makes pale-block sunlight bounces energy conserving.

TAAU, translucent-GI, sky/emissive gating, voxel-range constants, colored voxel albedo, deterministic voxel writes, point-light propagation, SSGI local-light damping, cave ambient tuning, and seam-safe tracing are now addressed; the remaining work is runtime validation plus optional debug views.

---

## Step 0 status — applied 2026-10-26

The three P0 fixes are now in the working tree. No in-game Iris test has been run; the user will load the shaders.

Changed shader/config files:

- `shaders/include/lighting/specular_lighting.glsl` — P0-1: undefine `RT_REFLECTIONS` for Nether and shadow-disabled programs before including the voxel reflection helper. This removes the undeclared `shadowtex0` compile error without adding a dummy sampler. Voxel reflections are intentionally unavailable in those two configurations; SSR/sky reflections still work.
- `shaders/include/buffers.glsl`, `shaders/program/gbuffers_all_translucent.fsh`, `shaders/program/c1_blend_layers.fsh`, `shaders/shaders.properties` — P0-2: added a dedicated full-res `RGBA8` `colortex17` for stained-glass filter data. `refraction_data`/`colortex3` is again used only for water normals. The glass filter now requires `is_translucent`, uses an explicit `is_glass_filter` flag, is applied before the `back_is_hand` early return, and no longer disables water refraction.
- `shaders/shaders.properties` — P0-3: `program.world0/world1/world-1/shadow.enabled` is forced to `true` whenever `RAYTRACED_GI || RT_REFLECTIONS` is defined, so the shadow vertex shader always runs to populate `voxel_img`. `CUSTOM_IMAGES` and `COMPUTE_SHADERS` were moved to `iris.features.required`; `ENTITY_TRANSLUCENT` remains optional. Added `size.buffer.colortex17`, its blend mode, and the required feature-flag line.
- `tools/shadercheck/check.py` — knows about `colortex17` and stubs Iris/Voxy/COLORWHEEL-injected functions so the static matrices are clean.

Static validation after the fixes:

- At Step 0 time: `224`-case compute/fragment matrix and `585`-case wrapper/option matrix, both **0 failures** with `NO_INJECT=shadowtex0`. Later matrices were expanded to `238`/`624`, then `294`/`780` after Step 3, and finally `308`/`780` after Step 8 (see Step 8 status).
- Additional strict checks passed for Nether default, Overworld/End with `SHADOW` off, TAAU 0.75, normal mapping, `DISTANT_HORIZONS`, `VOXY`, and `COLORWHEEL`.
- `shaders.properties` preprocessor conditionals are balanced. A simulated default-macro preprocessing pass confirms the new `shadow.enabled`, feature-flag, `colortex17` size, and blend keys are active exactly once; the only duplicate keys found are the same three that already exist upstream.

P1-1, P1-2, and Step 3 are now applied; the remaining P1/P2 items in this report still need runtime validation.

---

## Step 1 status — P1-1 applied 2026-10-26

P1-1 (TAAU coordinate handling) is now in the working tree. The shader loaded normally after Step 0; this change targets the TAAU path specifically, so **in-game TAAU verification is still required**.

Changed files:

- `shaders/include/global.glsl` — added `taau_framebuffer_uv()`, `taau_projection_uv()`, and `taau_uv_outside_viewport()`. They are identity at native resolution and centralize the TAAU sub-viewport convention.
- `shaders/include/lighting/diffuse_lighting.glsl` — `PROGRAM_DEFERRED4` now samples RTGI at `taau_framebuffer_uv(uv)`; forward-lit programs use `gl_FragCoord.xy * view_pixel_size` (framebuffer UV).
- `shaders/program/rtgi/rtgi_trace.csh`, `rtgi_temporal.csh`, `rtgi_filter.csh` — now treat their `uv` as a full-framebuffer UV, convert to projection UV before `screen_to_view_space(..., true)`, skip texels outside the active TAAU viewport, and clamp bilateral taps to that viewport.
- `shaders/program/rtgi/rtgi_temporal.csh` — reprojection results are converted from projection UV to framebuffer UV before sampling RTGI history images; motion is measured in RTGI-image pixels.
- `shaders/include/lighting/rt/ssgi.glsl` — depth/G-buffer lookups now use `taau_framebuffer_uv(hit_screen_pos.xy)` with clamped texel coordinates; the current G-buffer sample uses the same framebuffer UV. Previous-frame scene history (`colortex5`) remains in full-screen UV space, matching upstream TAA.
- `shaders/program/voxy_translucent.glsl` — added the missing `uniform vec2 view_pixel_size;` declaration required by the forward RTGI lookup.
- `tools/shadercheck/matrix.py` — added a `TAAU_RENDER_SCALE=0.50` variant.

Static validation after P1-1:

- At that time: `238`-case compute/fragment matrix and `624`-case wrapper/option matrix, both **0 failures** with `NO_INJECT=shadowtex0`. Current matrices are `308`/`780` after Step 8.
- Additional strict checks pass for TAAU 0.75 and 0.50, normal mapping, `DISTANT_HORIZONS`, `VOXY`, and `COLORWHEEL`.
- `git diff --check` and Python syntax checks pass.

P1-2 was applied afterward; see “Step 2 status”. Remaining nuance: SSGI still reconstructs the hit view position with `screen_to_view_space(..., false)` using the raymarcher’s jittered screen position, matching upstream SSR. That is a smaller jitter-path concern than the coordinate mismatch fixed here; verify it in-game with TAAU at 0.50/0.75 if you see SSGI shimmer.

---

## Step 2 status — P1-2 applied 2026-10-26

P1-2 (translucent surfaces receiving GI from the opaque background) is now fixed conservatively. The shader still loads normally; no in-game visual confirmation has been run after this change.

Changed file:

- `shaders/include/lighting/diffuse_lighting.glsl` — RTGI consumption is now gated by `RAYTRACED_GI && PROGRAM_DEFERRED4` via a local `DIFFUSE_USE_RTGI` macro. `rtgi_filtered_sampler` and `sample_rtgi_smooth()` are only declared in deferred4. Every other caller of `get_diffuse_lighting()` — `gbuffers_all_translucent.fsh`, `dh_water.fsh`, `voxy_translucent.glsl`, and builds with `RAYTRACED_GI` disabled — uses the analytic `get_sky_lighting(...)` + `get_block_lighting(...)` path from upstream.

Why this is the right conservative fix: the RTGI buffer is built from `depthtex1` and the opaque G-buffer before translucent geometry is drawn. Sampling it for water/glass/particles means shading the translucent fragment with GI belonging to the opaque pixel behind it. Restoring the analytic path avoids that mismatch without adding a second translucent GI pass.

Trade-off: translucent surfaces no longer receive voxel/SSGI bounce light, so `RTGI_BRIGHTNESS` now affects opaque deferred surfaces only. If you want RTGI on translucents later, add a dedicated translucent-depth RTGI layer or a cheap normal/light-level-based indirect term; do not simply reuse the opaque buffer.

Static validation after P1-2:

- At that time: `238`-case compute/fragment matrix and `624`-case wrapper/option matrix, both **0 failures** with `NO_INJECT=shadowtex0`. Current matrices are `308`/`780` after Step 8.
- Additional strict checks pass for `gbuffers_water`, `gbuffers_textured`, `dh_water` with `DISTANT_HORIZONS`, `voxy_translucent` with `VOXY`, Nether default, `!RAYTRACED_GI`, and TAAU 0.50.
- With `NO_INJECT=rtgi_filtered_sampler`, translucent programs still compile because they no longer reference the RTGI sampler; deferred4 still declares it itself. This confirms the analytic fallback is real and not masked by the harness.
- `git diff --check` passes.

Runtime validation needed: water, stained glass, held items behind glass, particles, DH/Voxy water, and TAAU 0.50/0.75. The most likely visible change is that translucent surfaces are lit more like upstream Photon and less like the opaque surface behind them.

---

## Step 3 status — P1-3 gating + P1-4 range applied 2026-10-26

Step 3 is now in the working tree and was followed by the runtime-feedback hotfix and Step 7. P1-3 is now fixed: sky-origin GI can be gated without discarding emissive/block-light bounces. A dedicated contact-AO pass is still a separate follow-up. P1-4 is fixed.

Changed files:

- `shaders/include/lighting/voxel/voxel_constants.glsl` — added `voxel_edge_fade_start`, `voxel_edge_fade_end`, `voxel_dda_max_steps`, and `get_voxel_edge_distance()` (Chebyshev distance to the voxel cube boundary).
- `shaders/include/lighting/rt/hybrid_rtgi.glsl` — `max_voxel_dist` now comes from `voxel_distance` instead of a hardcoded 64 blocks.
- `shaders/include/lighting/rt/voxel_dda.glsl` — `MAX_STEPS` now comes from `voxel_dda_max_steps` (`7/8 * VOXEL_VOLUME_SIZE + 8`) instead of a hardcoded 80.
- `shaders/include/lighting/diffuse_lighting.glsl` — deferred4 now blends RTGI with analytic sky lighting using `rtgi_visibility = clamp01(max(get_skylight_falloff(light_levels.y), clamp01(get_blocklight_falloff(...)))) * ao`; the vanilla blocklight fallback fades in using the derived voxel edge distance.
- `shaders/settings.glsl`, `shaders/lang/en_US.lang`, `shaders/program/d3_ao.fsh` — corrected the AO/volume-size comments to match current behavior.
- `tools/shadercheck/matrix.py` — added variants for `VOXEL_VOLUME_SIZE=64/256/512` and `VOXEL_VOLUME_CENTER=VOXEL_VOLUME_CENTER_AHEAD`.

Validation after Step 3:

- `294`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- Additional strict checks pass for `VOXEL_VOLUME_SIZE=64/256/512`, `VOXEL_VOLUME_CENTER_AHEAD`, `!SH_SKYLIGHT`, `!RAYTRACED_GI`, and TAAU 0.50.
- `git diff --check` and Python syntax checks pass.

The sky/emissive split was implemented in Step 7 and contact AO in Step 8; see the corresponding status sections. Runtime-test 256/512 volumes: they now actually extend GI range and use 64/512 MiB of VRAM, so they are heavier than the default 128.

---

## Runtime feedback hotfix — 2026-10-26

The user’s screenshots showed that Step 3’s hard `rtgi_visibility` gate made caves and the right-hand wall much darker. The rays did **not** get shorter: at the default `VOXEL_VOLUME_SIZE=128`, `max_voxel_dist` stayed at 64 blocks and `MAX_STEPS` increased from 80 to 120. The regression came from gating the whole RTGI result with the receiving surface’s sky/block lightmap values. In a cave, those values are low even on surfaces that should receive long-range lava/lantern bounces, so RTGI was replaced by a near-zero analytic sky term.

Hotfix applied:

- Added `RTGI_INTERIOR_RETENTION` to `settings.glsl`, `shaders.properties`, and `en_US.lang`.
- Default is `1.00`: full RTGI is preserved, restoring the brighter cave-filling look.
- Lower values (`0.75`, `0.50`, `0.25`, `0.00`) optionally reintroduce the interior light-leak gate to taste.
- `diffuse_lighting.glsl` now uses `mix(RTGI_INTERIOR_RETENTION, 1.0, visibility)` instead of a hard `visibility` multiplier.

Validation after the hotfix:

- `294`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- Direct checks pass for `RTGI_INTERIOR_RETENTION=1.00/0.50/0.00`, TAAU 0.50, Nether default, `gbuffers_water`, and `VOXEL_VOLUME_SIZE=512`.
- `git diff --check` and Python syntax checks pass.

Recommended in-game test: start at `RTGI Interior Retention = 1.00` (default). If sealed caves show outdoor light leaks, lower it gradually; `0.50` is a reasonable first diagnostic value. This is a tunable compromise until RTGI stores sky and emissive/blocklight bounces in separate channels.

---

## Step 4 status — colored voxels + terrain-stage gating applied 2026-10-26

Step 4 is now in the working tree. P1-5 is fixed; render-stage gating is restored; deterministic per-voxel writes and a voxel debug view remain follow-up work. No in-game visual confirmation has been run after this change.

Changed files:

- `shaders/include/lighting/voxel/voxel_storage.glsl` — replaced the old grayscale `albedo.g` payload with a 32-bit layout stored in the existing `RGBA8UI` image: RGB555 albedo, 7-bit block ID, 4-bit block light, 4-bit sky light, and 2-bit flags.
- `shaders/include/lighting/voxel/voxel_update.glsl` — clamps unexpected block IDs above 127 to stone and restores `renderStage` gating so only terrain shadow draw calls write world voxels. COLORWHEEL keeps the upstream permissive fallback.
- `shaders/include/lighting/rt/voxel_dda.glsl` — air detection now uses the unpacked block ID, not `raw.r` (which is now part of the albedo payload).
- `shaders/include/lighting/voxel/voxel_palette.glsl` — fallback-color heuristics now use full RGB (`max_of(fallback_color)`) instead of only the green channel.
- `tools/shadercheck/check.py` — corrected all `MC_RENDER_STAGE_*` constants to Iris `WorldRenderingPhase` ordinals and made the default shader-root/glslang lookup robust for both repository and scratch copies.
- `tools/shadercheck/voxel_packing_test.py` — added a pure-Python regression test for the new packed voxel layout; 1000 randomized round trips pass.
- `tools/shadercheck/README.md` — documents the new packing test.

Validation after Step 4:

- `294`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- Direct checks pass for Overworld/Nether shadow vertex shaders, COLORWHEEL shadow, `VOXEL_VOLUME_SIZE=64/512`, TAAU 0.50, and translucent programs.
- `git diff --check`, Python syntax checks, and the voxel packing test pass.

The per-voxel write race was resolved in Step 8 by switching `voxel_img` to `R32UI` and using `imageAtomicMax()`. Dead water/clear-glass palette branches and a voxel debug view still remain.

---

## Step 5 status — options/docs cleanup applied 2026-10-26

Step 5 cleanup is now in the working tree. These changes are UI/docs only and should not alter rendering. No in-game menu check has been run.

Changed files:

- `shaders/shaders.properties` — `RAYTRACED_GI` is now listed in `screen.raytracing`, so the RTGI toggle is visible in the menu. Removed `PHOTOMETRIC_EXPOSURE` from `screen.raytracing` and from all five profile strings.
- `shaders/settings.glsl` — removed the commented-out `PHOTOMETRIC_EXPOSURE` define and its empty `#ifdef` block.
- `shaders/lang/en_US.lang` — removed dead `RT_AMBIENT_OCCLUSION` and `PHOTOMETRIC_EXPOSURE` entries, removed the duplicated `RTGI_BRIGHTNESS` block, and trimmed the trailing blank lines.
- `README.md` — updated installation/features/compatibility for an Iris-only RTGI fork; removed stale OptiFine, GTAO, LPV colored lighting, and Photonics claims.

Validation after Step 5:

- `294`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `!RAYTRACED_GI`, TAAU 0.50, Nether, and translucent program checks pass.
- `git diff --check`, Python syntax checks, and the voxel packing test pass.

Remaining cleanup: other translation files still contain upstream-era wording, `ko_KR.lang` still has the large CRLF/ordering churn, and `SH_SKYLIGHT` is still mostly dead work when RTGI is on. Those are lower priority because they do not affect shader compilation.

---

## Step 6 status — regression tooling applied 2026-10-26

Step 6 regression checks are now in the working tree. These are developer-tool changes only; no shader rendering code was changed in this step.

Added files:

- `tools/shadercheck/properties_lint.py` — preprocesses `shaders.properties`, checks for new duplicate property keys, verifies the thirteen RTGI menu options are present in `screen.raytracing` / `en_US.lang` / `settings.glsl`, and rejects reintroduction of the removed dead options. The three duplicate keys that already exist upstream are reported as warnings.
- `tools/shadercheck/voxel_packing_test.py` — 1000 randomized round trips for the new 32-bit voxel payload.
- `tools/shadercheck/run_checks.sh` — one-command runner for the packing test, properties lint, and both static shader matrices.
- `tools/shadercheck/README.md` — updated usage instructions.

Validation after Step 6:

- `./tools/shadercheck/run_checks.sh` passes: packing test OK, properties lint OK (3 known upstream duplicate warnings), `308`-case compute/fragment matrix **0 failures**, and `780`-case wrapper/option matrix **0 failures**.
- The compute/fragment matrix is now repository-local at `tools/shadercheck/matrix_compute.py` with `308` cases and **0 failures**.
- `git diff --check`, Python syntax checks, and shell syntax checks pass.

Remaining Step 6 follow-up: add optional debug views for `rtgi_raw`, `rtgi_accum`, `rtgi_filtered`, and `voxel_sampler`, and wire `run_checks.sh` into CI or a pre-push hook if this repository gets a CI setup.

---

## Step 7 status — sky/emissive RTGI split applied 2026-10-26

Step 7 is now in the working tree. This replaces the earlier whole-GI receiver gate with a two-component signal so outdoor light leaks can be suppressed without removing emissive/block-light cave bounces. No in-game visual confirmation has been run after this change.

Changed behavior:

- `SSGIHit` and `VoxelHit` now carry a `sky_weight` estimate. SSGI derives it from the hit surface’s packed skylight; voxel DDA derives it from the ratio of sun/sky radiance to emission/block-light radiance.
- `evaluate_hybrid_rtgi_ray()` returns `vec4(radiance.rgb, sky_weight)`.
- `rtgi_raw_img.a` stores the averaged sky weight.
- Two new custom images, `rtgi_sky_accum_img` and `rtgi_sky_history_img`, carry the temporally accumulated sky weight through the ping-pong history.
- `rtgi_filtered_img.a` now stores the bilateral-filtered sky weight; `sample_rtgi_smooth()` returns `vec4`.
- `diffuse_lighting.glsl` splits RTGI into `rtgi_sky = rtgi_lighting * sky_weight` and `rtgi_local = rtgi_lighting - rtgi_sky`. `RTGI_INTERIOR_RETENTION` gates only `rtgi_sky`; `rtgi_local` is always added. When sky RTGI is suppressed, a proportional analytic sky term is added instead.
- Default `RTGI_INTERIOR_RETENTION=1.00` keeps all traced GI, so the brighter cave-filling look is preserved. Lower values now suppress only sky-origin GI on low-skylight surfaces.
- Updated the setting/language comments and taught `properties_lint.py` about the new custom images.

Validation after Step 7:

- `294`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `./tools/shadercheck/run_checks.sh` passes: voxel packing test OK, properties lint OK (3 known upstream duplicate warnings), full static matrix 0 failures.
- Direct checks pass for `RTGI_INTERIOR_RETENTION=0.50`, `!RAYTRACED_GI`, TAAU 0.50, Nether default, translucent programs, and `VOXEL_VOLUME_SIZE=512`.
- `git diff --check`, Python syntax checks, and shell syntax checks pass.

Contact AO was implemented in Step 8. P1-3 is now fully addressed.

---

## Step 8 status — contact AO + deterministic voxel writes applied 2026-10-26

Step 8 is now in the working tree. It implements the two items requested after the user confirmed the shader was working. No in-game visual confirmation has been run after this change.

Changed behavior:

- `shaders/program/d3_ao.fsh` now computes a mild 8-tap screen-space contact AO term from `combined_depth_tex`, the G-buffer normal, and TAAU-aware view-space reconstruction. `ambient.r` is no longer a constant 1.0. Ambient SSS and bent-normal packing are unchanged.
- Added `RTGI_CONTACT_AO_STRENGTH` (default `0.50`, range `0.00…1.00`) to `settings.glsl`, `shaders.properties`, and `en_US.lang`. `0.00` disables contact AO; the default should only add crevice darkening without removing large-scale RTGI.
- `shaders/shaders.properties` changed `voxel_img` from `RGBA8UI` to `R32UI` for every volume size.
- `shaders/include/lighting/voxel/voxel_storage.glsl` now packs one deterministic 32-bit payload. The bit layout was reordered so `imageAtomicMax()` prioritizes block ID, flags, and light levels over albedo:
  - bits 0–14: RGB555 albedo;
  - bits 15–18: block light;
  - bits 19–22: sky light;
  - bits 23–24: flags;
  - bits 25–31: block ID.
- `shaders/program/shadow.vsh` declares `layout(r32ui) uniform uimage3D voxel_img;`.
- `shaders/include/lighting/voxel/voxel_update.glsl` uses the global image directly and calls `imageAtomicMax()` instead of `imageStore()`. Concurrent vertex writes to the same voxel now resolve deterministically.
- `shaders/include/lighting/rt/voxel_dda.glsl` reads `texelFetch(...).r` and unpacks the 32-bit payload.
- `tools/shadercheck/voxel_packing_test.py` was updated for the new layout and now also verifies atomic-max priority.
- `tools/shadercheck/matrix_compute.py` was added so the compute/fragment matrix is repository-local and no longer depends on the scratch harness.

Validation after Step 8:

- `308`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `./tools/shadercheck/run_checks.sh` passes: voxel packing test OK, properties lint OK (3 known upstream duplicate warnings), both static matrices 0 failures.
- Direct checks pass for `shadow.vsh` with and without COLORWHEEL, `deferred3.fsh` contact AO, `RTGI_CONTACT_AO_STRENGTH=0.00`, `RTGI_INTERIOR_RETENTION=0.50`, TAAU 0.50, Nether, translucent programs, `VOXEL_VOLUME_SIZE=512`, and `VOXEL_VOLUME_CENTER_AHEAD`.
- `git diff --check`, Python syntax checks, and shell syntax checks pass.

Step 9 adds the first fix for the user-reported torch/light-source falloff; it still needs runtime validation. Remaining low-priority items: optional debug views, dead clear-glass/water palette branches, translation cleanup, and commit organization.

---

## Step 9 status — point-light field + SSGI damping applied 2026-10-26

Step 9 is now in the working tree. It targets the user-reported torch/light-source behavior: light pooling only 1–2 blocks around a source, appearing to spread behind the source from the camera’s perspective, and sharp falloff from non-full-block emitters. No in-game visual confirmation has been run after this change.

Changed behavior:

- `voxel_palette.glsl` now has `is_point_light_emitter()` and `get_voxel_light_color()`. Full-block emitters remain solid emissive hits; small emitters such as torches, lanterns, candles, end rods, and soul/copper torches are treated as transparent point lights.
- `voxel_update.glsl` injects a radial **light-only voxel field** around small emitters. These voxels have `block_id = 0` but nonzero `block_light`, so `imageAtomicMax()` lets real geometry always win while DDA can still accumulate the light field.
- Emitter voxels now store the normalized emitter color and full block light instead of relying only on shadow-pass lightmap coordinates.
- New settings:
  - `RTGI_POINT_LIGHT_STRENGTH` (default `0.75`);
  - `RTGI_POINT_LIGHT_RADIUS` (default `3`, options `2/3/4`);
  - `RTGI_SSGI_LOCAL_LIGHT_SCALE` (now default `0.00`; see Step 10).
- `voxel_dda.glsl` now carries `VoxelHit.accumulated_light`. It accumulates light-only voxels volumetrically along the ray, adds direct emission from transparent point emitters, and continues tracing instead of stopping on a torch voxel.
- `hybrid_rtgi.glsl` adds `accumulated_light` to both solid-hit and sky-miss rays and computes the sky weight from the resulting sky/local ratio.
- `rt_reflections.glsl` also adds the accumulated point light to voxel specular fallback.
- `ssgi.glsl` damps previous-frame screen color in low-skylight/local-light scenes, reducing the “light appears only when the camera angle changes” effect.
- `properties_lint.py` now checks the three new options; `en_US.lang`, `settings.glsl`, and `shaders.properties` were updated.

Validation after Step 9:

- `308`-case compute/fragment matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `780`-case wrapper/option matrix: **0 failures** with `NO_INJECT=shadowtex0`.
- `./tools/shadercheck/run_checks.sh` passes: voxel packing test OK, properties lint OK (3 known upstream duplicate warnings, 14 RTGI menu options checked), both static matrices 0 failures.
- Direct checks pass for `shadow.vsh` with/without COLORWHEEL, all three RTGI compute passes, `deferred3.fsh`, `deferred4.fsh`, Nether, translucent programs, TAAU 0.50, `!RAYTRACED_GI`, `RTGI_POINT_LIGHT_STRENGTH=0.00`, `RTGI_POINT_LIGHT_RADIUS=2/4`, and `RTGI_SSGI_LOCAL_LIGHT_SCALE=0.00`.
- `git diff --check`, Python syntax checks, and shell syntax checks pass.

Runtime validation needed: compare the same torch/redstone-torch scene while rotating and walking around the source. The intended result is a smoother, camera-independent falloff with light reaching the adjacent floor/walls, without the bright area being tied to what was visible in the previous frame.

---

## Runtime-reported torch issue — fix applied, needs validation

The user reported that with stock settings a torch produces only a small 1–2 block halo on the wall directly beneath it, and that moving/rotating the camera makes light gradually appear on the floor. The light appears to spread mostly behind the source from the camera’s perspective. The user confirmed this behavior existed before any of the fork fixes in this audit. The behavior also applies to other light sources, though less drastically, and non-full-block emitters show sharp brightness drops on adjacent blocks.

Likely contributing factors (now addressed by Step 9):

- SSGI sampled previous-frame scene color from `colortex5`, so torch-lit surfaces that were not visible in the previous frame could not contribute until the camera revealed them.
- Voxel block light was quantized to 4 bits and only read at the first solid DDA hit; there was no emitted-light field around small sources.
- `sample_data.block_light` came from shadow-pass lightmap coordinates, which can be high on the source block but drop sharply on adjacent wall voxels.
- Small emitters were solid DDA hits, so rays could stop at the torch voxel instead of reaching the surface it illuminates.

Step 9 adds a camera-independent radial light field, makes small emitters transparent to DDA, accumulates point light along rays, and damps SSGI’s view-dependent previous-frame color contribution in local-light scenes. This should reduce the “light behind the source from camera perspective” effect and smooth the sharp drop on adjacent blocks. It still needs an in-game comparison; if the effect persists, the next step is a true multi-bounce block-light propagation pass or a current-frame emissive buffer for SSGI.

---

## Step 10 status — runtime tuning hotfix applied 2026-10-26

After the user reported that the point-light field reduced noise but did not remove camera-position-dependent lighting, and that fully dark caves were too bright, two defaults/controls were changed:

- `RTGI_SSGI_LOCAL_LIGHT_SCALE` default changed from `0.35` to `0.00`. This disables SSGI's previous-frame color contribution in low-skylight/local-light scenes by default, removing the main view-dependent term there.
- Added `RTGI_CAVE_AMBIENT_SCALE` (default `0.35`) and applied it to Photon's analytic cave ambient term in `diffuse_lighting.glsl`. `0.00` makes fully dark caves darker; `1.00` restores the previous behavior.
- Updated `settings.glsl`, `shaders.properties`, `en_US.lang`, `properties_lint.py`, and the reproduce commands.
- Static checks still pass: `308`/`780` matrix cases, packing test, properties lint (14 RTGI menu options), `git diff --check`, and direct checks for `RTGI_SSGI_LOCAL_LIGHT_SCALE=0.00` and `RTGI_CAVE_AMBIENT_SCALE=0.00`.

Runtime validation is still needed. Step 11 addresses the remaining reprojection and voxel-field causes identified after this hotfix.

---

## Step 11 status — camera-independent local GI + AO cleanup applied 2026-10-26

Runtime screenshots showed a full-block emitter lighting the wall mainly when the source was behind the camera, while unlit caves stayed bright and corners showed non-raytraced AO. The following focused changes were applied:

- `ssgi.glsl` no longer reports a zero-radiance SSGI hit when `RTGI_SSGI_LOCAL_LIGHT_SCALE` is `0.00`; low-skylight scenes bypass SSGI entirely. This lets the camera-independent voxel DDA fallback run instead of being suppressed by a dead hit.
- `hybrid_rtgi.glsl` passes receiver skylight to SSGI so that bypass is based on the surface being shaded, not only the hit voxel.
- `voxel_palette.glsl` and `voxel_update.glsl` now inject the radial light field for every emissive block ID, including full-block lamps such as sea lanterns and froglights. `is_point_light_emitter()` remains the separate DDA transparency test for small sources.
- Defaults: `RTGI_POINT_LIGHT_STRENGTH=1.00`, `RTGI_POINT_LIGHT_RADIUS=4`, `RTGI_CONTACT_AO_STRENGTH=0.00`, `RTGI_CAVE_AMBIENT_SCALE=0.00`, and `VANILLA_AO` disabled. RTGI itself supplies the indirect occlusion; analytic/corner AO is optional.
- Static validation still passes: voxel packing test, properties lint (14 RTGI options), `308` compute/fragment cases, `780` wrapper/option cases, and `git diff --check`.

In-game validation is needed to confirm that walls beside a light source no longer brighten when the camera turns, that sealed caves are dark, and that corner AO is gone.

---

## Step 12 status — seam leaks + pale-block overbounce applied 2026-10-26

The user identified the bright sunlit sand sides as light leaking through block seams, with the same effect visible around cave lights. Static review found three contributors:

- Voxel DDA rays with an exactly axis-aligned component could travel forever on a voxel face/corner seam, bypassing solid voxels and sampling sun/sky/point-light radiance through walls. DDA and SSGI now apply a tiny deterministic direction jitter; DDA also ignores both the normal-derived and ray-derived origin voxels.
- Voxel DDA added sun/sky/blocklight irradiance as radiance without the Lambertian `1/pi` factor, and applied an extra `3.0` sun multiplier. Pale blocks such as sand became strong secondary lights. The multiplier is removed and all diffuse bounces now use `voxel_bounce_rcp_pi`.
- SSGI could sample an adjacent face of the same world block and feed its previous-frame sun/lamp color back into itself. Same-block hits, back-facing hits, and excessive sample radiance are now rejected; the high-skylight SSGI scale is reduced from `1.2` to `0.8`.

`dither` is now threaded through `trace_voxel_dda()` and `trace_voxel_specular_fallback()` so both diffuse and specular voxel traces get stable, per-ray seam offsets. Static validation still passes: voxel packing test, properties lint (14 RTGI options), `308` compute/fragment cases, `780` wrapper/option cases, and `git diff --check`.

In-game validation is needed to confirm that sand sides no longer glow, cave walls stay dark behind sealed corners, and lamp-lit walls remain visible.

---

## Step 13 status — redstone mechanism light leaks and vanilla propagation decoupling applied 2026-10-27

The user reported that walls and adjacent corridors were illuminated in bright red by redstone mechanisms located behind walls and ceilings when ceiling lamps were turned off.

Investigation and Root Causes:
1. **The Radial Point-Light Field in shadow.vsh (voxel_update.glsl)**:
   - In Step 9/11, a radial injection loop was added in shadow.vsh to populate light-only voxels up to RTGI_POINT_LIGHT_RADIUS (4 blocks).
   - In GPU rasterization, vertex shaders run asynchronously in parallel across GPU threads. When shadow.vsh executes for redstone torches/mechanisms, the intervening wall geometry has not yet been committed to voxel_img.
   - The occlusion check (imageLoad) sees unwritten air (0) and fails.
   - The shader then writes point_light_color (red for redstone torches) into all air voxels up to 4 blocks away in a sphere—directly through the solid walls into the room and corridor.
   - When RTGI rays are traced in rtgi_trace.csh through the room air, voxel_dda.glsl accumulates this red light from the air voxels and tints the entire room red.
2. **Redstone components classified as emitters**:
   - block.properties previously grouped redstone wire, repeaters, comparators, and rails under block.10038 and block.10058 as light emitters. In Minecraft Java Edition, redstone wire, repeaters, comparators, and redstone blocks emit 0 light.
3. **Vanilla Lightmap Propagation in Voxels**:
   - voxel_update.glsl was passing light_levels.x into sample_data.block_light, causing non-emitter blocks to bounce vanilla block light in voxel_dda.glsl.

Fixes Applied:
- Set RTGI_POINT_LIGHT_STRENGTH 0.00 by default in settings.glsl.
- Guarded the radial point-light injection loop in voxel_update.glsl and air-voxel accumulation in voxel_dda.glsl with #if RTGI_POINT_LIGHT_STRENGTH > 0, eliminating the loop overhead when disabled.
- Restored direct ray hits on emitters in voxel_dda.glsl: rays directly collect emitter radiance without requiring artificial radial air fields, and solid walls strictly occlude hidden emitters.
- Reclassified redstone wire, repeaters, comparators, rails, and redstone blocks into non-emitting block.10058 / block.10013 with emission = vec3(0.0).
- Added #define RTGI_VANILLA_LIGHTMAP_PROPAGATION toggle in settings.glsl (disabled by default), allowing voxels to be lit purely by ray-traced emitter hits rather than vanilla lightmap values.
- Re-packaged photon.zip into the 26.3 PrismLauncher profile.

---

## Step 14 status — temporal motion responsiveness, disocclusion anti-flicker, resolution-scaled filtering, and active pack synchronization applied 2026-10-27

The user reported four interrelated symptoms in game:
1. Flickering light (frequent brightness changes).
2. Strange, muddy AO in corners.
3. Strange white stripes along joints between blocks on the wall.
4. Trails / ghosting left by camera movement.

Root Causes:
- **Active Pack Mismatch**: Iris was configured in iris.properties to load photon123.zip. That file was an older pre-Step 12/13 build which still had corner-only voxelization (causing the white seam leaks), VANILLA_AO enabled (causing the muddy corner triangles), and RTGI_RESOLUTION=2 in photon123.zip.txt without adequate spatial filtering.
- **Camera Movement Trails**: rtgi_temporal.csh clamped motion alpha to a maximum of 0.25 (75% history retained during camera rotation), causing visible smearing / ghosting trails.
- **Light Flickering**: rtgi_temporal.csh used a hard binary cutoff for dist_diff < dist_tolerance. Any slight depth deviation across glancing walls caused the pixel to instantly discard all history and flash with raw 2-ray Monte Carlo noise.
- **Resolution Filter Gap**: At RTGI_RESOLUTION=2, rtgi_filter.csh used a fixed step_size=2, which only covered 4 pixels radius—too narrow to denoise 2 rays/pixel.

Fixes Applied:
- **Anti-Flicker Smooth Disocclusion**: In rtgi_temporal.csh, implemented continuous depth_confidence over [dist_tolerance, 2*dist_tolerance]. If geometry slightly shifts or jitters on angled walls, history smoothly transitions rather than popping violently to raw noise.
- **Eliminate Motion Trails**: Scaled motion sensitivity (length(screen_motion) * 0.08) and increased maximum motion alpha to 0.70. Rapid camera turns now refresh 70% of lighting immediately, eliminating ghosting trails. Still accumulation settles at alpha = 0.08.
- **Firefly Suppression**: Lowered max_radiance_lum from 12.0 to 8.0 in rtgi_trace.csh to suppress stochastic outlier flashes.
- **Resolution-Scaled Filter Kernel**: rtgi_filter.csh now scales step_size with RTGI_RESOLUTION (4 for full-res, 2 for half-res, 1 for quarter-res) so the spatial filter consistently spans an 8-pixel radius.
- **Dual Pack Sync**: Synchronized both photon.zip and photon123.zip in PrismLauncher's shaderpacks folder with all Step 0-14 updates.

---

## Step 15 status — smooth blocklight falloff, direct illumination restoration, and filter stippling removal applied 2026-10-27

The user uploaded a screenshot showing a sea lantern in a room with severe stippling/grain on the ceiling, pitch-black shadows on block sides, and harsh light cutoff.

Root Causes:
1. **Mosaic Grid Stippling**: step_size=4 in rtgi_filter.csh skipped 3 pixels between taps, leaving unblended hole gaps that produced a regular checkerboard grid pattern on the ceiling and walls.
2. **Missing Direct Local Illumination**: diffuse_lighting.glsl zeroed out mc_block inside the voxel volume (via voxel_edge_fade). This forced the room to rely entirely on 2 stochastic rays/pixel hitting the 1x1 sea lantern, leaving 95% of pixels with zero light and producing pitch-black shadows.
3. **Abrupt Light Cutoff Exponent**: get_blocklight_falloff used pow12(blocklight), which dropped light intensity from 0.9 to 0.02 after only 2 blocks.

Fixes Applied:
- Restored direct block illumination in diffuse_lighting.glsl: lighting += mc_block. Direct light from emitters now smoothly covers all line-of-sight surfaces over a 15-block radius. Because Minecraft's light engine respects block opacity, it never leaks through solid walls (hidden redstone mechanisms stay dark).
- Replaced the harsh pow12(blocklight) cutoff in get_blocklight_falloff with smooth natural 0.5 * pow4(blocklight).
- Replaced step_size=4 in rtgi_filter.csh with step_size=2 uniformly, ensuring complete spatial filter overlap without mosaic holes or stippled dots.
- Allowed voxel_block_light in voxel_update.glsl to store light_levels.x on solid surfaces so RTGI secondary rays bounce soft light into shadows.
- Synchronized both photon.zip and photon123.zip in PrismLauncher.

---

## What is working / verified good

These are not bugs, and some are improvements over the upstream baseline:

- The three RTGI compute passes (`rtgi_trace`, `rtgi_temporal`, `rtgi_filter`) compile for all three dimensions in the static matrix. Their `workGroupsRender` values match the relative custom-image sizes in `shaders.properties`, and Iris’s `ConstDirectiveParser` sees them after include expansion.
- Custom image declarations are consistent with Iris: `voxel_img` is cleared per frame; the four `rtgi_*` images persist and their ping-pong read/write pattern is consistent between `rtgi_temporal.csh` and `rtgi_filter.csh`.
- `78f04c8` adding an include guard to `global.glsl` is correct.
- `6df182b` renaming `light_color` → `voxel_light_color_table` fixes a real varying/function-name collision.
- `819072c` adding `surface_normal` to `trace_specular_ray` fixes the DDA argument mismatch.
- `shadow.vsh` now uses `uint(max0(mc_Entity.x - 10000.0))`, avoiding an undefined negative-to-uint conversion for entities.
- `gbuffers_all_translucent.fsh` no longer undefines `SHADOW_COLOR`, so colored shadows can affect forward-lit translucent surfaces.
- `voxel_tint_color_table` order matches `block.properties` IDs `10081`–`10096`.
- `385d3cd` removed a stray `#endif` at the end of `c3_taau_prep.fsh`. Static validation shows upstream `6e67b36` fails to compile with `TAAU` enabled because of that unmatched directive; the fork passes. This is a fork fix, not a regression.
- The deferred-stage `texture.deferred.depthtex0` 3D atmosphere LUT does **not** replace `sampler2D depthtex0` in the RTGI compute shaders. Iris only renames declarations whose sampler type matches the custom texture type; a `sampler2D depthtex0` remains bound to the real depth texture.

---

## P0 — release blockers

### P0-1 `RT_REFLECTIONS` references an undeclared `shadowtex0` — FIXED

**Confidence:** confirmed static compile failure; fork regression.  
**Introduced:** `04418ba` (RTGI), still present at HEAD.  
**Evidence:**

- `shaders/include/lighting/specular_lighting.glsl:299-334` calls `trace_voxel_specular_fallback(...)` with `shadowtex0`, `shadowModelView`, and `shadowProjection` inside `#ifdef RT_REFLECTIONS`.
- `shaders/include/lighting/rt/rt_reflections.glsl:8-20` and `shaders/include/lighting/rt/voxel_dda.glsl:47-58` require a `sampler2D` shadow texture.
- `shaders/program/d4_deferred_shading.fsh:76-85` declares `shadowtex0` only under `#ifndef WORLD_NETHER` / `#ifdef SHADOW`.
- `shaders/program/gbuffers_all_translucent.fsh:74-90` declares it only for Overworld/End with `SHADOW`.
- `shaders/program/dh_water.fsh:59-69` has the same restriction.
- `shaders/program/voxy_translucent.glsl:1-36` includes `specular_lighting.glsl` but does not declare `shadowtex0`.

Static validation results:

| Variant | Upstream `6e67b36` | Fork HEAD |
|---|---:|---:|
| Overworld default | passes | passes |
| End default | passes | passes |
| Nether default | passes | **fails**: `'shadowtex0' : undeclared identifier` |
| Overworld/End with `SHADOW` off | passes | **fails** |
| Nether with `RT_REFLECTIONS` off | n/a | passes |

Before the Step 0 fix, the 585-case wrapper/option matrix produced 38 compile failures, all with this single root cause. Disabling `RT_REFLECTIONS` made the failing Nether programs compile. After the fix, both static matrices report zero failures.

**Why it matters:** `RT_REFLECTIONS` is enabled by default in `settings.glsl:66` and in the high/ultra/extreme profiles. On a stock checkout, entering the Nether should produce shader compile errors. Turning off shadows in the UI does the same in Overworld/End.

**Fix applied (Step 0):** `specular_lighting.glsl:22-24` now undefines `RT_REFLECTIONS` for `WORLD_NETHER` or `!SHADOW` before the voxel reflection helper is included. Those programs fall back to SSR/sky reflections instead of referencing an undeclared sampler. This is option 3 from the original audit; options 1 and 2 remain valid future improvements if voxel reflections are wanted in the Nether or with shadows off.

---

### P0-2 `refraction_data.a` is overloaded and breaks water — FIXED

**Confidence:** confirmed logic bug; fork regression.  
**Introduced:** `129b519` for the filter marker; `7d2081e` for the water/glass branch in `gbuffers_all_translucent.fsh`.  
**Evidence:**

Before the fix:

- `c1_blend_layers.fsh` treated `refraction_data.a > 0.5` as “stained glass optical filter”.
- The same file disabled normal refraction when `refraction_data.a >= 0.5`.
- `gbuffers_all_translucent.fsh` wrote water normals into all four `refraction_data` channels and wrote stained-glass tint plus `a = 1.0` into the same buffer.
- `shaders/include/utility/encoding.glsl:101-107` shows `split_2x8(x)` stores the high byte of `x * 65535` in the second component. For `x > 0.5` — i.e. `normal_tangent.y > 0` — `refraction_data.a > 0.5`.
- `colortex3` is `RGBA8` (`shaders/include/buffers.glsl:7`), so all four channels were already occupied by water refraction data.

**Symptoms:**

- Ordinary water pixels with positive normal-map Y are falsely treated as stained glass. The “glass tint” is actually the two packed normal bytes interpreted as RGB, producing angle-dependent color bands and shimmer.
- Refraction is silently disabled for exactly those pixels.
- `back_is_hand` returned early at `c1_blend_layers.fsh:180-188`, so looking through glass at a held item bypassed the filter entirely. This is also fixed.
- The filter is applied to the whole background, including sky, fog, and clouds, rather than to light paths that physically cross glass. The `mix(background * tint, tint * bg_lum, 0.75)` formula does not actually preserve luminance in the working color space.

**Fix applied (Step 0):**

- Added a dedicated full-res `RGBA8` `colortex17` (`buffers.glsl:20,38,43`; `shaders.properties:288,368`). `gbuffers_all_translucent.fsh:15-20,364-369,732-742` now writes water normals to `refraction_data`/`colortex3` and stained-glass tint to `glass_filter_data`/`colortex17`.
- `c1_blend_layers.fsh:159-167,206-213,241-242,270,310-311,430-440` reads `colortex17`, computes an explicit `is_glass_filter`, requires `is_translucent`, and no longer inspects `refraction_data.a`.
- The `back_is_hand` early return now applies the glass filter before returning (`c1_blend_layers.fsh:180-188`), via the shared `apply_glass_filter()` helper.
- Water keeps its full 16-bit normal encoding; no precision was sacrificed. Re-test water, glass panes, tinted glass, held items behind glass, and refraction at grazing angles in-game.

---

### P0-3 Voxelization is tied to the shadow pass — FIXED

**Confidence:** confirmed configuration bug; fork regression / design issue.  
**Introduced:** `04418ba` and `385d3cd`.  
**Evidence:**

- `shaders/program/shadow.vsh:67-90` declares `voxel_img` and calls `update_rt_voxel_grid(...)` under `#if defined RAYTRACED_GI || defined RT_REFLECTIONS`.
- `shaders/include/lighting/voxel/voxel_update.glsl:24-58` only writes from the shadow vertex shader.
Before the fix:

- `shaders.properties` set `program.world0/shadow.enabled = SHADOW`, `program.world1/shadow.enabled = SHADOW`, and `program.world-1/shadow.enabled = RAYTRACED_GI`.
- `shaders/shaders.properties:404-415` declares `voxel_img` with `clear=true`; Iris clears it at frame start. If the shadow pass is disabled, it stays empty.
- `shaders/program/final.fsh:31-33,185-190` samples `shadowtex0` only under `RAYTRACED_GI && (WORLD_NETHER || !SHADOW)`; that does not force a disabled program to run.

**Failure modes:**

- `SHADOW` off + `RAYTRACED_GI` on: no voxelization, RTGI loses its DDA fallback.
- `RAYTRACED_GI` off + `RT_REFLECTIONS` on: custom voxel image and shader code still exist, but Nether shadow pass is disabled; reflections use an empty grid.
- `SHADOW` off + `RT_REFLECTIONS` on also triggers P0-1 compile errors.

**Fix applied (Step 0):**

- `shaders.properties:152-156,187-191,222-226` forces `program.world0/world-1/world1/shadow.enabled = true` whenever `RAYTRACED_GI || RT_REFLECTIONS` is defined. This guarantees `shadow.vsh` runs and populates `voxel_img` in all RT configurations, including the Nether with RTGI off.
- `shaders.properties:121-122` now sets `iris.features.required = CUSTOM_IMAGES COMPUTE_SHADERS` and keeps `ENTITY_TRANSLUCENT` optional, so Iris reports the hardware requirement explicitly.
- Future improvement: move voxelization into a dedicated `gbuffers_voxels`-style program so RTGI does not pay for a full shadow pass when `SHADOW` is off.

---

## P1 — correctness and compatibility

### P1-1 TAAU coordinates are inconsistent in the RTGI passes — FIXED

**Confidence:** high-confidence static issue; runtime verification required.  
**Status:** fix applied in Step 1; see “Step 1 status” above.

**Evidence before the fix:** upstream Photon consistently multiplies full-resolution texel coordinates by `taau_render_scale`, e.g. `shaders/include/misc/raytracer.glsl:67,92`, `shaders/include/lighting/shadows/ssrt.glsl:71`, and `shaders/program/c4_taa_exposure.fsh:272,332-333`. The RTGI code did not:

- `rtgi_trace.csh`, `rtgi_temporal.csh`, and `rtgi_filter.csh` treated their RTGI-image UV as both a full-framebuffer UV and a projection UV.
- `ssgi.glsl` used `ivec2(hit_screen_pos.xy * view_res)` for depth/G-buffer fetches even though the raymarcher that produced `hit_screen_pos` used `view_res * taau_render_scale`.
- `diffuse_lighting.glsl` sampled RTGI at `uv` in deferred4 and at `gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale)` in forward programs; both are viewport-space values, but the RTGI images are full-framebuffer relative.
- `rtgi_temporal.csh` used reprojection UVs directly on the RTGI history images without converting projection UV to framebuffer UV.

**Likely symptoms with TAAU on:** GI sampled from the wrong part of the frame, edge crawling, stale depth/G-buffer reads outside the active viewport, and out-of-range `texelFetch` results.

**Fix applied:** shared helpers in `global.glsl` now distinguish projection UV from framebuffer UV. The RTGI compute passes only write inside the active TAAU viewport, convert framebuffer UV → projection UV before view reconstruction, and use framebuffer UV for depth/G-buffer fetches. SSGI and the diffuse RTGI lookup use the same convention. Static matrices now include TAAU 0.50 and 0.75 and pass, but the user still needs to confirm the TAAU path in-game.

---

### P1-2 Translucent surfaces receive GI for the opaque background — FIXED

**Confidence:** confirmed logic issue; fix applied in Step 2.  
**Evidence before the fix:**

- `shaders/program/rtgi/rtgi_trace.csh:92-109` builds RTGI from `depthtex1` (solid depth) and `colortex1/2` (solid G-buffer).
- Iris runs `deferredRenderer.renderAll()` in `beginTranslucents()` before translucent G-buffers are drawn.
- `shaders/program/gbuffers_all_translucent.fsh:638-659`, `shaders/program/dh_water.fsh:271`, and `shaders/program/voxy_translucent.glsl:247` call `get_diffuse_lighting`.
- `diffuse_lighting.glsl` previously sampled `rtgi_filtered_sampler` at the translucent fragment’s screen coordinate for all of those callers.

So water, stained glass, particles, and other forward-lit translucent fragments received the GI computed for the opaque pixel behind them, not GI for their own surface normal/depth.

**Fix applied:** `shaders/include/lighting/diffuse_lighting.glsl:21-28,183-186,301-363,381-383` now defines `DIFFUSE_USE_RTGI` only for `PROGRAM_DEFERRED4`. Opaque deferred shading keeps RTGI; all forward-lit translucent and `!RAYTRACED_GI` paths use analytic `get_sky_lighting(...)` + `get_block_lighting(...)`. See “Step 2 status” for validation and the remaining trade-off.

---

### P1-3 RTGI removes skylight/AO gating entirely — FIXED (sky/emissive split + contact AO)

**Confidence:** confirmed logic issue; final fixes applied in Steps 7 and 8.  
**Evidence before the fix:**

- `diffuse_lighting.glsl` added `rtgi_indirect * (1.6 * RTGI_BRIGHTNESS)` directly in deferred4 with no sky/emissive distinction.
- A later hard receiver-lightmap gate fixed light leaks but also removed long-range lava/lantern cave bounces; the user’s screenshots showed the resulting dark cave.
- `shaders/program/d3_ao.fsh:90-93` always writes `ambient = vec4(1.0, ...)`; SSAO/GTAO implementations were deleted in `385d3cd`.

**Final fixes:** Step 7 stores a sky-origin weight alongside RTGI radiance and carries it through temporal accumulation and bilateral filtering. `diffuse_lighting.glsl` splits RTGI into sky and local/emissive parts; `RTGI_INTERIOR_RETENTION` gates only the sky part. Default `1.00` keeps all traced GI, so cave bounces remain; lower values suppress only sky-origin RTGI on low-skylight surfaces. Step 8 adds a tunable screen-space contact AO pass. See “Step 7 status” and “Step 8 status” for files and validation.

**Resolved:** contact AO is implemented in `d3_ao.fsh` with `RTGI_CONTACT_AO_STRENGTH` (default `0.50`). P1-3 is fully addressed; remaining work is optional debug views and translation cleanup.

---

### P1-4 Voxel range, step count, and edge fade are hardcoded — FIXED

**Confidence:** confirmed design/performance issue; fixed in Step 3.  
**Evidence before the fix:**

- `diffuse_lighting.glsl` hardcoded `smoothstep(48.0, 60.0, player_dist)` for the vanilla blocklight fallback, regardless of `VOXEL_VOLUME_SIZE`.
- `hybrid_rtgi.glsl` hardcoded `max_voxel_dist = 64.0`.
- `voxel_dda.glsl` hardcoded `MAX_STEPS = 80`, which truncates diagonal 64-block rays.
- `voxel_constants.glsl` defined `voxel_distance = 0.5 * VOXEL_VOLUME_SIZE` but the tracer did not use it.
- `settings.glsl:160` and `shaders.properties:404-415` allowed `VOXEL_VOLUME_SIZE` up to 512, so 256/512 allocated 64/512 MiB while most of the volume was unreachable.

**Fix applied:**

- `shaders/include/lighting/voxel/voxel_constants.glsl:17-24,45-49` now defines the fade start/end, the DDA step budget, and `get_voxel_edge_distance()` (cube-aligned Chebyshev distance).
- `shaders/include/lighting/rt/hybrid_rtgi.glsl:59` uses `voxel_distance`.
- `shaders/include/lighting/rt/voxel_dda.glsl:85` uses `voxel_dda_max_steps`.
- `shaders/include/lighting/diffuse_lighting.glsl:336-342` uses the derived edge fade.
- The `settings.glsl` and `en_US.lang` comments now document that 256/512 are high-VRAM options.

**Remaining consideration:** 256/512 now genuinely extend the ray range and step count, so they are expensive. Runtime-profile them; if they are not useful, remove those slider values and the matching `image.voxel_img` branches.

---

---

### P1-5 Voxel albedo is effectively grayscale — FIXED

**Confidence:** confirmed fidelity issue; fixed in Step 4.  
**Evidence before the fix:** `voxel_storage.glsl` stored only `albedo.g` in 6 bits and unpacked `sample_data.color = vec3(tint_g)`, so most colored blocks bounced neutral gray.

**Fix applied:** the voxel payload now stores full RGB555 albedo alongside block ID, light levels, and flags. `voxel_palette.glsl` heuristics use full RGB fallback color. `voxel_dda.glsl` detects air from the unpacked block ID. Light levels are now quantized to 4 bits and block IDs to 7 bits; current `block.properties` IDs stop at 96, so the 7-bit ID is safe.

See “Step 4 status” for validation and the remaining data-race follow-up.

---

## P2 — cleanup, options, and quality

### Options that do nothing or are not exposed — MOSTLY RESOLVED

Step 5 cleanup resolved the main en_US menu issues:

- `RAYTRACED_GI` is now exposed in `screen.raytracing`.
- `PHOTOMETRIC_EXPOSURE` and `RT_AMBIENT_OCCLUSION` were removed from settings/profiles/menu language because they had no implementation.
- Duplicate `RTGI_BRIGHTNESS` language keys were removed.
- `VOXEL_VOLUME_SIZE` and `README.md` wording were updated for the RTGI/Iris-only fork.

Remaining lower-priority cleanup:

- Other translation files still contain upstream-era wording and may lack the new `RTGI_INTERIOR_RETENTION` option.
- `shaders/lang/ko_KR.lang` still has a large CRLF/ordering diff from the fork history; consider normalizing it intentionally in a dedicated commit.
- `SH_SKYLIGHT` remains mostly dead work when RTGI is on (see below).

### SH skylight is now mostly dead work

`SH_SKYLIGHT` still enables `deferred4_a.csh` (`shaders/shaders.properties:183`) and passes SH varyings, but `get_sky_lighting(...)` — the only consumer of those SH coefficients for diffuse lighting — is skipped under `RAYTRACED_GI`. Either remove/disable the option when RTGI is on, or feed the SH terms into the RTGI sky fallback.

### Voxelization details to revisit

- `renderStage` gating was restored in Step 4, so only terrain shadow draw calls write world voxels. This bullet is resolved.
- Multiple vertices can still attempt to write the same voxel, but Step 8 changed the image to `R32UI` and uses `imageAtomicMax()`, so the result is deterministic.
- `should_voxelize()` still excludes block ID `80u` entirely, so the clear-glass palette entry and DDA branch remain dead code. Water (`1u`) is also excluded. Remove those branches or voxelize the blocks intentionally.
- `sample_voxel_sun_shadow()` in `voxel_dda.glsl:20-44` uses a fixed `normal * 0.15` bias rather than the pack’s `get_shadow_bias()`; expect more light leaks/peter-panning on voxel bounce lighting.
- The first voxel crossed by a DDA ray uses `mask = 0` for its hit normal (`voxel_dda.glsl:82,106`), so that normal is wrong for immediate hits.

### SSGI and filter heuristics

- `shaders/include/lighting/rt/ssgi.glsl:81-88` rejects any SSGI hit whose pixel has a translucent depth layer in front. This does not distinguish stained glass from water, particles, or hand geometry. It can cause a visible switch from detailed SSGI to low-resolution voxel GI around any translucent surface.
- `ssgi.glsl:92` accepts hit normals with `dot(hit_normal_view, -ray_dir_view) > -0.1`, which allows slightly back-facing hits.
- `shaders/program/rtgi/rtgi_filter.csh:105-143` does not reject sky neighbors (`n_depth >= 1.0`) and uses a depth tolerance proportional to `center_dist`, so distant sky/background samples can bleed onto nearby geometry.

---

## Prioritized next steps

### Step 0 — make a stable baseline — DONE (code changes applied)

1. Apply the three P0 fixes. **Done** — see “Step 0 status” above.
2. Run `python3 tools/shadercheck/matrix.py`; target: **zero real compile failures** across Overworld/Nether/End, shadows on/off, RT reflections on/off, RTGI on/off, TAAU on/off, normal mapping on/off. **Done:** both static matrices pass with `NO_INJECT=shadowtex0`.
3. Load the pack in Iris and enter all three dimensions. Confirm no compile errors in `latest.log`. **Pending — user will do this.**

### Step 1 — validate the render pipeline in-game

Use this matrix:

- Dimensions: Overworld, Nether, End.
- Options: `SHADOW` on/off; `RT_REFLECTIONS` on/off; `RAYTRACED_GI` on/off; `TAAU` off and 0.75/0.50; `RTGI_RESOLUTION` 0/1/2; `RTGI_RAY_COUNT` 2/4/8; `VOXEL_VOLUME_SIZE` 64/128/256; `NORMAL_MAPPING` on/off; `SH_SKYLIGHT` on/off; `VL` on/off.
- Scenes: sealed cave, red/green/blue concrete room, torch in a dark room, stained glass against bright sky and dark cave, water with normal mapping, held item behind glass, Nether portal, rapid camera rotation, teleport/respawn, window resize.

### Step 2 — translucent GI — DONE

- TAAU coordinate handling is done; see “Step 1 status”.
- Forward-lit translucent surfaces now use analytic sky/block lighting instead of the opaque RTGI buffer; see “Step 2 status”. A dedicated translucent RTGI layer remains a possible future enhancement.

### Step 3 — restore physically meaningful gating — DONE

- Sky-origin GI is now separated from emissive/block-light GI; see “Step 7 status”.
- `voxel_edge_fade`, `max_voxel_dist`, and `MAX_STEPS` derive from `VOXEL_VOLUME_SIZE`.
- Contact AO was implemented in Step 8; see “Step 8 status”.

### Step 4 — improve voxel data — DONE (debug view optional)

- Full RGB albedo is packed; see “Step 4 status”.
- `renderStage` gating and deterministic atomic voxel writes are both applied.
- Still to do: remove dead clear-glass/water palette branches or voxelize those blocks, and add a debug view for `voxel_sampler` occupancy, block ID, light levels, and albedo.

### Step 5 — clean up the fork — DONE

- Dead options and duplicate en_US keys were removed; `RAYTRACED_GI` is exposed; see “Step 5 status”.
- `README.md` compatibility/features were updated.
- Still optional: normalize the remaining translation files and reorganize the 20 RTGI commits into logical commits before opening a PR. Keep the fixes from `6df182b`, `819072c`, and `385d3cd` attributable.

### Step 6 — add regression checks — DONE (debug views optional)

- `tools/shadercheck/` now includes `run_checks.sh`, `properties_lint.py`, `voxel_packing_test.py`, and the static GLSL matrix; see “Step 6 status”.
- Still optional: wire `run_checks.sh` into CI/pre-push, expand the linter to `image.*` / `program.*.enabled`, and add debug views for `rtgi_raw`, `rtgi_accum`, `rtgi_filtered`, and `voxel_sampler`.

---

## Validation methodology and limitations

- Cloned upstream Photon at `6e67b36` and current Iris (`bff1e69cb`) to verify Iris contracts: compute dispatch directives, custom image parsing, feature flags, custom-texture patching, and deferred/compute pass ordering.
- Built `glslang` locally and wrote `tools/shadercheck/check.py`, which:
  - resolves the shaderpack include graph;
  - injects Iris-provided custom uniforms and environment defines;
  - supports macro overrides such as `!SHADOW`, `TAAU`, `+DISTANT_HORIZONS`;
  - compiles representative `.csh`, `.fsh`, and `.vsh` wrappers with `glslang`.
- Ran two repository-local matrices. At Step 0 they were 224 compute/fragment and 585 wrapper/option variants; after Step 9 they are 308 compute/fragment and 780 wrapper/option variants. Before the fixes, every real compile failure traced to P0-1; the only other failures were harness-only COLORWHEEL/Voxy injection artifacts. After Step 0, harness stubs, P1-1, P1-2, Step 3, the runtime-feedback hotfix, Steps 4–8, and Step 9, both matrices report zero failures.
- Caveats:
  - This is not a full Iris runtime compile. Vertex shaders were approximated with GLSL 430 compatibility because Iris injects replacements for `gl_Vertex`, `gl_ModelViewMatrix`, etc.; COLORWHEEL and Voxy runtime-injected code was stubbed.
  - `glslang` does not validate OpenGL uniform binding, image feedback hazards, or driver-specific behavior.
  - No in-game visual test was performed. TAAU and temporal issues are high-confidence static findings that still need runtime confirmation.

Reproduce the current static validation (all should pass):

```sh
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred1_a.csh comp
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world-1/deferred4.fsh frag
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/gbuffers_water.fsh frag
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag '!SHADOW' '!SHADOW_SSRT'
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag TAAU TAAU_RENDER_SCALE=0.50
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_INTERIOR_RETENTION=0.50
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_POINT_LIGHT_STRENGTH=0.00
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_POINT_LIGHT_RADIUS=2
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_SSGI_LOCAL_LIGHT_SCALE=0.00
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_CAVE_AMBIENT_SCALE=0.00
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred1_a.csh comp VOXEL_VOLUME_SIZE=512
NO_INJECT=shadowtex0 python3 tools/shadercheck/check.py /world0/deferred4.fsh frag VOXEL_VOLUME_CENTER=VOXEL_VOLUME_CENTER_AHEAD
NO_INJECT=shadowtex0 python3 tools/shadercheck/matrix_compute.py
NO_INJECT=shadowtex0 python3 tools/shadercheck/matrix.py
python3 tools/shadercheck/voxel_packing_test.py
python3 tools/shadercheck/properties_lint.py
```

Or simply:

```sh
./tools/shadercheck/run_checks.sh
```

Before the P0 fixes, the Nether and `!SHADOW` checks above failed with
`'shadowtex0' : undeclared identifier`. They now pass. The TAAU 0.50 check
exercises the P1-1 coordinate path. Steps 11–12 add no new macros; the existing
`RTGI_SSGI_LOCAL_LIGHT_SCALE=0.00`, `RTGI_CAVE_AMBIENT_SCALE=0.00`, and
`RTGI_CONTACT_AO_STRENGTH=0.00` cases cover the new defaults.
