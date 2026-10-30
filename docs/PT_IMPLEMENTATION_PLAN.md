# Stage 9 — Path-tracing readiness and implementation plan

**Status:** deferred future reference. PT implementation is paused while the fork becomes RT-first.  
**Active roadmap:** `docs/RT_PT_FORK_PLAN.md` — RT by default, no hybrid/original Photon lighting, PT reserved for later.  
**Audited baseline:** `1c764b3` (`Improve DDGI relocation and firefly filtering`), 2026-10-29.  
**Related documents:** `RTGI_IMPLEMENTATION_PLAN.md` §Stage 9, `docs/testing/reference_scenes.md`, and `tools/shadercheck/README.md`.

## 1. Recommendation

Do **not** start by adding a path loop and a `PATH_TRACED` menu entry. The current repository has useful RTGI components, but it does not yet satisfy the starting conditions assumed by the original Stage 9 specification.

Insert a readiness phase, then deliver PT through small, independently testable gates:

1. Establish a reproducible baseline and a real validation gate.
2. Make scene intersection, materials, and lighting queries trustworthy.
3. Build an emitter representation and a consistent primary-surface BSDF.
4. Implement an internal, diffuse-only reference path tracer.
5. Add GGX-VNDF transport and shared BSDF/light MIS.
6. Add true progressive accumulation and PT-aware reconstruction.
7. Replace the single-volume backend with the clipmap/range coverage required for production.
8. Expose and tune the public mode, then consider optional reservoir resampling.

**Recommended scope strategy:** validate the estimator on the existing bounded voxel volume first, behind an internal compile-time switch. Keep the scene behind a ray-query interface so clipmap work does not require rewriting the integrator. Do not call Stage 9 complete until range coverage, runtime validation, and performance gates pass.

**Important dependency correction:** explicit PT does not need to consume DDGI. The reference PT mode should trace its own bounces and should not read the probe cache. Therefore, imperfect DDGI is not a reason to postpone the PT reference implementation, but the shared scene/material/query defects are. DDGI remains the multi-bounce mechanism for `HYBRID`.

This plan deliberately differs from the old roadmap in two places:

- It does not assume Stages 4–8 are complete.
- It does not switch Ultra/Extreme to PT by default until measured hardware results justify that choice.

## 2. What the current code actually provides

The following is based on the checked-in code, not on stage labels in older documents.

| Area | Current state | Consequence for PT |
| --- | --- | --- |
| Mode selection | `RAYTRACED_GI` is a boolean; `RTGI_TRACER` selects voxel-only or screen-space hybrid. There is no `RTGI_MODE` or PT option. | Add a real mode contract and migrate pass/image/composition guards without breaking `OFF` or `HYBRID`. |
| Scene storage | One cubic `R32UI` image, selectable from 64³ to 512³; default 128³. No clipmap levels or level-transition traversal. | A bounded reference backend is possible; production range coverage is still missing. |
| Voxel writes | Shadow/terrain vertex hooks use `imageAtomicMax` on a packed payload. There is no explicit scene-generation/revision channel. | Static accumulation cannot reliably detect block changes. `worldTime` is not a block-change detector. |
| Shape support | Cube, two slab classes, a fixed stair proxy, and a central pane/fence proxy exist. Classification is heuristic and orientation is not stored. | PT must use exactly the supported shape set and document its limits. Full and shadow rays must agree. |
| Unified ray query | `ray_query.glsl` exists but has no callers. It maps `VoxelHit.accumulated_light` to `RayHit.emission`, loses intrinsic hit emission, and sets block ID/shape to zero. | It is not a usable PT intersection API yet. Separate geometry/material hits from radiance evaluation. |
| Any-hit query | `trace_any_hit` tests different solidity/translucency conditions from the full DDA and does not share its emitter/glass policy. | NEE visibility can disagree with path visibility, producing leaks or missing light. |
| Voxel materials | RGB555 albedo, block-ID palette, emission and roughness. No complete `f0`/metal model. Voxel albedo is linearized but not converted to the renderer's Rec.2020 working space. | Multi-bounce transport will accumulate color and energy errors unless the material contract is fixed. |
| Primary materials | `deferred4` reconstructs `Material` from the G-buffer. Albedo is 8-bit and may already contain vanilla AO/overlays; specular/normal channels depend on options. PT runs earlier. | A shared primary-material decoder is needed. Reference tests need clean albedo, not AO baked into reflectance. |
| Emitters | Emission is found when a ray happens to hit an emissive voxel. There is no emitter list, area/power CDF, deduplication, or overflow policy. | Efficient NEE and emitter MIS cannot be implemented correctly yet. |
| Sky/sun | RTGI uses scalar ambient color and a heuristic hemisphere term. A directional sky map exists, but the PT path does not consume it. | Define one radiance convention and avoid counting the analytic sun both in the sky and in NEE. |
| DDGI | One 32³ probe grid at 4-block spacing, relocation and directional weighting; fixed 2,048 updates/frame. It is not the original two-level, moments/Chebyshev design. | Keep it out of reference PT. Do not claim probe-assisted PT is unbiased. |
| Temporal pass | Reprojection, neighbourhood clipping, motion-adaptive blending, age capped at 64, alpha floor 0.03, and a neighbour firefly clamp. No true static camera/scene detector. | This is reconstruction, not progressive convergence to 256+ samples. |
| Variance metadata | The stored “M2” is blended toward the square of accumulated luminance, not an accumulated raw second moment. Auxiliary channels are already occupied by sky/age/normal. | PT needs a defined metadata layout and a correct variance estimator; do not infer variance from the current field name. |
| Spatial filter | Variance-guided edge weights, but fixed step size and no path-length/RR/convergence inputs. | Add PT metadata and a converged-pixel bypass without destabilizing HYBRID. |
| Composition | The tracer signal is treated as incoming radiance and multiplied by primary albedo/π again; analytic block light and existing reflection paths can also contribute. | PT must return outgoing radiance or use an explicitly different composition contract. Otherwise energy is applied twice. |
| Validation | Python tests mirror selected formulas; they do not execute the GLSL path tracer. No CPU/GPU transport reference comparison exists. | Passing the current tests is not evidence that PT is correct. |
| Resource budget | The local properties linter enforces a 16-image limit. Current active GI configurations use roughly 9 images, or 11 with both diagnostic images. | PT buffers, emitter storage, and future clipmap levels need an explicit allocation table. |

### 2.1 Baseline checks performed for this plan

- `voxel_packing_test.py`: passed, 1,000 randomized round trips.
- `dda_test.py`: passed its 16 Python-side checks.
- `properties_lint.py`: **failed** because `RTGI_POINT_LIGHT_RADIUS` is exposed but no shader reads it; existing upstream warnings remain.
- GLSL compilation/dispatch tests: not run successfully because no usable `glslang` binary is configured in the current environment.
- In-game Iris validation: not performed here. No PT performance or visual-quality result is claimed.

The first implementation PR must fix the baseline gate rather than adding new code on top of a red lint result.

## 3. Product scope and radiometric contract

### 3.1 Included in Stage 9

- Rasterized primary visibility from the opaque G-buffer; no primary ray retracing.
- Explicit 1/2/4/8-bounce paths through the represented voxel world.
- Cosine-weighted diffuse sampling and GGX-VNDF specular sampling.
- Sun and emissive-block next-event estimation with shared PDF/MIS functions.
- Russian roulette after the second scattering event.
- Progressive accumulation for genuinely static camera, scene, and lighting.
- PT-aware temporal/spatial reconstruction and diagnostic views.
- `OFF`, `HYBRID`, and `PATH_TRACED` modes in one pack.
- A bounded-volume reference configuration and a production clipmap configuration.

### 3.2 Excluded from the initial PT mode

- Refraction and total internal reflection.
- Caustics and participating-media transport.
- Entities, hand items, and particles as secondary ray-traced geometry.
- Spectral rendering.
- Block shapes beyond the explicitly supported voxel shape set.
- Full Distant Horizons/Voxy geometry unless the clipmap phase establishes a reliable voxelization hook.
- A claim of full-scene physical realism: this remains raster primary visibility plus voxel path-traced lighting.

Existing raster/forward effects may remain visible, but the documentation must distinguish them from path-traced transport.

### 3.3 What “unbiased” may mean

The reference integrator can be unbiased **with respect to the voxel scene, chosen BSDF, and light sampling model**. It is not an unbiased reconstruction of every real Minecraft surface.

For reference tests, disable radiance clamps, probe-tail estimates, denoising, and analytic fallback inside the tested volume. Firefly suppression and reconstruction are biased post-processes and must be evaluated separately.

### 3.4 Primary lighting boundary

Recommended initial contract:

- Keep the existing raster direct sun/moon highlight and primary-surface emission.
- PT returns **outgoing indirect radiance from the primary surface**, including light arriving from emitters, other surfaces, and the sky.
- At the primary vertex, do not add sun NEE if the raster direct sun is retained.
- At secondary vertices, evaluate sun/moon and emitter NEE explicitly.
- Disable vanilla block-light fallback, analytic ambient sky, and SSR/environment reflection for fully PT-covered opaque surfaces; otherwise the same transport is counted twice.
- Outside valid scene coverage, use a marked transition to the existing analytic/HYBRID fallback. Reference captures disable that fallback inside the test region.
- Preserve the current analytic behavior for translucent surfaces, entities, and hand rendering unless a later stage explicitly changes them.

A later “full PT shading” variant may replace primary direct lighting too, but that is a larger composition change and is not required for the first correct implementation.

## 4. Target architecture

```text
Terrain/shadow voxelization
        |
        v
Finalized voxel scene + revision/hash + emitter table
        |
        v
Shared primary material/geometry decoding
        |
        v
Mode dispatch: OFF | HYBRID trace | PT trace
        |
        v
Raw radiance + validity + PT metadata
        |
        v
Progressive/static accumulation OR motion-aware SVGF temporal pass
        |
        v
PT-aware spatial filter / converged bypass
        |
        v
deferred4 composition with no double-counted lighting
        |
        v
Existing TAA/post-processing
```

DDGI updates remain on the HYBRID branch. They are not in the reference PT dependency chain.

### 4.1 Scene/query interface

The integrator should depend on a backend-neutral query, not on `trace_voxel_dda` internals:

- `trace_scene_ray(...)`: nearest supported opaque surface, distance, geometric normal, voxel/material ID, shape, and transmittance policy.
- `trace_scene_any_hit(...)`: visibility using the same shape and opacity rules.
- `scene_is_valid(...)`: coverage/LOD validity for fallback decisions.
- `get_scene_material(...)`: one material decode shared by all ray modes.

Intersection must not return a precomputed “radiance” mixture. The integrator decides whether it needs emission, reflected light, NEE, or further scattering.

Start with the current single-volume backend. Add the clipmap backend later without changing BSDF sampling, MIS, RR, or accumulation logic.

### 4.2 Path vertex and BSDF interface

Use one path-vertex representation containing position, geometric normal, shading normal, outgoing direction, albedo, emission, roughness, Fresnel parameters, metal/opacity class, and scene validity.

Share these functions between sampling and PDF evaluation:

- `bsdf_eval(...)`
- `bsdf_sample(...)`
- `bsdf_pdf(...)`
- `light_sample(...)`
- `light_pdf(...)`
- `mis_balance_weight(...)` or a documented power-heuristic equivalent

The diffuse/specular mixture PDF must include the lobe-selection probability. Area-light PDFs must include emitter selection probability and the area-to-solid-angle Jacobian. A sampled direction with zero PDF must contribute zero, never a division by zero.

### 4.3 Buffer and image budget

Before implementation, produce a per-mode allocation table and extend the linter to check every active combination. The table must include voxel levels, raw/history/accumulation, metadata, filtered output, probes, emitters, revision state, and debug images.

Recommended starting point:

- Reuse the existing raw and ping-pong history buffers where formats permit.
- Replace/repurpose the sky/aux pair rather than adding another full set of sky buffers.
- Add one PT metadata pair only if the existing auxiliary channels cannot hold age, depth/normal, variance, path length, and RR information safely.
- Prefer one image-backed emitter table initially; an SSBO is an optional optimization after an Iris runtime spike.
- Allocate DDGI images only for HYBRID/probe debug, not for reference PT.
- Gate diagnostic images exactly as today.

At 1920×1080, one full-resolution RGBA16F image is about 15.8 MiB; a ping-pong pair is about 31.6 MiB. Half-resolution images are one quarter of that. Three 128³ R32UI clipmap levels cost 24 MiB before overlap, whereas one 512³ volume costs 512 MiB. These are format payloads, not total driver allocations.

Do not finalize buffer count or format until the metadata and clipmap overlap requirements are known. The 16-image limit is a hard design constraint, not a cleanup item.

## 5. Work packages and gates

Estimates below are focused engineering effort, not a delivery promise. Runtime hardware access and Iris/driver issues can dominate the schedule.

### P0 — Baseline, tooling, and decisions

**Goal:** make regressions visible before changing transport.

**Tasks**

- Fix the existing orphaned `RTGI_POINT_LIGHT_RADIUS` option and restore a green properties lint baseline.
- Install/pin `glslang`, document the exact version, and make missing compiler validation a nonzero CI failure rather than a silent pass.
- Run the existing compute/fragment and wrapper matrices; record the baseline commit, settings, and failures.
- Add a real shader-execution or GPU-capture path for small synthetic tests. Python reimplementations alone are insufficient.
- Define linear HDR capture export, camera/scene metadata, fixed seeds, and numeric comparison tooling.
- Record HYBRID and OFF baseline captures and frame/pass timings on at least one available GPU.
- Confirm the supported Iris/Minecraft version, custom-image behavior, SSBO availability, and required synchronization on that version.

**Likely files:** `tools/shadercheck/*`, CI workflow, `shaders.properties`, testing docs.

**Exit gate:** baseline lint/compile checks are green or have explicitly approved exceptions; a synthetic GPU result can be captured and compared; no new PT feature code yet.

**Estimate:** 2–4 days, plus hardware access.

### P1 — Scene and ray-query correctness

**Goal:** make full-hit and shadow-hit queries describe the same world.

**Tasks**

- Verify voxel image clear/lifecycle behavior on Iris. Document frame boundaries and visibility of writes; do not assume a persistent cache or a generation counter that does not exist.
- Define stable world/cell coordinates, coverage bounds, and invalid-cell behavior.
- Refactor DDA into a shared traversal/shape-intersection core.
- Make `trace_scene_ray` return complete hit data, including intrinsic emission and material identity.
- Make `trace_scene_any_hit` use the same emitter, glass, foliage, and shape policy as the full query.
- Replace whole-origin-cell rejection where it can skip legitimate nearby geometry; use surface identity plus a distance/normal bias appropriate to the voxel scale.
- Audit axis-aligned rays, corner ties, slab/stair seams, inside-origin cases, and maximum-distance termination.
- Fix the material color-space contract: decode voxel albedo once into the working space used by primary materials and lights.
- Remove nonphysical palette attenuation from the PT material path or make it an explicit, shared material definition. The same surface must not have one reflectance for HYBRID and another for PT without documentation.
- Decide the initial glass policy. Recommended: preserve tinted straight-through transmittance as a documented approximation, but exclude refractive transport; full-hit and any-hit must account for it consistently.
- Add GPU/CPU synthetic intersection tests for every supported shape and opacity class.

**Likely files:** `voxel_dda.glsl`, `ray_query.glsl`, `voxel_storage.glsl`, `voxel_palette.glsl`, `voxel_update.glsl`, new scene-query tests.

**Exit gate:** full/any-hit agreement on the test corpus; no systematic self-intersection or seam leaks; material round trips and color-space tests pass; HYBRID remains usable through the new interface.

**Estimate:** 1–2 weeks.

### P2 — Emitters, sun/sky model, and scene revisions

**Goal:** provide light sampling data that conserves energy and can invalidate accumulation.

**Tasks**

- Build a deduplicated emitter table from finalized voxels, not from arbitrary racing vertex writes.
- Store cell/world position, shape/face or area model, emission, total power, selection CDF/alias data, and generation as needed.
- Start with an image-backed table because custom images are already used by the pack. Spike SSBO support separately; do not make it a prerequisite.
- Define capacity tiers and an overflow flag. A bounded table is an acceleration structure, not permission to discard light energy.
- On overflow, use a documented fallback: hierarchical voxel emission sampling, or BSDF-only emitter hits for that frame. Never silently truncate the list and still claim correct NEE.
- Implement area sampling for supported emissive shapes. If a torch uses a point/small-sphere approximation, define its radiance/power normalization and delta-light PDF handling explicitly.
- Build a power-weighted selection structure and shared `light_sample`/`light_pdf` functions.
- Separate directional environment radiance from analytic sun/moon radiance. If the sky map includes the sun disk, exclude it from the environment term used alongside sun NEE.
- Define sun/moon visibility consistently with the selected shadow model; record shadow-map bias/filtering as an approximation in reference comparisons.
- Add a finalized-scene fingerprint or per-tile revision buffer. For a static camera, compare completed voxel/material/emitter hashes; for motion, rely on reprojection plus local invalidation.
- Include lighting changes in progressive invalidation: sun/moon direction/color, weather, relevant sky-map changes, and emitter changes. Do not use `worldTime` as a proxy for block edits.

**Likely files:** new emitter/scene-state includes and compute passes, voxel finalization hooks, sky/lighting includes, `shaders.properties`.

**Exit gate:** duplicate emitter writes produce one entry; power/area/PDF tests pass; overflow is visible and energy-safe; placing/removing a block or lamp invalidates the correct history; changing time of day does not leave stale converged lighting.

**Estimate:** 1–2 weeks.

### P3 — Primary surface and composition contract

**Goal:** ensure the first path vertex and final composition use the same material and energy conventions.

**Tasks**

- Extract shared material reconstruction used by the PT trace and `deferred4`, including normal/specular mapping and hardcoded material rules.
- Provide clean primary albedo for PT. Either conditionally avoid baking vanilla AO into the stored reflectance or add a dedicated clean material channel; apply gameplay overlays after transport where appropriate.
- Resolve where rain-puddle/material modifications occur so trace and final shading do not disagree.
- Define geometric versus shading normal handling. Sample only valid hemispheres and prevent mapped normals from sending paths through the geometric surface.
- Define the opaque BSDF model: diffuse substrate plus reflected specular lobe; metals have no diffuse term in PT. Do not reuse HYBRID's 0.5 metal-diffuse compromise and call it physical.
- Audit the existing roughness convention before VNDF sampling. In the current material code, perceptual roughness is already squared; do not square it twice.
- Add a PT composition branch that adds outgoing radiance directly, without multiplying by primary albedo/π again.
- Disable duplicate block, ambient, SSR, and environment terms only for PT-covered surfaces. Keep a coverage mask and a controlled boundary transition.
- Keep primary raster sun/highlight and emission according to §3.4, or move them into PT in a separate, explicitly tested change.

**Likely files:** `gbuffers_all_solid.fsh`, `material.glsl`, a shared primary decode include, `rtgi_trace.csh`, `diffuse_lighting.glsl`, `d4_deferred_shading.fsh`, reflection dispatch.

**Exit gate:** OFF/HYBRID captures remain within the approved regression tolerance; a flat white surface under known illumination matches the chosen radiometric convention; no albedo, Fresnel, or direct-light double counting is found.

**Estimate:** 4–7 days.

### P4 — Internal diffuse reference path tracer

**Goal:** prove explicit multi-bounce transport before adding specular complexity.

**Tasks**

- Add `include/lighting/rt/path_trace.glsl` behind an internal/test macro, not a public profile default.
- Reconstruct the primary vertex from the G-buffer and start with diffuse-only sampling.
- Support 1/2/4/8 scattering events with bounded loops and 1/2/4 SPP.
- At the primary vertex, evaluate emitter NEE but omit sun/moon NEE while raster direct sun is retained. At each secondary vertex, evaluate both emitter and sun/moon NEE. Trace a visibility ray and apply shared MIS weights in both cases.
- Continue with cosine sampling; add emitter/sky hits using the BSDF-side MIS weight.
- Apply Russian roulette only after the second scattering event, using bounded survival probability and throughput compensation.
- Keep reference output free of radiance clamps and probe-cache contributions. Add a separate guarded production path only after reference tests pass.
- Add finite-value checks and a magenta diagnostic for NaN/Inf or invalid PDF state.
- Write raw radiance, validity, path length, and survival metadata.
- Build an independent CPU reference over small analytic voxel scenes. It must not call or mechanically mirror the GLSL integrator.

**Likely files:** new `path_trace.glsl`, trace dispatch, debug views, `tools/shadercheck/pt_reference_test.py`, synthetic scene fixtures.

**Exit gate:** raw GPU PT at 1,024+ SPP agrees with the independent CPU reference within 5% on three prescribed surfaces, with confidence intervals reported; finite-bounce furnace tests pass; no NaN/Inf; bounce-count behavior matches the same-bounce reference.

**Estimate:** 1 week after P1–P3.

### P5 — GGX-VNDF and complete opaque BSDF transport

**Goal:** add specular paths without breaking the validated diffuse estimator.

**Tasks**

- Move/reuse VNDF sampling in a PT-safe include with an explicit PDF contract.
- Use the correct VNDF throughput weight, including the appropriate Smith masking/shadowing ratio; do not substitute a generic D·cosine/PDF expression.
- Implement the diffuse/specular lobe mixture and its combined PDF.
- Share Fresnel evaluation between BSDF evaluation and sampling; define dielectric, albedo-metal, and hardcoded-metal behavior.
- Decide whether an explicit multi-scatter compensation model is part of the BSDF. Do not add the existing approximate compensation on top of a VNDF estimator that already accounts for the same effect.
- Extend emitter/sun NEE and MIS to specular directions using the same light PDFs.
- Clamp roughness away from zero for the supported opaque model; delta mirrors/refraction are outside this stage.
- Replace existing reflection contribution on PT-covered surfaces rather than adding PT reflections to SSR.
- Add PDF normalization tests, grazing-angle tests, rough-metal furnace tests, and CPU/GPU glossy-scene comparisons.

**Likely files:** `bsdf.glsl`, shared VNDF code, `path_trace.glsl`, material decode, reflection composition, reference tests.

**Exit gate:** diffuse-only results remain unchanged within numerical tolerance; sampled PDFs match histogram/chi-square checks; glossy reference scenes agree within the agreed uncertainty; no reflection double count.

**Estimate:** 1–2 weeks.

### P6 — Progressive accumulation and PT-aware reconstruction

**Goal:** distinguish interactive denoising from actual sample convergence.

**Tasks**

- Add a static-state detector using camera translation/rotation, projection/FOV, viewport/TAAU scale, scene revision, lighting revision, and relevant option changes.
- Do not reset merely because TAA jitter or `frameCounter` advances; reconstruct the unjittered primary position correctly.
- Store actual accumulated SPP per pixel. For a valid static history, use `new_count = old_count + current_spp` and blend with `current_spp / new_count` until the configured cap.
- At the cap, stop increasing the effective count; either hold the result or use the equivalent bounded running-average update without claiming more than the cap.
- Reset on camera/scene/lighting invalidation. For motion, use reprojection and a bounded SVGF history rather than pretending the pixel is still progressively static.
- Define initialization sentinels for persistent images and reset on pack/resource/dimension changes.
- Separate the raw/reference accumulation view from the denoised display view.
- Define an auxiliary layout for sample count, depth/normal or material identity, raw luminance moments, path length, RR survival, and validity. Split images only when the budget permits.
- Correct second-moment accumulation: accumulate raw luminance squared with the proper temporal weight; do not blend toward the square of the filtered mean.
- Extend the filter with path/noise metadata and a conservative converged-pixel bypass. Keep geometric/material edge stops.
- Keep firefly suppression out of reference mode. In display mode, measure and document its bias.
- Add explicit views for accumulated SPP, reset reason, path length, RR survival, variance, and invalid paths.

**Likely files:** `rtgi_temporal.csh`, `rtgi_filter.csh`, new scene-state utility, buffer declarations, debug includes/lang, accumulation tests.

**Exit gate:** static sample count advances by the configured SPP and caps correctly; camera rotation/translation, block edits, emitter edits, and lighting changes reset as specified; frame-64 versus frame-256 difference meets the scene-specific target; converged pixels bypass filtering; HYBRID reconstruction does not regress.

**Estimate:** 1–2 weeks.

### P7 — Clipmap scene backend and production range

**Goal:** satisfy the original Stage 9 scene-range objective without rewriting the integrator.

**Tasks**

- Implement the missing Stage 4/5 scene work behind the P1 query interface.
- Recommended initial layout: three 128³ levels at 1/2/4 blocks per voxel, giving nominal 128/256/512-block coverage, with overlap and toroidal scrolling. Confirm dimensions against memory and image-budget measurements before committing.
- Define world-aligned origins, per-level generation, overlap bands, coarse-level construction, and update scheduling.
- Add DDA level selection/transitions and prevent double hits or gaps at seams.
- Use the finest valid level for near surfaces and a documented LOD policy for distant/secondary rays.
- Extend emitter construction and scene fingerprints across levels without duplicate light power.
- Define behavior when a ray leaves all levels: environment escape only if the scene is genuinely exhausted; otherwise use the marked coverage fallback.
- Investigate DH/Voxy voxelization only after native terrain coverage works. If no reliable hook exists, document the limitation rather than implying distant mod terrain is traced.
- Measure voxelization, scrolling, query, and memory cost separately from path tracing.

**Likely files:** voxel constants/storage/update, new clipmap includes/passes, ray-query backend, emitter builder, properties/settings, scene tests.

**Exit gate:** camera crosses level boundaries without GI popping beyond the agreed tolerance; thin-wall/seam tests pass; full/any-hit agreement holds at every level; memory stays within the approved budget; range and fallback are visible in diagnostics.

**Estimate:** 2–4 weeks. This is the largest readiness risk and may be split into its own reviewed milestone.

### P8 — Public mode, profiles, performance, and documentation

**Goal:** ship an honest, recoverable mode rather than an experimental default.

**Tasks**

- Introduce `RTGI_MODE = OFF | HYBRID | PATH_TRACED` and migrate shader/property/pass guards consistently.
- Preserve a compatibility mapping for existing `RAYTRACED_GI` configurations during migration, then remove redundant controls only after tests pass.
- Add PT controls: bounces, SPP, sample cap, and later reservoir toggle. Keep advanced controls grouped and documented.
- Initially keep all five profiles on their existing OFF/HYBRID behavior. Make PT opt-in. Consider Ultra/Extreme defaults only after the performance gate passes on the agreed target GPUs.
- Add the label “Path tracing (voxelised world; no entity/refraction transport)” or equivalent concise UI wording.
- Add `docs/known_limitations.md` and update README, debug docs, reference scenes, and language strings.
- Record per-pass and total-frame timings for HYBRID versus PT at matched resolution, scene, camera, and settings. Include voxelization/emitter/reconstruction cost, not just the trace pass.
- Enforce the original target of PT frame time ≤2.5× HYBRID as a release target, not an assumed result. If missed, lower the recommended profile or keep PT experimental.
- Verify all dimensions, TAAU scales, normal/specular mapping on/off, shadow settings, debug views, and image limits.
- Keep `HYBRID` and `OFF` reachable without a different pack.

**Likely files:** `settings.glsl`, `shaders.properties`, all world wrappers, `en_US.lang`, properties lint/matrix tests, README and testing docs.

**Exit gate:** all mode/bounce/SPP matrix cases compile; active image budgets pass; visual/numeric gates pass; performance report is reviewed; limitations are visible; rollback modes work.

**Estimate:** 1–2 weeks, excluding additional driver fixes.

### P9 — Optional first-hit reservoir resampling

**Goal:** reduce emitter-sampling variance only after ordinary NEE is correct.

**Tasks**

- Keep this feature off by default initially.
- Restrict it to the first diffuse scattering event, as specified by Stage 9.
- Draw a fixed number of power-weighted candidates and perform weighted reservoir selection with a mathematically defined target function and unbiased final weight.
- Use the resulting effective selection PDF in the existing MIS functions; do not treat the reservoir as a delta light with an invented PDF.
- A/B test equal ray budgets against ordinary NEE. Enable only if variance reduction outweighs cost and no bias/instability appears.
- Do not introduce temporal ReSTIR reuse in this stage; that adds visibility/reuse bias questions and is a separate project.

**Exit gate:** CPU/GPU agreement remains within tolerance, variance improves at equal cost on the lamp-heavy test, overflow behavior remains safe, and disabling the option exactly restores ordinary NEE.

**Estimate:** 3–7 days after P8.

## 6. Corrected numerical acceptance plan

The original Stage 9 and reference-scene documents contain furnace wording that must be corrected before implementation.

### 6.1 Furnace tests

1. **Uniform environment furnace:** a lossless white Lambertian surface under uniform environment radiance should return that radiance. Adding more bounces must not make it exceed the environment reference. This tests normalization and PDF cancellation.
2. **Closed emitter furnace:** a sealed white room with an emitter and no absorption has no finite steady-state solution. Do not use ρ=1 for an infinite-bounce energy test.
3. Use ρ=0.5 and ρ=0.8 rooms for finite-bounce tests. In a uniform-radiosity approximation, cumulative reflected energy after B bounces is proportional to `(1 - ρ^B) / (1 - ρ)`. Compare each bounce count with the reference truncated at the same B.
4. Do not require a four-bounce result to match a one-bounce reference, or universally require `E4 ≈ E8`. Their difference depends on albedo. Require monotonic behavior within stochastic uncertainty and convergence toward the appropriate finite/infinite reference.

### 6.2 Independent reference comparison

- Use small analytic scenes: white room, red-wall corridor, sealed torch room, red/blue emitters, thin wall, slab/stair seam, and glossy metal panel.
- Export linear radiance and exact scene/material/light/camera metadata. Avoid judging correctness from tone-mapped screenshots.
- Compare raw PT, not SVGF output, at 1,024 SPP minimum; use 4,096+ for difficult glossy/emitter cases.
- Report mean relative error, confidence intervals, chromaticity error, and invalid-pixel count.
- Initial gate: three prescribed opaque surfaces within 5% of the independent CPU result, with no unexplained systematic channel bias.
- Test each supported bounce count against the matching finite-bounce CPU result.

### 6.3 Energy, visibility, and color tests

- Sealed cave with no emitters: no sky/sun contribution above numerical noise.
- One torch: monotonic falloff and no camera-yaw dependence beyond sampling uncertainty.
- Red plus blue emitters: additive purple illumination in the shared region.
- Red wall/white floor/opposite wall: measurable second-bounce color transport.
- Thin wall and roof torch: no full-hit/any-hit visibility disagreement.
- Primary white surface: no repeated albedo multiplication or direct-light double count.
- PT coverage boundary: no abrupt energy step; fallback region is identifiable in debug output.

### 6.4 Progressive and reconstruction tests

- Static camera/scene/lighting: count reaches 64 and 256 correctly; frame-64 versus frame-256 mean difference is below 3% on the designated low-variance scenes.
- Camera translation, rotation, FOV change, resize/TAAU change, block edit, emitter edit, and lighting change each produce the expected reset/invalidation.
- At the sample cap, effective sample count does not grow without bound.
- No NaN/Inf in a long static run; invalid paths are counted and displayed.
- Firefly test: no denoised pixel above 30× the frame's 99.9th percentile in the designated 10,000-sample scene. This is a display-quality gate, not an unbiasedness proof.
- OFF/HYBRID regression captures stay within the baseline tolerance after each shared-infrastructure change.

### 6.5 Static and runtime matrix

At minimum, cover:

- Modes: OFF, HYBRID, PATH_TRACED.
- PT bounces: 1/2/4/8; SPP: 1/2/4; representative sample caps.
- RTGI resolutions and TAAU scales, including non-native viewport coordinates.
- Normal/specular mapping enabled and disabled.
- All three dimensions; shadow on/off where supported; representative voxel sizes/LODs.
- Debug off and each diagnostic view, checking active image count and format.
- Emitter-list empty, full, and overflow states.
- NVIDIA/AMD/Intel runtime reports on the agreed Iris version. Static compilation is necessary but not sufficient.

## 7. Performance and resource strategy

- Keep the reference path simple before optimizing. Measure DDA steps, path length, emitter candidates, and reconstruction separately where tooling allows.
- Start recommended interactive PT at half resolution, 1 SPP, 2–4 bounces; the original 1080p/1-SPP/4-bounce target remains a measured goal.
- Use bounded loops and early termination for zero throughput/invalid coverage.
- Build emitters/revisions only when needed; avoid scanning a 512³ volume every frame if a hierarchical or incremental builder is practical.
- Prefer clipmap storage over a single huge volume for range.
- Keep probe updates disabled in reference PT.
- Treat reservoir resampling as an optimization after correctness, not a prerequisite.
- Record total frame time and visible latency, not only trace-kernel time. The ≤2.5× HYBRID target must include all added passes and memory traffic.
- If the target is not met, publish a lower recommended tier or keep PT opt-in/experimental; do not hide the cost by changing resolution or comparison settings.

## 8. Main risks and mitigations

| Risk | Mitigation | Stop/recovery condition |
| --- | --- | --- |
| Iris image/SSBO synchronization differs from assumptions | Runtime spike first; image-backed emitter table; explicit pass boundaries | Do not enable progressive mode until write/read visibility is proven |
| Emitter table overflows | Overflow flag, hierarchical or BSDF-only fallback, lamp-heavy test | Never silently discard emitters in a correctness claim |
| Full-hit and any-hit disagree | Shared traversal/shape core and differential tests | Block NEE release until visibility tests pass |
| Material/color drift across bounces | One working-space contract and shared decoder | Stop reference comparison on systematic channel error |
| Primary composition double counts light | Explicit outgoing-radiance contract and term-by-term energy audit | Keep PT internal until flat-surface tests pass |
| Progressive history never resets or never converges | Scene/light fingerprints, per-pixel counts, reset-reason debug | Disable progressive mode, retain motion-aware reconstruction |
| Firefly clamps hide integrator bugs | Separate raw reference and denoised display paths | Judge unbiasedness only on raw output |
| Clipmap seams leak or double-hit | Overlap, transition tests, per-level diagnostics | Fall back to bounded volume backend |
| Image limit exceeded | Per-mode allocation table and linter gate | Repurpose buffers or use verified SSBO path before adding features |
| PT too expensive | Matched-setting profiling and conservative profiles | Keep HYBRID default; ship PT only as opt-in if necessary |
| Old tests pass but GLSL is wrong | Independent CPU scenes plus actual GPU captures | Do not use Python formula mirrors as transport evidence |

## 9. Review decisions requested

Recommended defaults are marked.

1. **Delivery order:** approve a bounded-volume internal reference PT before the full clipmap backend? **Recommended: yes.** The alternative is to complete all missing Stage 4/5 scene work before any PT loop, which delays estimator validation.
2. **Probe dependency:** keep reference PT independent of DDGI? **Recommended: yes.** A probe-assisted tail can be a later, explicitly approximate performance mode.
3. **Emitter storage:** start with an image-backed table and investigate SSBO separately? **Recommended: yes.**
4. **Profile defaults:** keep Ultra/Extreme on HYBRID until PT passes runtime/performance gates? **Recommended: yes.** This intentionally postpones the old roadmap's automatic Extreme/Ultra PT default.
5. **Range target:** approve three 1/2/4-block clipmap levels as the initial production target, subject to memory/seam tests? **Recommended: yes.** DH/Voxy coverage remains a separate investigation.
6. **Target platform:** specify the primary Minecraft/Iris version and the GPU(s) that define the performance gate. If unspecified, use the version already supported by this fork and require at least one NVIDIA/AMD/Intel runtime report before calling the mode production-ready.
7. **Physical scope:** accept the opaque, voxel-world, raster-primary boundary in §3, including no entity/refraction/media transport? **Recommended: yes for Stage 9.**

## 10. Proposed PR sequence and definition of done

Suggested reviewable PRs:

1. Baseline tooling/lint repair and capture protocol.
2. Shared scene-query/material contract and differential tests.
3. Emitter table, light PDFs, and scene/light revisions.
4. Primary material/composition cleanup with OFF/HYBRID regression proof.
5. Internal diffuse PT and independent CPU reference.
6. GGX-VNDF and complete MIS transport.
7. Progressive accumulation and PT metadata/reconstruction.
8. Clipmap backend and range/seam validation.
9. Public mode, profiles, limitations, and performance report.
10. Optional first-hit reservoir resampling.

Each PR must include: focused tests, full static matrix where practical, affected runtime captures, memory/image-budget impact, rollback behavior, and an updated list of known limitations. Do not combine the first path loop, clipmap rewrite, denoiser redesign, and profile migration into one unreviewable change.

**Stage 9 is done only when:**

- The public mode selects OFF/HYBRID/PATH_TRACED correctly in all supported worlds.
- The reference integrator passes independent numerical tests without denoising or probe feedback.
- The production backend meets the approved range and seam/visibility requirements.
- Progressive accumulation and invalidation behave correctly for camera, scene, and lighting changes.
- No double-counted lighting or unsupported physical claim remains in code/UI/docs.
- Static and runtime matrices pass, image budgets hold, and the performance report supports the chosen profile defaults.
- HYBRID and OFF remain complete, reachable fallback modes.
