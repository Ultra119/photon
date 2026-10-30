# RT Lighting Bug Audit — fork HEAD `6d49083` (`arena/ce39d2b2-photon`)

**Date:** 2026-10-30 (Wave 1 fixes applied same day)
**Status:** Wave 1 applied — see “Wave 1 status” below. Waves 2–4 pending.
**Method:** full static re-read of the current RT pipeline (`rtgi_trace`, `rtgi_temporal`, `rtgi_filter`, `rtgi_probe_update`, `rt_gi.glsl`, `ddgi.glsl`, `voxel_dda.glsl`, `voxel_update/palette/storage`, `diffuse_lighting.glsl`) against the SEUS PTGI HRR Test 2.1 reference (extracted from the attached archive). Every finding below was re-verified from the current working tree; nothing is copied from prior audit docs, and prior "confirmed" claims were treated as untrusted. SEUS is used only as a behavioral reference — no code is taken from it.

**Confidence labels:**
- `[static-confirmed]` — logic error provable from the code alone.
- `[high-confidence]` — mechanism is clear from code; magnitude needs one in-game check.
- `[design-issue]` — not a crash/logic error, but the architecture itself produces the reported symptoms.

---

## Wave 1 status — applied 2026-10-30

Five bleeding-stop fixes from Section 7, Wave 1, are now in the working tree.
No in-game validation has been run; the user should load the pack and compare
against the isolation guide in Section 8.

Changed files and behavior:

- `shaders/program/rtgi/rtgi_temporal.csh` — **T1:** the M2 moment is now an
  EMA of *sample luminance squared* (`mix(prev_m2, current_lum², alpha)`)
  instead of `accum_lum²`, which had collapsed `variance = M2 − M1²` to zero
  and disabled all variance-guided filtering. History-rejected/reset pixels
  seed M2 with the center luminance plus the local raw 3×3 variance so the
  à-trous filter sees a real noise level on disocclusion. **T2:** history
  (radiance, distance, packed sky/age, octahedral normal) is now point-sampled
  with `texelFetch` at the reprojected integer texel; the reprojected position
  is also rejected when outside the active TAAU viewport. **T3:** the
  neighbour-relative firefly ceiling (`neighbor_max·2 + 0.15`) is removed; it
  clamped legitimate emitter hits to ~0.15 in dark rooms and itself flickered
  with the 2-ray neighbourhood. A generous absolute guard (luminance 32) plus
  the trace-side `RTGI_MAX_RADIANCE` clamp remain as outlier control, with real
  outlier suppression coming from the now-working history variance clip.
  Unused `raw_min`/`neighbor_max`/scalar `m1` locals removed.
- `shaders/include/lighting/rt/voxel_dda.glsl` — **S1:** the first-voxel entry
  normal is now the axis that achieved the clip-cube `tenter` instead of the
  zero-mask fallback `-sign(dir)` (an unnormalized diagonal that produced
  over-bright garbage `NoL` exactly at corners). The mask is overwritten with
  the next step axis before the first `t_max` update, so stepping is unchanged.
  **D6:** `trace_voxel_level` zeroes `mat.emission` for clipmap levels > 0, so
  a single torch/lamp block folded by `imageAtomicMax` into a 2³/4³-block
  coarse cell can no longer shade as a giant emissive cube (popping far-field
  fireflies). Coarse cells remain conservative occupancy with sun bounce.

Validation after Wave 1:

- `./tools/shadercheck/run_checks.sh` passes end-to-end with glslang 16.6.0:
  voxel packing test OK, properties lint OK (3 known upstream duplicates),
  `294`-case compute/fragment matrix **0 failures**, `1053`-case
  wrapper/option matrix **0 failures**, voxel DDA/energy reference 16/16,
  clipmap coverage OK, RT lighting boundary OK, RT AO dispatch OK (12 cases),
  gi debug wiring OK (38 cases).
- `git diff --check` passes.

Runtime validation still needed (Wave 1 targets):

- Static dark room with one torch: brightness should stop “breathing”; the
  torch halo no longer collapses to ~0.15 when neighbouring rays miss (T3).
- Moving camera/objects at depth edges: fewer noise flashes and light trails
  from corrected disocclusion tests (T2), residual noise reduced by the
  revived variance-guided filter (T1).
- Room corners at grazing rays: no more over-bright diagonal-normal spikes
  (S1).
- Distant village at night: no popping giant emissive cubes (D6).

Remaining waves: Wave 2 (DDGI containment: D1/D2/D3/D5), Wave 3 (leak gates
& energy: S2/S4/T4/L1), Wave 4 (cleanup: L2/L3/L4/S5).

---

## 0. Symptom → root-cause map

| Reported symptom | Primary causes (finding IDs) |
|---|---|
| DDGI metrics fluctuate on every update; bright spots appear | D1, D2, D4, D5, T1, T3 |
| Shades tinted by surrounding colors | D2, D3 |
| Constant brightness/lighting changes in final render | D1, D5, T1, T2, T3, V2 |
| Colored light leaks at room corners from sources behind walls/ceilings | D3, S2, S3, V2 |
| Sunlight/moonlight leaks at corners | S1, S2, S3 |
| Generally "terrible lighting" vs SEUS | whole Section 2 + 3 |

---

## 1. Current pipeline (as-built)

```
shadow pass (voxel_img/mid/coarse, R32UI, cleared EVERY frame, rebuilt from terrain vertices)
deferred      = d0_sky_map         (sky map in colortex4; light_color at (191,0))
deferred_a    = rtgi_probe_update  (2048 of 32³ probes/frame; 16-frame full cycle)
deferred1     = clouds
deferred1_a   = rtgi_trace         (2 rays/pixel cosine hemisphere → voxel DDA + DDGI bounce)
deferred2_a   = rtgi_temporal      (SVGF-ish temporal, ping-pong accum/history)
deferred3_a   = rtgi_filter        (single 5×5 à-trous pass, stride 2)
deferred4     = d4_deferred_shading (opaque surfaces: filtered RTGI × π × INTENSITY × BRIGHTNESS)
forward-lit   = raw `sample_ddgi_irradiance()` (translucent, DH/Voxy, entities) — no temporal, no filter
```

SEUS reference pipeline for comparison: per-pixel multi-bounce voxel path trace (1–4 rays, temporal 1/N accumulation into `colortex5` with frame-count + variance packed per pixel), multi-pass variance-scaled bilateral denoise with an edge rule that *boosts darker occluded neighbors* (prevents bright bleeding into contact shadows), plus a world-space IR light cache stored **at 1-block resolution inside the shadow volume**, refreshed 2.5 %/frame with solid-neighborhood rejection. Sun/cave leak gates multiply GI by the receiver's vanilla skylight (`SUNLIGHT_LEAK_FIX`, `CAVE_GI_LEAK_FIX`). The fork's architecture inverts SEUS's balance: primary signal is 2 noisy rays, and a low-quality probe cache is re-injected into every hit every frame.

---

## 2. P0 — DDGI probe cache: the source of the fluctuation / bright spots / colored shades

### D1 — Probe refresh cadence + 16-ray variance = visible churn every update
`[design-issue]` (static-confirmed numbers)
- `rtgi_probe_update.csh:50-52` updates 2048 of 32768 probes per frame → each probe refreshes once per **16 frames**.
- `RTGI_PROBE_RAYS = 16` (`settings.glsl:69`) uniform sphere rays with **no variance tracking, no propagation** (probes never read other probes — stated design in `ddgi.glsl` header).
- Hysteresis `0.70` (`rtgi_probe_update.csh:183-188`): each refresh replaces only **30 %** of the value with a **16-ray Monte-Carlo estimate**. Near a small emitter, 16 rays almost always *miss* the torch (a torch at 5 blocks subtends ≈0.04 sr of 12.57 sr; P(hit) ≈ 5 %). So a probe is either ~0 or, on a lucky hit, `E0 ≈ π/16 × emission` — for table emission ~14–35 (`light_colors.glsl` × 2.5 in `voxel_palette.glsl:100`) that is a jump of several units.
- Result: which probes are "bright" reshuffles every 16 frames; the 30 % blend makes each probe drift visibly on its refresh. This is exactly *"metrics fluctuate with every update"* and *"bright spots appear"*.

**SEUS contrast:** their IR cache holds *only* pass-through torch light (ID 241), lives at 1-block resolution, is refreshed with a 2.5 % mix (`deferred2.fsh`: `mix(old, new, 0.025)`), and is neighbor-occlusion-validated. It never carries sky/sun, so it cannot flicker with day/night ray luck, and the primary per-pixel trace carries the actual lighting.

### D2 — Single-direction `dir_factor` hack replaces DDGI's directional irradiance
`[static-confirmed]` — `ddgi.glsl:133-134`
```glsl
float dir_factor = clamp(1.0 + dot(normal, probe_dir_sample.xyz), 0.1, 2.0);
vec3 probe_irradiance = probe_irr_sample.rgb * dir_factor;
```
- `probe_dir` is the luminance-weighted mean direction of the *last* 16-ray update (`rtgi_probe_update.csh:172-175`), itself hysteresis-blended, so it lags and flips.
- One scalar direction cannot represent multi-source irradiance (window + lamp + bounce). A receiving surface facing the stored direction gets **2.0×**; facing away gets **0.1×** — a **20× swing** from a single hacky dot product.
- As probes refresh, `dir` flips → surfaces flick between boost and suppression with the *color of whatever the probe last saw* → *"shades that match the color of the surroundings"*, bright/dark splotches.

**SEUS contrast:** no directional reconstruction at all for diffuse; directionality comes from the per-pixel path trace itself. Proper DDGI uses an 8×8 octahedral irradiance atlas per probe, not a mean direction.

### D3 — Trilinear probe blending leaks light through 1-block walls
`[high-confidence]` — `ddgi.glsl:104-141`
- Probe spacing is 4 blocks (`ddgi_probe_spacing = 4.0`). Minecraft walls are 1 block. The 2×2×2 trilinear blend at a room surface routinely includes probes **on the other side of the wall** (~2.5 blocks away).
- The backface weight (`ddgi.glsl:121-127`) only rejects probes that are *behind the receiving surface's normal plane*. For a **floor or ceiling near a wall** (normal ⊥ wall), a bright probe behind/above the wall has `normal_dist > 0` → **full weight**. Sunlit roof probes leak into the ceiling corners of the room below; a lit room behind a wall leaks its color into the floor/ceiling line of the dark room. This is exactly the reported *"colored light leaks from the corners of the room from a source behind the wall or ceiling. The same happens with sunlight and moonlight."*
- No query-time occlusion test exists (SEUS's IR-cache query rejects probes whose voxel or any of 6 neighbors is solid, `deferred2.fsh c(irCachePos)`; proper DDGI additionally uses probe relocation + short ray tests).

### D4 — Probe relocation is one-shot, single-axis, and doesn't re-validate
`[static-confirmed]` — `rtgi_probe_update.csh:73-118`
- If a probe lands in a solid voxel it tries the 6 face neighbors (+1.5 blocks), then distance-2 neighbors (+2.5), along **one axis only**. A probe deep inside a multi-block structure never escapes; it is zeroed (`w=0`), leaving a hole that neighbors skip → local GI weight drops → dim patches that fill in as the 16-frame cycle reaches them.
- After relocation there is no re-check that the new position is actually air *at coarse scale*, and no check that the probe is not inside a closed box (a relocated probe inside a wall cavity sees only that cavity).

### D5 — Probe bounce is re-injected into every primary hit, every frame
`[design-issue]` — `rt_gi.glsl:71-79`
```glsl
vec4 probe_irr = sample_ddgi_irradiance(hit_world_pos + hit_normal * 0.15, hit_normal, cameraPosition);
vec3 probe_bounce = vx_hit.albedo * voxel_bounce_rcp_pi * probe_irr.rgb;
vec3 radiance = (vx_hit.radiance + probe_bounce) * vx_hit.transmittance;
```
- The per-pixel 2-ray estimate is *supposed* to converge over ~30–60 temporal frames. Instead, every frame the temporally-softened (30 %/16 frames) probe value is added at full strength to every ray hit. Probe noise therefore enters the "converged" signal continuously → the temporal filter chases a moving target → *"constant changes in brightness and lighting in the final render"*.
- The probe term is also double-counted energy: the per-pixel ray's first hit already returns `emission + sun_bounce`; the probe irradiance at that same point includes the same sun bounce gathered by the probe. There is no MIS or subtraction of the already-traced direct term.

### D6 — Coarse clipmap cells fold a torch into a 2³/4³-block emissive cube
`[static-confirmed]` — `voxel_update.glsl:150-168` + `voxel_dda.glsl:286-300`
- `imageAtomicMax` keeps the payload with the **highest block ID**; emitters (IDs 32–79) always beat terrain (IDs ≤ 31). At level 1/2 the payload is written into 2³/4³-block cells with `VOXEL_SHAPE_CUBE` forced, but **block ID, emitter flag and emission are preserved**.
- `trace_voxel_level` shades coarse hits with the full `get_voxel_material(id).emission` = palette × 2.5 (`voxel_dda.glsl:292-296` → `voxel_palette.glsl:78`).
- Consequence: one distant lantern makes its entire 8- or 64-block³ coarse cell a solid emitter of radiance ~14–35. Rays that clip it (max trace distance ≈ 443 blocks, `voxel_constants.glsl:96-98`) produce far-field fireflies that pop as the clipmap scrolls. This is a second, independent source of *"bright spots"*.
- The code comment ("representative material, not a sum of emitter power") is wishful: atomic-max picks the emitter over everything else, it is not a representative average.

---

## 3. P0 — Temporal accumulation & filter

### T1 — Moment tracking is mathematically wrong; variance collapses to ~0
`[static-confirmed]` — `rtgi_temporal.csh:231`
```glsl
m2 = mix(prev_aux.r, accum_lum * accum_lum, alpha);   // ← M2 is driven toward (mean)²
```
- `rtgi_filter.csh:110` computes `center_var = max(0, m2 - m1²)`. Since M2 converges to `accum_lum²` and `m1 = accum_lum`, **variance → 0 by construction**. On history reset `m2 = current_lum²` exactly → variance 0 there too. The variance signal is dead everywhere.
- Filter consequences (`rtgi_filter.csh:118-127`): `sigma_n → 128` (absurdly strict normal test) and `sigma_l → 0.01` floor (almost no luminance blending) as soon as `center_std` underflows. The à-trous filter degenerates to near-no-op on static surfaces and over-reacts on resets → residual 2-ray noise flickers on geometry while history churns.
- Correct SVGF: track `m1 = mix(m1_prev, lum, alpha)`, `m2 = mix(m2_prev, lum², alpha)`, variance = `m2 - m1²` of the *distribution*, or carry the neighborhood variance from the raw buffer (SEUS packs a per-pixel variance/age and scales its denoise kernel by it — `PathTraceDenoiser.glsl`: kernel width `mix(1, 4, sqrt(variance))`, normal exponent `mix(3, 1, variance)`).

### T2 — History is bilinearly sampled, including packed/invalidatable channels
`[static-confirmed]` — `rtgi_temporal.csh:182-185`
- `textureLod` bilinear-interpolates: distance (`.a`, disocclusion test), packed sky+age (`.g`, **bit-packed** — interpolating a packed integer yields garbage), octahedral normal (`.ba`, decoded at `:201`).
- At every depth/normal edge the interpolated values are meaningless → history is wrongly accepted (ghosting, light trails behind moving objects) or wrongly rejected (noise flashes). SVGF samples history with `texelFetch` at the reprojected integer texel and compares *plucked* depths.

### T3 — Neighbor-relative firefly ceiling pumps brightness
`[static-confirmed]` — `rtgi_temporal.csh:141-150`
```glsl
float firefly_ceiling = max_neighbor_lum * 2.0 + 0.15;
```
- In a dark room, 8 neighbors with 2 rays each are usually ~0 → ceiling ≈ 0.15, so a legitimate ray that hits the lamp (radiance 8–30 before this) is clamped to **0.15**. When a neighbor's ray also happens to hit something bright, the ceiling jumps. The clamp itself flickers at ray-noise frequency.
- The absolute `+0.15` floor is far below typical emitter radiance and even below modest bounce levels; it only works if the rest of the scene is already very dark.
- This fights D1/D5: probe/emitter spikes are clamped relative to a stochastic neighborhood, then history mixes clamped/unclamped frames → visible breathing.

### T4 — Single à-trous pass, fixed stride, no variance-guided iteration count
`[design-issue]` — `rtgi_filter.csh:123` (`const int step_size = 2`), one dispatch.
- 2 rays/pixel at half res cannot be denoised by one 5×5 stride-2 pass. SEUS runs successive passes (deferred3/4/5 template) with variance-scaled kernels. Under-denoising forces T3's aggressive clamping, which causes the pumping instead.

---

## 4. P0/P1 — Voxel tracer & sun/moon leaks

### S1 — First-hit entry normal is an unnormalized diagonal vector
`[static-confirmed]` — `voxel_dda.glsl:292` (and `trace_any_hit:399`)
```glsl
vec3 entry_norm = (dot(mask, mask) > 0.5) ? (-mask * step_dir) : -sign(dir_level);
```
- When a solid voxel is hit on the **first DDA iteration** (`mask == 0`), `entry_norm = -sign(dir_level)` = e.g. `(-1,-1,-1)` — a diagonal, **not normalized, not an axis face normal**.
- That value is then used as `hit_norm` for: sun `NoL = dot(hit_norm, l_dir)` (can exceed 1.0 → over-bright sun bounce), shadow-map bias (`get_shadow_bias` with a garbage normal), the DDGI sample offset, and `result.hit_normal` consumers. Immediate hits happen exactly at **room corners and wall bases** where rays graze along a face — this is a corner-localized brightness artifact and a leak helper.
- Fix: derive the face normal from the last axis stepped (keep `mask` from the step that *entered* the voxel), or from `hit_t`'s winning slab in `intersect_sub_box` even when `tenter ≈ seg_start`.

### S2 — Sun/moon bounce on ray hits has no receiver-side gate and a hard-coded shadow bias
`[high-confidence]` — `voxel_dda.glsl:171-185`, `shade_voxel_hit`
- Every solid hit evaluates the **shadow map** at the hit point with a fixed `0.001` compare bias (`:179`) plus `get_shadow_bias(...)` tuned for *primary* pixels, not for arbitrary bounce points. Near silhouettes and thin walls the compare passes on the lit side → sun radiance is added to a hit that geometrically should be dark → sunlight/moonlight bleeding into corners.
- There is **no equivalent of SEUS `SUNLIGHT_LEAK_FIX`** (`deferred.fsh:192-198`: sun-bounce contribution × `saturate(receiver_skylight × 100)`), nor of the 1.1-block "don't bounce the receiver's own sunlight back at itself" origin exclusion (`deferred.fsh` skips sun contribution when `|hit − origin| < 1.1`). The fork previously had an `RTGI_INTERIOR_RETENTION` gate (audit Step 7/10); it has been removed — only the now-dead sky-weight plumbing remains (see L2).
- A ray that tunnels or slides along a seam to a sunlit exterior surface is then *fully trusted*: `radiance = emission + albedo·sun·NoL/π`. The corner leak is colored by the sun/sky tint — matching the report.

### S3 — `safe_ray_dir` creates near-axis rays that slide along voxel faces indefinitely
`[high-confidence]` — `voxel_dda.glsl:20-29`, `trace_voxel_dda:340`
- Exact-axis components are replaced by ±1e-5. A ray intended to travel exactly along a wall plane instead travels *inside* the air voxel hugging the wall for up to `voxel_dda_max_steps` steps, sampling every emitter/light it passes on the *outside* of the intended occluder path. Combined with S1 (first-hit normal garbage when it finally turns a corner) this yields corner streaks.
- Deterministic epsilon jitter is fine for avoiding division by zero, but the "ignore both origin voxels" rule (`:267-268`) plus face-sliding needs a *randomized* sub-voxel origin offset (SEUS: `origin += dir·(0.0001·len) − normal·(0.4·parallax/(NoV)+0.0008)`, `deferred.fsh:191`), not just a direction epsilon.

### S4 — Emission radiance is a fixed palette × 2.5, unrelated to Minecraft light levels
`[design-issue]` — `voxel_palette.glsl:96-101`, `light_colors.glsl`
- `mat.emission = voxel_light_color_table[id-32] * 2.5` (`voxel_palette.glsl:78`) → glowstone-class entries already scaled ×12–14 in the table become radiance **30–35**; redstone torch ×1.5 → 3.75. The table was designed as a *color+relative intensity* table, and the extra ×2.5 has no physical anchor. Combined with T3's 0.15 ceiling the effective visible range of a torch is a coin flip per ray.
- Also: small emitters are **solid DDA hits** that stop the ray (torch voxel blocks the path behind it), while their light is otherwise supposed to come from hitting the voxel — no next-event estimation, no pass-through like SEUS ID 241 (`continue` after adding emission, ray keeps going). This inflates variance and truncates multi-bounce paths at every torch.

### S5 — Voxels are cleared and rebuilt from the shadow pass every frame
`[design-issue]` — `shaders.properties:412-422` (`clear=true`), `voxel_update.glsl` gated on shadow/terrain stages
- Costly full rebuild each frame; anything not drawn into the shadow frustum (beyond shadow distance, chunk edges during fast movement) is simply absent → rays miss → sky fireflies at chunk borders during motion, which the temporal filter then smears. This is a known constraint but it contributes to the "everything constantly changes" feel at range. (SEUS persists its volume in the shadow map with its own voxelization cadence.)

---

## 5. P1 — Integration & consistency

### L1 — Forward-lit surfaces bypass the whole denoise stack and sample raw probes
`[static-confirmed]` — `diffuse_lighting.glsl:194-208`
- Only `PROGRAM_DEFERRED4` uses the filtered RTGI buffer. Everything else (translucent, DH/Voxy water, entities, weather…) calls `sample_ddgi_irradiance()` **directly** — raw, un-temporal, un-filtered, with the D2 `dir_factor` and the D3 wall leak at full strength, and offset along `bent_normal` which for those programs is often just the shading normal.
- A glass pane and the wall behind it can disagree by the full probe noise amplitude in the same frame.

### L2 — Sky-weight plumbing is dead code
`[static-confirmed]`
- `rt_gi.glsl`, `rtgi_trace.a`, `rtgi_temporal` sky/age pack-unpack, `rtgi_sky_accum/history` images (2 extra 32³-relative full-screen RGBA16F targets), `rtgi_filter` sky output — all maintained. But `diffuse_lighting.glsl:196-199` consumes only `.rgb`; `RTGI_INTERIOR_RETENTION` no longer exists in `settings.glsl`. The entire Step-7 sky/local split is unused weight (bandwidth + complexity) unless re-connected (see S2).

### L3 — Probe update dispatch is unconditional
`[static-confirmed]` — `shaders.properties:184` etc. (`deferred*_a.enabled = true`), `LIGHTING_MODE` has only `LIGHTING_MODE_RT` as option (`settings.glsl:65-67`)
- `LIGHTING_MODE_PT` is defined but not selectable; probes + RTGI always run. Dead option surface; if an analytic mode is ever wanted the ifdef maze in `diffuse_lighting.glsl` no longer has a fallback branch ("There is no analytic sky/block/cave fallback" — comment is accurate). Fully dark unloaded areas therefore have **zero** indirect floor once cave ambient was removed — anything the probes miss is pure black, which amplifies the perception of flicker (T3 clamps toward 0).

### L4 — `accumulated_light` / point-light field remnants
`[static-confirmed]` — `voxel_dda.glsl:108,153`; `is_point_light_emitter()` in `voxel_palette.glsl:33-49` is referenced by nothing
- Dead struct field and dead function from the Step 9/13 point-light field experiments (the user-reported red-leak bug). Harmless but confusing; the stale comment in `voxel_palette.glsl:28-31` still claims every emitter "gets a radial light field".

### L5 — `RTGI_PROBE_HYSTERESIS` menu range encourages the wrong direction
`[design-issue]` — `settings.glsl:70`
- Higher hysteresis (up to 0.95) makes D1's churn slower but adaptation to torches/day-night glacial (0.95 → 5 %/16 frames ≈ 5 s time constant). The real fix is more rays per update *at lower frequency*, variance-guided blending, or replacing probes for near-field with per-pixel accumulation (SEUS model).

---

## 6. What SEUS does that the fork should modernize (concept list, not code)

1. **Primary signal carries the lighting**; caches only assist. Per-pixel temporal 1/N accumulation with per-pixel frame count, disocclusion → hard reset to raw (`deferred2.fsh` main). The fork should raise `RTGI_RAY_COUNT` or accept slower convergence instead of injecting noisy probes every frame (D5).
2. **Variance-guided everything**: per-pixel variance packed next to history (`colortex5` layout in SEUS `awIafiSlNY`), kernel width and normal-exponent driven by it (`PathTraceDenoiser.glsl G(...)`). Replace T1's broken moments.
3. **Point-sampled history** with plucked depth/normal comparisons (SEUS `c(v)` uses `floor(uv*res)+0.5` before every history fetch). Fix T2.
4. **Edge rule that protects dark occluded neighbors**: if a tap is *behind* the center plane and darker, its weight is multiplied (SEUS `k = M>.05 && lum(T)<lum(center); q *= 4/variance`). This is the anti-bleed rule the fork's filter lacks; it directly addresses light smearing into corners.
5. **Receiver-plane ray-origin offset** scaled by 1/NoV plus along-ray epsilon (`deferred.fsh:191`) — replaces both the current normal*0.03 hack and the direction epsilon (S1/S3).
6. **Sky/sun leak gates**: multiply sky-miss and sun-bounce contributions by the *receiver's* vanilla skylight (SEUS `saturate(a*100)` / `saturate(a*10)`). Cheap, robust, and it is what actually stops corner leaks of sun/moon (S2). The fork already has the removed plumbing (L2) to reattach this.
7. **IR cache discipline**: 1-block resolution (inside the shadow volume = same resolution as the geometry), stores only *emitter pass-through light* (no sky, no sun), neighbor-solid rejection at query, tiny per-frame refresh. If DDGI is kept, at minimum: store only local emission in probes (drop sky from probes — sky is already traced per-pixel as a miss), query-reject probes inside/near solids, and do not re-add probe energy that the per-pixel ray already observed within ~1 block (origin-exclusion like SEUS's `|dist| ≥ 1.1` rule).
8. **Emitter pass-through**: ID 241-style `continue` — small emitters add radiance and do not terminate the path (S4), which fixes both the "torch blocks its own light" issue and improves multi-bounce.

---

## 7. Prioritized fix plan (recommended order)

**Wave 1 — stop the bleeding (small diffs, largest symptom relief):**
1. T1: fix moment tracking (or feed raw 3×3 variance straight into the aux and drop moments).
2. T2: `texelFetch` history + integer reprojection; keep bilinear only for the radiance itself if desired.
3. T3: replace neighbor-relative ceiling with (a) a luminance-adaptive clamp using the *accumulated* mean (e.g. `max(k·accum_lum, absolute_min)`), or SEUS-style variance clamp; raise the absolute floor.
4. S1: correct first-hit entry normal.
5. D6: zero emission (and emitter flag) for clipmap levels > 0; keep them occupancy-only.

**Wave 2 — DDGI containment:**
6. D2: delete `dir_factor`; keep isotropic irradiance.
7. D3: query-time rejection — skip probes whose offset-to-probe segment crosses a solid (cheap 1-2 step DDA) or at minimum skip probes with `normal_dist < 0` for *all* axes via a sphere bound; consider spacing 2–3 for level-0 region.
8. D5: subtract/ignore probe bounce for hits closer than ~1–2 blocks (the per-pixel ray already sees their direct lighting); or only add probe bounce on 2nd+ bounces (track bounce count in `evaluate_rtgi_ray`).
9. D1: 32–64 rays per update at 2×–4× longer cycle, or update 1/4 of probes per frame with variance-weighted hysteresis (`h = clamp(prev_var/(prev_var+new_var), …)`).

**Wave 3 — leak gates & energy:**
10. S2: re-attach a receiver-skylight gate (reconnect L2 plumbing or multiply in `shade_voxel_hit` using the hit voxel's stored sky light — currently hardwired to 0 in `voxel_storage.glsl:74`), plus the 1.1-block origin exclusion for sun bounce.
11. S4: calibrate emission to actual Minecraft light levels (15 → chosen radiance unit), make small emitters pass-through.
12. T4: two à-trous iterations (stride 2 then 1) once variance is real.
13. L1: either run translucents through the same filtered buffer (with their own depth) or gate probe-only lighting to be clearly dimmer/analytics.

**Wave 4 — cleanup:**
14. L2 remove or reconnect sky split; L3 remove dead `LIGHTING_MODE_PT` or restore a fallback; L4 delete dead field/function and fix stale comments; S5 consider persistent voxels across frames with dirty-region updates (bigger project).

---

## 8. Quick reproduction / isolation guide (in-game)

- `GI_DEBUG = GI_DEBUG_PROBE` (`settings.glsl:552`): if the probe view already shimmers while standing still, D1/D2 confirmed.
- `GI_DEBUG_HIT` / `GI_DEBUG_REJECT`: reject-view flicker on static walls → T2/T3.
- Stand in a sealed 5×5 room under a roof with one torch outside the ceiling: ceiling corner color = D3; floor-line glow from adjacent lit room = D3; whole-room breathing = D1+D5.
- Look at a distant village at night: isolated popping bright cubes = D6.
- Sun low at dawn behind a house: light line at interior wall/floor corner = S2 (±S1).

---

*Static analysis only; no shader was executed. All line numbers refer to the tree at audit time (`6d49083`). SEUS PTGI HRR Test 2.1 GFME 1.22 RC1 was used solely to understand reference behavior (raw/accum/denoise/temporal/leak-gate/rebounce); no SEUS code is included or should be copied into this project.*
