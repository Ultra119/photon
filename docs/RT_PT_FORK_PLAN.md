# RT-first fork plan — RT by default, PT deferred

**Status:** proposal for review; planning only, no renderer implementation in this change.  
**Audited baseline:** `1c764b3` (`Improve DDGI relocation and firefly filtering`), 2026-10-29.  
**Supersedes as the active roadmap:** `docs/PT_IMPLEMENTATION_PLAN.md` for current work. That document remains a future PT reference, not the next implementation target.

## 1. Product decision

The fork will have two lighting modes only:

1. **RT Mode — default.** Gameplay-focused real-time ray-traced lighting with a reasonable performance/quality balance, while remaining configurable.
2. **PT Mode — deferred.** Quality-first path tracing, also configurable, implemented later.

There will be no third lighting concept:

- No `OFF` / original Photon lighting mode.
- No `HYBRID` SSGI + voxel GI mode.
- No analytic Photon sky/block/cave ambient used as a production fallback.
- No profile labelled “Path Tracing” until PT actually exists.

**RT is the default and the normal shipped renderer.** PT is reserved in the architecture but not exposed as a working user option until it passes its own implementation gates.

### 1.1 What “no hybrid” means here

Removed hybrid concept:

- Screen-space GI mixed with voxel GI.
- Previous-frame composite color used as a GI light source.
- Analytic vanilla lightmap/SH/cave ambient mixed with ray-traced GI.
- SSR used as the primary reflection transport with voxel rays only as a fallback.

Retained real-time rendering techniques:

- Rasterized primary visibility through the G-buffer.
- Direct sun/moon lighting and shadow maps, unless a later RT shadow-ray option replaces them.
- Sky/atmosphere/clouds/fog as environment radiance and post/effects.
- TAA, exposure, bloom, color grading, water refraction/absorption, and other non-GI post/effects.

This is still “RT Mode” in the real-time shaderpack sense: raster primary visibility plus ray-traced lighting transport. It is not a claim that every pixel is produced by a full path tracer.

### 1.2 What “no original Photon lighting” means here

The following may remain as **environment/material/post inputs**, but not as analytic surface-lighting fallbacks:

- Sky map radiance for ray misses and reflections.
- Sun/moon color and direct-light intensity.
- Block emitter color tables as source data for RT emitters.
- Fog/atmosphere scattering.
- Material emission.

The following must be removed or replaced as production lighting sources:

- Vanilla blocklight falloff on surfaces.
- Analytic skylight/SH ambient on surfaces.
- Cave ambient / minimum brightness hacks.
- Bounced-sunlight analytic terms.
- Interior-retention damping used to hide leaks.
- Handheld analytic light falloff, unless converted into an RT emitter.
- Directional lightmaps / vanilla AO used as transport substitutes.

Unsupported or out-of-range surfaces must use an RT-derived result: probe radiance, coarse scene radiance, sky/environment radiance, or an explicit diagnostic. They must not silently revert to original Photon lighting.

## 2. Current state that affects this change

The repository is not yet an RT-only renderer.

| Area | Current state | Required change |
| --- | --- | --- |
| Mode selection | `RAYTRACED_GI` boolean plus `RTGI_TRACER = VOXEL | HYBRID`. | Replace with a two-mode lighting contract: RT default, PT reserved. Remove OFF/HYBRID from public UI. |
| GI estimator | `hybrid_rtgi.glsl` can mix SSGI and voxel DDA. | Replace with an RT-only world-space estimator. Delete SSGI from production GI. |
| GI feedback | Legacy input can sample previous composite color. | Remove legacy composite feedback from RT lighting. |
| Opaque composition | RTGI is consumed only in `deferred4`; analytic block fallback can still add light. | Make RT the sole indirect/block-light source for opaque surfaces. |
| Forward surfaces | Translucents, DH water, Voxy translucents, entities/hand use analytic `get_sky_lighting` / `get_block_lighting`. | Add RT forward lighting, primarily probe-based with optional short voxel rays. |
| Block light | Vanilla lightmap fallback is enabled; radial point-light hack exists but is default-off/orphaned. | Replace with RT emissive transport through emitters/probes. |
| Sky ambient | Scalar ambient heuristic plus SH skylight path. | Use traced sky visibility / probe radiance; remove analytic surface ambient. |
| Cave lighting | `CAVE_LIGHTING_I` and `RTGI_CAVE_AMBIENT_SCALE` add fake ambient. | Remove; unlit caves should be dark unless RT emitters/sky reach them. |
| Reflections | SSR is primary; voxel RT is a fallback behind `RT_REFLECTIONS`. | Make voxel RT reflections the RT-mode transport; sky radiance is the miss result. Remove SSR as lighting transport. |
| AO | Vanilla AO, SSAO, GTAO, and cheap contact AO exist. | Decide RT-only AO policy; recommended: RT/probe-derived occlusion, with screen-space AO removed from production transport or kept only as an explicitly optional artistic effect. |
| Scene range | One cubic voxel volume, default 128³, no clipmap. | Provide an RT coverage contract; add clipmap/coarse coverage before claiming full-range RT-only lighting. |
| DDGI | One 32³ probe grid, relocation, fixed update count; no full moments/Chebyshev design. | Make DDGI a core RT component, improve stability/leak control, expose quality knobs. |
| Profiles | Extreme is labelled “Path Tracing” but is not PT. | Rename to RT Extreme; all profiles select RT until PT exists. |
| Tests/lint | Tests expect `RAYTRACED_GI` on/off and hybrid options; lint currently fails on orphaned `RTGI_POINT_LIGHT_RADIUS`. | Replace mode tests, remove dead options, restore green baseline. |

Baseline checks performed while preparing this plan:

- `voxel_packing_test.py`: passed.
- `dda_test.py`: passed its Python-side checks.
- `properties_lint.py`: failed due to orphaned `RTGI_POINT_LIGHT_RADIUS`; existing upstream warnings remain.
- GLSL compilation/dispatch tests: not validated here because no usable `glslang` is configured.
- In-game Iris validation: not performed here.

## 3. Target mode contract

### 3.1 RT Mode

RT Mode is the default gameplay renderer.

**Included:**

- Raster primary visibility from the G-buffer.
- World-space voxel ray-traced diffuse GI.
- DDGI/probe-based multi-bounce and emissive transport.
- RT-derived block/emitter lighting instead of vanilla blocklight.
- RT-derived sky/indirect occlusion instead of analytic ambient.
- Voxel ray-traced reflections with sky/environment miss radiance.
- Temporal/spatial reconstruction tuned for interactive play.
- Configurable quality: ray count, trace scale, probe quality, reflection quality, scene range, and advanced scene options.

**Not included:**

- SSGI.
- Previous-frame composite color as GI input.
- Analytic Photon ambient/block/cave fallback.
- Progressive unbiased path accumulation as the primary gameplay mode.
- Full entity/refraction/media path transport. Those remain limited or raster/forward effects unless explicitly implemented later.

RT Mode may be approximate and denoised. It should be stable, responsive, and playable. It does not need to be unbiased.

### 3.2 PT Mode

PT Mode is deferred.

When implemented later, it should be quality-first and configurable:

- Explicit path tracing over the shared RT scene backend.
- 1/2/4/8 bounces, SPP, sample cap, and optional reservoir/resampling controls.
- Progressive accumulation when camera/scene/lighting are static.
- GGX-VNDF specular transport, emitter/sun NEE, MIS, Russian roulette.
- Higher default cost and quality than RT.

For now:

- Reserve the mode enum and interface boundaries.
- Do not expose a broken PT option.
- Do not label any profile as PT.
- Do not implement PT-specific integrator code in this phase.

### 3.3 No OFF mode

There is no user-selectable original Photon lighting mode.

Failure behavior:

- If Iris/custom-image/compute requirements are unavailable, the pack should fail to load or show a clear diagnostic rather than silently using analytic lighting.
- If a surface is outside RT scene coverage, use RT-derived coarse/probe/environment radiance and expose coverage in debug views.
- If temporal history is invalid, use the current RT/probe estimate, not analytic fallback.
- If a feature is unsupported, remove/disable the feature or document the limitation; do not reintroduce original Photon lighting as a hidden substitute.

## 4. Target architecture

```text
Shared environment/material inputs
        |
        v
Lighting mode dispatch
        |
        +-- RT Mode (default, implemented now)
        |       |
        |       +-- RT scene backend: voxel volume -> clipmap
        |       +-- RT ray queries: full-hit / any-hit / visibility
        |       +-- RT diffuse GI trace
        |       +-- DDGI probe cache / emitter transport
        |       +-- RT forward lighting for translucents/entities
        |       +-- RT voxel reflections
        |       +-- RT temporal/spatial reconstruction
        |
        +-- PT Mode (reserved, deferred)
                |
                +-- Shared scene/material/light interfaces
                +-- Future explicit path integrator
                +-- Future progressive accumulation

Final composition:
  direct sun/moon + RT indirect/emitter + RT reflections + material emission
  no analytic Photon ambient/block/cave fallback
```

### 4.1 Shared interfaces to preserve for future PT

Even though PT is delayed, RT work should avoid painting the fork into a corner.

Create or stabilize these boundaries:

- `rt_scene`: voxel/clipmap storage, coverage, revisions.
- `rt_query`: nearest hit, any-hit, material at hit, validity.
- `rt_material`: one working-space material decode for primary and voxel surfaces.
- `rt_light`: sun/moon, sky/environment, emitter data.
- `rt_surface_lighting`: common surface lighting result structure.
- `rt_reconstruct`: temporal/spatial filtering, later extendable for PT metadata.

PT can later reuse the scene, material, light, and composition contracts without inheriting SSGI or analytic fallback logic.

### 4.2 RT lighting result contract

Define one explicit result type, for example:

```glsl
struct RtLighting {
    vec3 diffuse_indirect;   // outgoing diffuse indirect radiance
    vec3 specular_indirect;  // outgoing reflected radiance, if computed here
    vec3 emission;           // material/emitter exitance already in working space
    float coverage;          // 0..1 RT scene coverage/confidence
    float sky_fraction;      // optional debug/artist split, not a leak hack
};
```

Rules:

- All lighting values are linear and in the renderer working color space.
- Diffuse indirect is outgoing radiance, or the contract explicitly states irradiance and composition applies albedo/π exactly once. Do not mix conventions.
- Primary albedo is applied exactly once.
- Direct sun/moon is added separately and is not duplicated inside indirect GI.
- Material emission is added exactly once.
- Sky miss radiance comes from the environment/sky model, not scalar analytic ambient.
- Coverage/fallback information is available for debug and boundary blending.

### 4.3 RT forward lighting

Opaque deferred surfaces can consume a reconstructed RT buffer. Forward surfaces cannot safely sample the opaque RT buffer because it describes the background, not the translucent fragment.

RT forward lighting should therefore use:

- DDGI/probe irradiance at the forward surface position and normal.
- Optional short voxel rays for contact/emitter visibility at higher quality.
- Direct sun/moon shadowing as appropriate.
- RT reflection/refraction rules for water/translucents.

Consumers to migrate:

- `gbuffers_all_translucent.fsh`
- `dh_water.fsh`
- `voxy_translucent.glsl`
- entity/hand forward paths where applicable
- particles/spider eyes/other forward-lit programs if they currently use analytic diffuse lighting

Default forward RT should be probe-based for performance. Higher quality can add short rays.

### 4.4 RT reflections

RT Mode reflections should be world-space:

- Voxel/clipmap reflection rays.
- GGX/VNDF or roughness-aware sampling as quality allows.
- Sky/environment radiance on miss.
- Temporal reconstruction and roughness-aware filtering.
- No SSR as the primary transport and no previous composite color as the reflected scene source.

Water and smooth surfaces may still use raster refraction/absorption effects. Those are not GI transport and should be documented separately.

### 4.5 RT AO and occlusion — implemented in R6

Policy: **RT-derived occlusion only.** SSAO/GTAO were removed rather than kept as optional artistic effects.

- Large-scale indirect occlusion comes from traced RTGI/probe visibility.
- Contact detail comes from short cosine-weighted voxel visibility rays (`RT_AO_STRENGTH`, `RT_AO_RADIUS`, `RT_AO_RAYS`). The half-resolution result is temporally reconstructed and may darken direct diffuse/specular light when `RT_AO_IN_DIRECT` is enabled.
- Contact AO is **not** multiplied into RTGI or probe irradiance; that would double-count occlusion. It is neutral for the hand and outside voxel coverage.
- Vanilla vertex AO, directional lightmaps, normal-map lightmap modulation, SH skylight ambient, and AO-derived ambient SSS are removed from production RT.
- `ambient_color`/sky-map samples remain only for sky, fog, clouds, and water-media appearance, or as explicit environment radiance for RT misses. They are not analytic surface irradiance.
- Direct sun/moon, shadow maps/PCSS/VPS/SSRT, and cloud shadows remain the intentional direct-light boundary. With shadows explicitly disabled, the remaining lightmap-gated direct approximation is a user-selected no-shadow mode, not an indirect fallback.
- Material emission is added once in diffuse composition. Voxel emitters are separate transport sources for GI/reflections, not a second surface-emission addition.

Known R6 limitations: contact rays use opaque voxel sub-shapes, ignore same-cell concavity through the any-hit self-rejection, do not generate bent normals, and are not applied to forward translucent surfaces. Visual strength/radius tuning and disocclusion checks remain runtime work.

### 4.6 RT scene coverage — R7 first backend

Implemented backend: **three nested, camera-snapped clipmap levels** at 1/2/4 blocks per voxel, sharing `RT_CLIPMAP_SIZE` texels per side (default 128 → 128/256/512 blocks across).

- Coordinates are world-aligned and snapped to each level's voxel grid; texel addressing is positive-modulo toroidal.
- Iris clears the custom images at frame start, so this first backend is a **full rebuild from submitted terrain each frame**, not persistent incremental scroll reuse. That choice deliberately avoids stale cells without a block-edit revision feed.
- The shared scene query traces finest-first. A coarser level starts just outside the finer cube, so a surface/emitter is shaded once and glass transmittance is carried across levels without double attenuation.
- Fine level keeps sub-block shapes; coarse levels are conservative occupancy cubes with a representative material payload. Coarse cells do **not** sum emitter power.
- `GI_DEBUG_COVERAGE` colours surfaces by finest containing level (red/green/blue). Bright hue means a populated voxel record at the sampled point; dark hue means in-bounds but no record (air, non-voxelized material, or uncaptured terrain). Yellow tints the owning level's boundary band; magenta means outside all active clipmaps. The coverage dispatch runs before the fine-only bounds guard so medium/coarse rings are not falsely magenta.
- Image budget: 3 voxel + 6 RTGI + 3 DDGI = 12 custom images, +2 optional debug = 14/16.

Known limitations / follow-ups:
- Actual populated range is limited to terrain submitted by the shadow/gbuffer passes (`shadowDistance`, render distance). Coarse levels do not invent geometry beyond that.
- DH/Voxy terrain is not voxelized by this backend yet; those surfaces remain raster appearance while RT rays use vanilla submitted terrain, probes, or environment misses. No original Photon lighting fallback is introduced.
- Persistent toroidal scroll reuse, block-edit invalidation, and DH/Voxy coarse voxelization remain R7 follow-ups.

## 5. Settings and menu plan

### 5.1 Mode enum

Introduce a clear lighting mode enum:

```glsl
#define LIGHTING_MODE_RT 0
#define LIGHTING_MODE_PT 1
#define LIGHTING_MODE LIGHTING_MODE_RT
```

Public UI while PT is deferred:

- Show RT as the active/default mode.
- Hide PT or show it only as a disabled/coming-later entry if Iris UI supports that cleanly.
- Do not provide `OFF` or `HYBRID`.

Internal migration may temporarily keep compatibility aliases, but the shipped RT-only build must not expose them.

### 5.2 Proposed public RT settings

Names are provisional; final names should be short and consistent.

| Setting | Purpose | Proposed values/default |
| --- | --- | --- |
| `RT_RAY_COUNT` | Diffuse GI rays per traced pixel | 1 / 2 / 4 / 8; default 2 |
| `RT_SCALE` | RT trace resolution scale | 0.25 / 0.5 / 1.0; default 0.5 |
| `RT_PROBE_RAYS` | Probe update rays | 8 / 16 / 32 / 64; default 16 |
| `RT_PROBE_UPDATES` | Probes updated per frame | 64 / 128 / 256 / 512 / 1024; default measured |
| `RT_PROBE_HYSTERESIS` | Probe temporal stability | 0.50–0.95; default measured |
| `RT_INDIRECT_INTENSITY` | Artistic indirect scale | default 1.00 |
| `RT_EMISSIVE_INTENSITY` | Artistic emitter scale | default 1.00 |
| `RT_REFLECTION_RAYS` | Reflection rays/pixel or quality tier | 0 / 1 / 2 / 4; default 1 |
| `RT_REFLECTION_SCALE` | Reflection trace scale | 0.5 / 1.0; default 0.5 |
| `RT_AO_STRENGTH` | RT contact occlusion strength | 0.00–1.00; default measured |
| `RT_SCENE_RANGE` | Clipmap/coverage tier | near / medium / far; default measured |
| `RT_VOXELIZE_ENTITIES` | Optional dynamic entity voxelization | off by default |
| `RT_HANDHELD_LIGHT` | Dynamic held-light emitter | on if implemented, otherwise hidden |
| `GI_DEBUG` / debug views | Diagnostics | off by default |

Advanced/developer settings may expose voxel volume size/center, probe grid details, clamp/debug controls, and scene backend selection. Avoid exposing multiple overlapping brightness/intensity knobs.

### 5.3 Settings to remove or replace

Remove public UI and eventually code for:

- `RAYTRACED_GI` as an on/off toggle.
- `RTGI_TRACER`, `RTGI_TRACER_HYBRID`, `RTGI_TRACER_VOXEL`.
- `RTGI_SSGI_LOCAL_LIGHT_SCALE`.
- `RTGI_GI_INPUT`, especially legacy composite feedback.
- `RTGI_DIRECT_BLOCK_FALLBACK`.
- `RTGI_INTERIOR_RETENTION`.
- `RTGI_CAVE_AMBIENT_SCALE` and `CAVE_LIGHTING_I` as surface lighting.
- `RTGI_POINT_LIGHT_STRENGTH`, `RTGI_POINT_LIGHT_RADIUS`, and the radial injection hack.
- `RTGI_VANILLA_LIGHTMAP_PROPAGATION` if still present/dead.
- `RTGI_MULTIBOUNCE_OFF` as a public return to non-RT behavior. RT may have low probe quality, but not analytic fallback.
- Duplicate `RTGI_BRIGHTNESS` / `RTGI_INTENSITY` controls; consolidate into one indirect scale.
- `RT_REFLECTIONS` as a boolean fallback toggle; replace with RT reflection quality.
- SSR transport controls if SSR is removed from RT Mode.
- `SH_SKYLIGHT` as analytic surface ambient, unless repurposed strictly for environment/fog and audited.
- `BOUNCED_LIGHT_I` analytic bounced sunlight.
- `VANILLA_AO`, `DIRECTIONAL_LIGHTMAPS` as RT transport substitutes.
- Extreme profile label “Path Tracing”.

Keep but audit:

- Sun/moon color/intensity controls.
- Sky/atmosphere/cloud/fog controls.
- Material emission controls.
- Blocklight color tables as emitter source data, not vanilla surface falloff.
- Shadow controls, TAAU, exposure, bloom, color grading, water effects.

### 5.4 Profile plan

All profiles select RT until PT exists.

Provisional starting points, subject to measurement:

| Profile | RT scale | GI rays | Probe rays | Reflections | Intent |
| --- | ---: | ---: | ---: | --- | --- |
| Low RT | 0.25–0.5 | 1 | 8 | sky-only or 1 low-res ray | Playable low-end RT |
| Balanced RT / default | 0.5 | 2 | 16 | 1 half-res ray | Default gameplay balance |
| High RT | 0.5–1.0 | 4 | 32 | 2 rays | Higher quality |
| Ultra RT | 1.0 | 4–8 | 64 | 4 rays | High-end quality |
| Extreme RT | 1.0 | 8 | 64+ | 4 rays, larger range | Maximum RT, not PT |

Do not ship these as final until frame-time and visual testing confirms them. The default profile must be RT and must not depend on analytic fallback.

## 6. Removal and retention inventory

### 6.1 Delete or replace

| Item | Action |
| --- | --- |
| `include/lighting/rt/hybrid_rtgi.glsl` | Replace with RT-only estimator; delete hybrid dispatch. |
| `include/lighting/rt/ssgi.glsl` | Delete from production GI. |
| SSGI hit-source debug | Replace with RT hit/coverage/probe/emitter diagnostics. |
| Legacy GI input from composite color | Delete. |
| `get_block_lighting` analytic surface path | Replace with RT emitter/probe lighting. |
| `get_sky_lighting` analytic surface path | Replace with RT sky/probe lighting. |
| Cave ambient term | Delete. |
| Interior retention hack | Delete after visibility/probe leak control is adequate. |
| Radial point-light injection | Delete; replace with emitter/probe transport. |
| Handheld analytic falloff | Replace with dynamic RT emitter or remove until supported. |
| SSR primary reflection transport | Replace with RT voxel reflections. |
| Vanilla AO / directional lightmaps in transport | Remove or isolate as non-transport optional effects if approved. |
| Hybrid/SEUS/PTGI marketing strings | Rewrite around RT Mode and deferred PT. |
| Tests expecting OFF/HYBRID | Replace with RT/PT-reserved mode tests. |

### 6.2 Retain

| Item | Reason |
| --- | --- |
| Raster G-buffer primary visibility | RT Mode is real-time ray-traced lighting, not full path-traced primary visibility. |
| Direct sun/moon and shadow maps | Direct lighting remains valid; RT can later add ray-traced shadows as an option. |
| Sky map / atmosphere radiance | Environment source for RT misses and reflections. |
| Fog/clouds/volumetrics | Effects/environment, not analytic surface GI fallback. |
| Material emission | Physical source term. |
| Water refraction/absorption | Raster/forward effect, documented separately from transport. |
| TAA/post/exposure/color grading | Image pipeline. |
| labPBR/material decoding | Shared material system. |
| DH/Voxy rendering support | Keep rendering; migrate lighting to RT forward/probe paths. |

## 7. Work packages

Estimates are focused engineering effort, not delivery promises. Hardware/runtime validation can dominate.

### R0 — Freeze contract, baseline, and tooling

**Goal:** make the RT-only direction explicit and establish a green baseline.

Tasks:

- Approve the RT/PT-only product contract in this document.
- Record current pure-voxel RT baseline captures and timings where possible.
- Fix the orphaned `RTGI_POINT_LIGHT_RADIUS` lint failure.
- Install/pin `glslang`; make missing compiler validation fail CI.
- Add a removal inventory test scaffold for forbidden hybrid/analytic symbols.
- Define target hardware/Iris version and default performance target.
- Mark the old PT plan as deferred reference.

Exit gate:

- Baseline lint/compile checks are green or have approved exceptions.
- The team agrees on what “RT-only” permits and forbids.
- No renderer behavior change yet.

Estimate: 1–3 days.

### R1 — Two-mode scaffold and RT default UI

**Goal:** introduce the public mode contract without pretending PT exists.

Tasks:

- Add `LIGHTING_MODE_RT` / `LIGHTING_MODE_PT` enum.
- Make RT the default compile-time and profile mode.
- Hide/reserve PT; remove OFF/HYBRID from public UI.
- Migrate pass/image guards from `RAYTRACED_GI` to the mode contract.
- Rename Extreme profile to RT Extreme.
- Update language strings and properties lint expectations.
- Keep temporary internal migration guards only where needed; track them for deletion.

Exit gate:

- All public profiles select RT.
- No public OFF/HYBRID/PT-working claim.
- Static matrix covers RT default and reserved-PT compile boundaries.

Estimate: 2–4 days.

### R2 — RT-only opaque GI core

**Goal:** remove SSGI/hybrid from opaque indirect lighting.

Tasks:

- Replace `hybrid_rtgi.glsl` with an RT-only estimator, e.g. `rt_gi.glsl`.
- Delete SSGI include/call path and SSGI settings.
- Remove legacy composite-color GI input.
- Use world-space voxel rays plus DDGI/probe transport.
- Define RT sky-miss radiance from the environment model.
- Make hit-source debug report RT voxel/probe/sky/coverage, not SSGI.
- Fix full-hit/any-hit consistency where required by RT visibility.
- Establish one radiometric convention for RT diffuse output.

Exit gate:

- Opaque RT GI contains no SSGI or previous-composite feedback.
- Camera rotation does not change lighting beyond sampling noise.
- Static compile/dispatch tests prove SSGI is absent.

Estimate: 4–7 days.

### R3 — RT block/emitter lighting and DDGI core

**Goal:** replace vanilla blocklight and the radial hack with RT emitter transport.

Tasks:

- Make DDGI/probe cache a core RT component, not an optional return to analytic lighting.
- Add configurable probe update count and quality.
- Improve probe relocation, backface/visibility weighting, and stability.
- Add moments/Chebyshev or another leak-control mechanism if required by tests.
- Build deduplicated emissive voxel/probe source data.
- Support small emitters and full-block emitters with explicit area/power models.
- Remove `RTGI_DIRECT_BLOCK_FALLBACK` from opaque composition.
- Remove radial point-light injection and its settings.
- Convert handheld lighting into a dynamic RT emitter or hide/remove it until supported.
- Remove cave ambient and interior-retention hacks after leak tests pass.

Exit gate:

- Torch/lava/lamp rooms are lit by RT emitters/probes, not vanilla blocklight.
- Sealed unlit caves are dark.
- Red/blue emitter blending works.
- No roof-torch leak through vanilla lightmap.
- Handheld light is either RT-derived or explicitly unavailable.

Estimate: 1–2 weeks.

### R4 — RT forward lighting for translucents, entities, DH/Voxy

**Goal:** eliminate analytic Photon lighting on forward surfaces.

Tasks:

- Add `rt_forward_lighting` using probe irradiance and optional short voxel rays.
- Migrate `gbuffers_all_translucent.fsh`.
- Migrate `dh_water.fsh` and `voxy_translucent.glsl`.
- Migrate entity/hand/particle forward lighting where applicable.
- Ensure translucent surfaces do not sample opaque-background RTGI as their own lighting.
- Add RT coverage behavior for distant/mod terrain.
- Keep direct sun/shadow and material emission rules consistent.
- Add tests for water, stained glass, particles, entities, and DH/Voxy surfaces.

Exit gate:

- Forward-lit surfaces no longer call analytic `get_sky_lighting` / `get_block_lighting` as production fallback.
- Water/translucents receive RT-derived ambient/emitter light.
- Entities are not lit by a hidden original Photon path.
- Out-of-coverage behavior is RT-derived and debuggable.

Estimate: 1–2 weeks.

### R5 — RT reflections and SSR removal

**Goal:** make reflections consistent with the RT-only concept.

Tasks:

- Replace SSR-primary reflection transport with voxel/clipmap RT reflections.
- Use sky/environment radiance on miss.
- Add roughness-aware sampling and temporal reconstruction.
- Remove or disable SSR transport controls in RT Mode.
- Keep water refraction/absorption as documented raster effects.
- Ensure reflections do not sample previous composite color as scene transport.
- Add reflection quality settings and profile defaults.

Exit gate:

- RT reflections work off-screen and behind the camera via the voxel scene.
- No SSR/previous-composite dependency remains in RT reflection transport.
- Reflection cost is measurable and configurable.

Estimate: 4–10 days.

### R6 — RT AO and direct-light boundary cleanup

**Status:** implemented and statically validated; runtime visual/disocclusion testing pending.

**Goal:** remove remaining non-RT transport substitutes and define what direct lighting remains.

Completed:

- Implemented the RT-derived occlusion policy in §4.5 with short voxel contact rays and explicit quality profiles.
- Removed vanilla AO, directional lightmaps, SSAO/GTAO, the SH skylight compute pass/utility, and AO-derived ambient SSS.
- Kept direct sun/moon and shadow maps as the documented direct-light boundary; kept environment color only for sky/fog/media/RT misses.
- Verified material emission is added once in diffuse composition.
- Added RT boundary/dispatch guardrails and made the shader checker propagate glslang failure codes.

Exit gate:

- RT lighting does not require vanilla AO or SH ambient to look correct.
- Direct sun/moon remains intentional and documented.
- No analytic bounced/cave/ambient surface term remains in production RT.
- Runtime check: contact strength/radius, moving edges, hand neutrality, and uncovered/LOD surfaces behave acceptably.

Estimate: 3–7 days.

### R7 — RT scene coverage and clipmap backend

**Status:** first backend implemented and statically validated; runtime seam/coverage testing pending. Persistent scroll reuse and DH/Voxy voxelization remain follow-ups.

**Goal:** make RT-only lighting viable beyond the current small voxel cube.

Completed:

- Defined RT coverage tiers (`RT_CLIPMAP_SIZE`, `RT_COVERAGE_LEVELS`) and added `GI_DEBUG_COVERAGE`.
- Implemented three nested clipmap levels behind the shared scene query, with finest-first ownership and no duplicate emitter/transmittance accounting.
- Added camera-snapped toroidal coordinates, per-frame clear/rebuild revision policy, seam/energy/image-budget tests.
- Extended GI/reflection/probe transport across active levels; removed the single 512³ volume option.
- Documented DH/Voxy and shadow-distance population limits (§4.6).

Remaining:

- Persistent incremental toroidal scroll updates with reliable block-edit invalidation.
- DH/Voxy coarse voxelization or an explicit RT coarse/probe coverage path for LOD terrain.
- Runtime validation of seams, camera motion, populated range, and performance cost.

Exit gate:

- RT lighting remains RT-derived across camera motion and level boundaries.
- No original Photon fallback appears at range.
- Coverage boundaries are visible in debug and acceptable in normal play.
- Memory/image budget passes.

Estimate: 2–4 weeks.

### R8 — Reconstruction, performance, and profile tuning

**Goal:** make RT the playable default.

Tasks:

- Tune temporal/spatial reconstruction for RT-only signals.
- Remove PT-specific progressive accumulation from the current scope.
- Keep disocclusion responsive; avoid ghosting from probe/emitter changes.
- Measure trace, probe, emitter, reflection, forward lighting, and reconstruction costs separately where possible.
- Tune Low/Balanced/High/Ultra/Extreme RT profiles.
- Validate TAAU scales and resolution scales.
- Enforce image/format budgets.
- Add performance regression capture protocol.

Exit gate:

- Default RT profile meets the agreed target hardware/frame budget.
- Quality knobs scale cost predictably.
- No profile depends on analytic fallback.
- Extreme is labelled RT, not PT.

Estimate: 1–2 weeks.

### R9 — Delete original lighting and hybrid remnants

**Goal:** make the codebase match the product contract.

Tasks:

- Delete dead hybrid/SSGI files, settings, lang strings, debug paths, and tests.
- Delete analytic surface-lighting fallback functions or reduce them to explicitly non-production test utilities if absolutely needed.
- Remove temporary migration guards.
- Remove orphaned options and stale profile tokens.
- Update properties lint to forbid OFF/HYBRID/SSGI/analytic fallback in production RT.
- Update README and known-limitations docs.
- Confirm no public UI advertises original Photon lighting or working PT.

Exit gate:

- Forbidden-symbol tests pass.
- Public mode surface is RT-only with PT reserved.
- No dead RTGI/hybrid options remain.
- Documentation matches behavior.

Estimate: 4–7 days.

### R10 — RT-only release validation

**Goal:** ship RT as the default fork renderer.

Tasks:

- Run full static matrix: worlds, TAAU, normal/specular maps, shadow settings, debug views, RT quality tiers.
- Run runtime scenes: sealed cave, torch room, colored emitters, red-wall bleed, thin wall, water/translucents, entities, DH/Voxy, Nether/End, camera rotation, range boundary.
- Verify no analytic fallback through debug views and code-path tests.
- Record performance on target GPUs.
- Record memory/image usage.
- Publish known limitations.
- Keep PT deferred plan intact for later work.

Exit gate:

- RT is default and complete enough for gameplay.
- No hybrid/original Photon lighting remains as production transport.
- PT is not advertised as implemented.
- Performance and visual gates pass.

Estimate: 1 week, excluding driver fixes.

## 8. Validation plan

### 8.1 Static/code-path gates

Add tests that fail if production RT shaders contain:

- SSGI trace calls or SSGI settings.
- Hybrid tracer dispatch.
- Legacy composite GI input.
- Analytic `get_sky_lighting` / `get_block_lighting` surface fallback.
- Cave ambient / interior retention / radial point-light hack.
- Public OFF/HYBRID mode tokens.
- SSR primary reflection transport in RT Mode, if SSR removal is approved.
- Profile labels claiming PT before PT exists.

Also test:

- RT is default in settings and all profiles.
- PT is reserved/hidden, not selectable as working.
- Every public RT setting is read by shader code.
- Image declarations match active RT passes and stay within Iris limits.
- All world variants compile.

### 8.2 Visual/runtime gates

Required scenes:

1. **Sealed unlit cave:** black or near-black except numerical noise; no cave ambient.
2. **Torch room:** monotonic RT emitter falloff, no vanilla lightmap dependency.
3. **Roof torch / thin wall:** no leak to interior.
4. **Red wall / white floor / opposite wall:** colored multi-bounce transport.
5. **Red + blue emitters:** additive blending.
6. **Camera rotation:** fixed surface lighting stable within noise.
7. **Water/translucent glass:** RT forward lighting, no opaque-background GI reuse.
8. **Entities/hand:** RT-derived lighting or explicitly documented limitation; no hidden analytic path.
9. **Reflections:** off-screen/behind-camera voxel reflections, sky miss, no SSR transport.
10. **Range boundary:** RT-derived coarse/probe/environment behavior, no original Photon fallback.
11. **Nether/End:** RT lighting works without Overworld-only analytic ambient.
12. **DH/Voxy:** lighting remains RT-derived or documented coarse coverage.

### 8.3 Performance gates

Before R0 completion, define:

- Target Minecraft/Iris version.
- Reference GPU(s).
- Target resolution and frame-rate goal for Balanced RT.
- Maximum acceptable RT overhead versus the current pure-voxel baseline.

Measure:

- Total frame time.
- GI trace cost.
- Probe update cost.
- Emitter/scene update cost.
- Reflection cost.
- Forward RT lighting cost.
- Reconstruction cost.
- VRAM/image budget.

Do not claim “reasonable performance” without a measured default profile.

### 8.4 Numerical sanity gates

RT is allowed to be approximate, but it should still pass basic energy checks:

- White furnace under uniform environment does not gain energy with more probe bounces.
- Closed emitter room with ρ < 1 converges/stabilizes rather than diverging.
- Primary albedo is applied once.
- Direct sun is not duplicated in indirect GI.
- Emitter power is not duplicated by probes and direct emitter hits.
- Color space is consistent across voxel, primary, probe, and reflection paths.

## 9. Performance and resource strategy

- Default RT should favor half-resolution tracing, modest ray counts, probe caching, and aggressive but stable reconstruction.
- Probe updates should be amortized and configurable.
- Reflections should default to lower cost than diffuse GI unless profiling shows otherwise.
- Forward RT lighting should default to probe lookups, not per-pixel many-ray tracing.
- Clipmap storage should replace huge single-volume range increases.
- Keep the 16-image limit in mind for every mode/debug/profile combination.
- Remove SSGI/legacy feedback buffers if they become unused.
- Do not allocate PT-specific progressive buffers yet.
- Keep debug images gated.

Provisional default target:

- 1080p output.
- RT diffuse at 0.5 scale.
- 2 GI rays per traced pixel.
- 16 probe rays with amortized updates.
- 1 half-res reflection ray or sky-only on Low.
- Probe-based forward lighting.

This is a starting point, not a promise. R8 must validate it.

## 10. Risks and mitigations

| Risk | Mitigation | Stop condition |
| --- | --- | --- |
| Removing analytic fallback before forward RT exists causes black water/entities | Implement R4 before public RT-only release; keep temporary internal guards tracked for deletion | Do not ship if forward surfaces are unlit or secretly analytic |
| DDGI leaks without vanilla fallback/interior retention | Improve visibility weights, moments, relocation, emitter tests | Keep RT internal until sealed-cave/thin-wall tests pass |
| Small emitters are too dim without vanilla blocklight | Deduplicated emitter/probe transport, area/power model | Torch room fails |
| RT reflections too expensive | Lower default reflection rays/scale, sky-only Low profile | Default profile misses frame budget |
| Range outside voxel volume becomes black or fake | Clipmap/coarse probe coverage, coverage debug | No RT-derived far behavior |
| Image limit exceeded | Per-mode allocation table, remove SSGI/legacy buffers, gate debug | Properties lint fails |
| “No hybrid” interpreted as no raster at all | Clarify RT = raster primary + ray-traced lighting; PT is future quality mode | Product contract disagreement |
| PT scope creep delays RT | Hide/reserve PT, no PT integrator work in this roadmap | Any PT implementation task enters RT milestone |
| Old settings survive as dead UI | Properties lint + forbidden-symbol tests | Orphaned option remains |
| Static tests pass but runtime is wrong | GPU captures and scene gates | No runtime evidence before release |

## 11. Review decisions requested

Recommended answers are marked.

1. **RT definition:** approve RT as raster primary visibility plus world-space ray-traced lighting, not full path-traced primary visibility? **Recommended: yes.**
2. **Direct sun/shadows:** keep direct sun/moon and shadow maps in RT Mode while removing analytic indirect/ambient/block fallback? **Recommended: yes.**
3. **SSR:** remove SSR as RT reflection transport and use voxel RT reflections + sky miss? **Recommended: yes.** If SSR is kept, it must be explicitly optional and not the primary RT concept.
4. **AO:** use RT/probe-derived occlusion and remove vanilla AO/directional lightmaps from transport? **Recommended: yes.** Decide whether SSAO/GTAO may remain as optional artistic effects.
5. **Forward surfaces:** require RT-derived probe/short-ray lighting for translucents/entities/DH/Voxy before public RT-only release? **Recommended: yes.**
6. **Handheld lights:** convert to dynamic RT emitters, or hide/remove until supported? **Recommended: convert if feasible; otherwise hide.**
7. **PT UI:** hide/reserve PT until implemented, with no “Path Tracing” profile label? **Recommended: yes.**
8. **Scene range:** require clipmap/coarse RT coverage before calling the fork fully RT-only, or allow a bounded RT release with explicit range limitations? **Recommended: bounded internal RT first, public RT-only after coverage is acceptable.**
9. **Default profile:** approve Balanced RT as the default target, subject to measured performance? **Recommended: yes.**
10. **Target hardware:** specify the primary GPU/Iris version for the performance gate. If unspecified, require at least one midrange NVIDIA/AMD/Intel runtime report before release.

## 12. Proposed PR sequence

1. Plan approval, baseline lint/tooling repair, PT plan marked deferred.
2. Lighting-mode scaffold, RT default profiles/UI, PT reserved.
3. RT-only opaque GI estimator; remove SSGI/legacy GI feedback.
4. RT emitter/DDGI block lighting; remove vanilla block fallback and radial hack.
5. RT forward lighting for translucents/entities/DH/Voxy.
6. RT voxel reflections; remove SSR transport.
7. RT AO/direct-light boundary cleanup; remove analytic ambient/cave/bounced terms.
8. RT scene coverage/clipmap backend.
9. Reconstruction/performance/profile tuning.
10. Delete hybrid/original-lighting remnants; update docs/lang/tests.
11. RT-only release validation.
12. Later: PT implementation using the deferred PT plan and shared interfaces.

Each PR should include:

- Affected settings/menu changes.
- Static matrix results.
- Runtime captures for relevant scenes.
- Performance/memory impact where relevant.
- Removal of dead options introduced or exposed by the change.
- Confirmation that no hidden analytic fallback was added.

## 13. Definition of done for this concept change

The fork is RT-first when:

- RT is the default and all shipped profiles use RT.
- There is no public OFF/HYBRID/original Photon lighting mode.
- PT is reserved/deferred and not advertised as working.
- Opaque GI is world-space RT, not SSGI hybrid.
- Block/emitter lighting is RT-derived, not vanilla lightmap fallback.
- Sky/ambient lighting is RT-derived, not analytic Photon surface ambient.
- Cave ambient/interior-retention/radial hacks are gone.
- Forward surfaces use RT-derived lighting or have explicit documented limitations.
- Reflections use RT voxel transport, not SSR-primary hybrid transport.
- Range/coverage behavior is RT-derived and debuggable.
- Dead hybrid/analytic options, strings, and tests are removed.
- Default RT performance is measured and acceptable on the agreed target hardware.

## 14. PT handoff after RT is complete

When RT is stable, resume PT from the deferred plan with these constraints:

- PT is a second quality-first mode, not a replacement for RT default.
- PT reuses the RT scene/material/light/query interfaces.
- PT does not reintroduce SSGI or analytic Photon fallback.
- PT adds explicit paths, progressive accumulation, NEE/MIS, GGX-VNDF, and higher sample counts.
- PT profiles are introduced only after PT passes correctness and performance gates.
- RT remains available for gameplay.
