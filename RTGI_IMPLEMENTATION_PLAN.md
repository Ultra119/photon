# Photon RTGI / Path-Tracing Fork — Implementation Plan

**Document status:** first deliverable (plan, not implementation)
**Branch:** `arena/1996cb09-photon`
**Fork HEAD at time of audit:** `e56ae19` ("Refine voxel GI lighting and redstone handling"), plus one P0 fix committed during this audit (`216b896`)
**Upstream fork point:** `6e67b36e818bacde0304edd49f28e2bb70e33f04` — *Use Distant Horizons LOD block textures when Iris provides them (#691)*, 2026-10-23, which is also the current `main` of `sixthsurge/photon`
**Iris reference:** branch `26.3`, commit `671a5c87747d33983d7ed659461a64f46dfcb1f0` ("fix mixin injection (fix glowing with end portal) (#3359)", 2026-10-08). Iris `MOD_VERSION = 1.11.6`, `MINECRAFT_VERSION = 26.3`
**SEUS reference:** `SEUS PTGI HRR Test 2.1 GFME 1.22 RC1` (ZIP, 446 entries) — inspected as a historical reference only

Evidence labels used throughout:

- **[VERIFIED]** — established by reading code in this workspace, by building `glslang 15.0.0` and compiling the shaders, or by reading Iris 26.3 source.
- **[MEASURED]** — produced by a tool run during this audit (numbers reproducible with the commands in §8.5).
- **[ASSUMPTION]** — plausible but not confirmed in this environment (no Minecraft/Iris runtime and no GPU are available here).
- **[PROPOSED]** — a design decision made by this plan, not a property of the existing code.

---

## 1. Executive summary

### 1.1 What exists today

The fork already contains a working, non-trivial GI implementation: a **voxelized world grid** written from the shadow-pass vertex stream, a **screen-space GI raymarcher**, a **single-bounce voxel DDA**, and a **three-pass compute pipeline** (`rtgi_trace` → `rtgi_temporal` → `rtgi_filter`) running at half resolution with 2 rays per pixel [VERIFIED].

That is a legitimate hybrid SSGI + voxel-GI renderer. It is **not** a path tracer, and it does not deliver physically plausible multi-bounce transport. Its most damaging defects are architectural, not cosmetic:

1. **The GI estimator is a closed feedback loop through last frame's final image.** `rtgi_trace.csh` samples `colortex5`, which is written by `c4_taa_exposure.fsh` (`/* RENDERTARGETS: 0,5 */`) — i.e. the *TAA-resolved composite scene colour of the previous frame*, containing direct light, GI, specular, fog and translucency from that frame [VERIFIED]. GI therefore depends on its own previous output and on what the camera happened to see. This single fact explains the reported "light only appears when I move the camera" and "light appears behind the source" symptoms, and no amount of denoiser tuning can remove it. The audit log in `RTGI_AUDIT.md` independently reached the same conclusion in Steps 9–11 and papered over it with damping factors (`RTGI_SSGI_LOCAL_LIGHT_SCALE = 0.00`, `RTGI_CAVE_AMBIENT_SCALE = 0.00`).
2. **Seam material for absent transport is being supplied by vanilla's light engine.** Block light in the voxel grid is the Minecraft lightmap value (`light_levels.x`) tinted by a per-emitter colour, and `diffuse_lighting.glsl` additionally adds `mc_block` on top of RTGI. Direct block light is therefore counted twice in the common case, and "coloured bleeding" is a tinted 15-level scalar, not coloured transport [VERIFIED].
3. **There is exactly one bounce.** `trace_voxel_dda` returns the direct lighting of a single hit surface; `accumulated_light` is a non-occluded accumulation of a radial light field that is disabled by default. Nothing re-feeds bounce *n* into bounce *n+1* [VERIFIED].
4. **The scene representation cannot grow.** `VOXEL_VOLUME_SIZE` is a cubic `R32UI` 3D image; 128³ = 8 MiB, 256³ = 64 MiB, 512³ = **512 MiB** [VERIFIED — `image.voxel_img` in `shaders.properties` plus `layout(r32ui)` in `shadow.vsh`]. The option is advertised up to 512. A clipmap solves this for 4 MiB total (see §3.3).
5. **The build was broken on strict compilers.** The last commit introduced `#if RTGI_POINT_LIGHT_STRENGTH > 0` in three places, but the option is a float slider defined as `0.00`. Float literals are illegal in GLSL preprocessor expressions, so **every** program including `voxel_dda.glsl` or `voxel_update.glsl` failed to compile under `glslang`/Mesa, in all default profiles [MEASURED: 120 of 308 compute/fragment cases failed before the fix]. NVIDIA's lenient preprocessor masked it in the author's testing. Fixed during this audit in `216b896`; both static matrices are now green.

### 1.2 Recommended architecture

**One scene core, one denoiser, two estimators** — not two separate shader packs.

- **Scene core:** a **4-level voxel clipmap** (64³ texels per level, spacing 1/2/4/8 blocks, covering 512 blocks in ~4 MiB) written by a dedicated, decoupled voxelization stage, storing albedo, emission, block ID, flags and light levels in one 32-bit payload. This replaces `VOXEL_VOLUME_SIZE` and the `imageAtomicMax` racing.
- **Multi-bounce:** a **DDGI-style probe radiance cache** (irradiance + octahedral depth moments) over the same clipmap, updated round-robin, giving ~4 effective bounces, view-independent stability, coloured bleeding and emissive illumination. This *replaces* the radial point-light injection hack, which is the same idea with the occlusion test removed and made order-dependent.
- **RTGI mode:** per-pixel **1–2 ray hybrid trace** (short screen-space for detail + clipmap DDA for off-screen) for near-field detail, combined with the probe cache for multi-bounce. Honest description: *single-bounce stochastic GI with a multi-bounce radiance cache; not unbiased.*
- **PT mode:** genuine **voxelised-geometry path tracer**, 1–8 bounces, cosine/GGX MIS sampling, Russian roulette, reservoir-based light resampling at the first diffuse hit, SVGF reconstruction, progressive accumulation when the camera is static. Honest description: *path tracing through a 1/2/4/8-block voxel approximation of the world, with no entities, particles or sub-block shape detail.*
- **Denoiser:** one shared **SVGF-class** implementation (moments → variance → adaptive temporal α → variance-guided à-trous) replacing the current fixed-α reprojection and the fixed-radius bilateral filter.

No Iris modification is required. Everything above fits inside Iris 26.3's existing `CUSTOM_IMAGES` + `COMPUTE_SHADERS` + `SSBO` feature set [VERIFIED against Iris source, §3.6].

### 1.3 Major trade-offs

| Decision | Gain | Cost |
|---|---|---|
| Clipmap instead of one cubic volume | 4 MiB covers 512 blocks; range grows without VRAM blow-up | 2–4× more complex DDA (level transitions); visible LOD seams at level boundaries |
| DDGI probes for multi-bounce | Real multi-bounce, coloured bleeding, view-independent stability | ≈2 MiB for two probe levels (§Stage 8); probe update scheduling; leak mitigation via moments; a second tuning surface |
| Drop `colortex5` feedback from GI | Removes the entire class of view-dependent GI artifacts | Needs a new direct-radiance buffer and a one-frame restructuring of SSGI; loses cheap screen-space colour reuse |
| Separate PT mode | Real, defensible path tracing with progressive convergence | ~2× the shading code paths; higher maintenance; must share the denoiser carefully |
| Keeping the legacy analytic path intact | Guaranteed fallback; satisfies "no silent removal" | Dead-ish code that must still compile in every option combination |

### 1.4 Feasibility

**Feasible, with three hard limits that the plan must not paper over:**

1. **No hardware ray tracing, no BVH, no scene geometry.** Iris exposes no ray-query API; shaderpacks are GLSL 4.3-class programs over textures, UBOs, custom images and ≤12 SSBOs [VERIFIED]. All visibility is authored by hand over the voxel grid and depth buffers.
2. **Geometry coverage is bounded by what Minecraft draws into passes we can hook.** Today only the shadow pass writes voxels, entity draws are explicitly excluded, and neither Distant Horizons nor Voxy terrain is voxelized at all [VERIFIED: `grep -rln voxel_update.glsl` returns exactly `shaders/program/shadow.vsh`]. GI range is therefore tied to `shadowDistance` (default 128.0) [VERIFIED]. Fixing this is Stage 4 work, not a footnote.
3. **"Path tracing" cannot mean full-scene PT.** It means PT over a block-granular voxel scene. Stating otherwise would be dishonest; the plan specifies the exact limitations in §4.4.

---

## 2. Repository audit

### 2.1 Repository state

| Item | Finding | Evidence |
|---|---|---|
| Branch | `arena/1996cb09-photon`, clean, 2 commits total | `git rev-list --count HEAD` → 2 |
| Commit 1 | `6e67b36` = upstream Photon `main`, 631 files, byte-identical tree to GitHub's `6e67b36` (same commit SHA) | `git ls-tree -r 6e67b36 --name-only \| wc -l` → 631 |
| Commit 2 | `e56ae19` — squashed import of all fork work | `git show --stat HEAD` |
| Commit 3 | `216b896` — this audit's P0 compile fix | `git log --oneline` |
| Prior audit | `RTGI_AUDIT.md`, 751 lines, documents "Steps 0–15" | present in tree |
| **History provenance gap** | `RTGI_AUDIT.md` cites 20 SHAs (`04418ba`, `129b519`, `819072c`, `385d3cd`, `78f04c8`, `6df182b`, `7d2081e`, …). **None exist in this repository** — `git cat-file -t 04418ba` fails. The fork history was squashed, so the audit's per-commit attributions are unverifiable here. | `git cat-file -t 04418ba` → *Not a valid object name* |
| Net diff vs upstream | 30 files added, 37 deleted, 34 modified | `git diff --no-renames --name-status 6e67b36 HEAD` |
| Runtime verification in this environment | **None possible.** No Minecraft, no Iris runtime, no GPU, no OpenGL context. | [VERIFIED absence] |

**Consequence:** every claim about on-GPU behaviour in this plan is either static-analysis-derived or inherited from the user's screenshots recorded in `RTGI_AUDIT.md`. The plan is structured so that Stage 0 establishes that missing runtime truth before any architecture is committed to.

### 2.2 What was deleted from upstream — and why it matters

The fork removed 37 upstream files [VERIFIED, `--no-renames`]. They fall into three groups, and **only one of the three is justified by the lighting redesign**:

**(a) LPV system — justified as a replacement, but with net capability loss**

Deleted: `include/lighting/lpv/{blocklight,floodfill,light_colors,voxelization}.glsl`, `include/fog/lpv_fog.glsl`, `program/lpv/{floodfill,setup}.csh`, `program/shadow_voxels.{vsh,fsh}`, `world*/{setup.csh,shadowcomp.csh,gbuffers_voxels.*,shadow_voxels.*}` (16 files).

The new voxel grid replaces LPV's voxelization. But upstream LPV also provided:
- **multi-bounce propagation** via a floodfill compute pass (`program/lpv/floodfill.csh`) — the new system has *no* multi-bounce;
- **coloured volumetric fog** (`lpv_fog.glsl`) — nothing replaces this; `AIR_FOG_COLORED_LIGHT_SHAFTS` still exists as an option string.

**(b) Screen-space AO — replaced, but the fallback path is now AO-less**

Deleted: `include/lighting/ao/gtao.glsl`, `include/lighting/ao/ssao.glsl`.

Upstream: `#define SHADER_AO_NONE 0 / SHADER_AO_SSAO 1 / SHADER_AO_GTAO 2` and `#define SHADER_AO SHADER_AO_GTAO // [SHADER_AO_NONE SHADER_AO_SSAO SHADER_AO_GTAO]`.
Fork: only `SHADER_AO_NONE` is defined and `SHADER_AO` is hardcoded to it (`shaders/settings.glsl:160-161`); `SHADER_AO=SHADER_AO_NONE` is baked into all five profiles [VERIFIED].

Combined with `RTGI_CONTACT_AO_STRENGTH = 0.00` (default since Step 11), **the default configuration ships with no ambient occlusion of any kind**, and with `RAYTRACED_GI` off there is no AO at all. This is a silent feature regression on the fallback path.

**(c) Photonics integration — unrelated to lighting, removed anyway**

Deleted: `shaders/ph_lights.json` (359 lines — the light-ID table), `shaders/photonics/{photonics,shader_interface,ph_samplers,write_indirect}.glsl`, `shaders/photonics/modifiers/{is_hand_modifier,light_modifier,restir_gi_modifier}.glsl` (8 files).

Upstream's `photonics.glsl` is a documented *stub* ("content provided by the Photonics mod at runtime. This empty file ensures the shader pack loads without the mod installed"). Removing it removes the injection point, not shader logic. Note that upstream already exposed a **`restir_gi_modifier.glsl`** hook — i.e. a ReSTIR-GI integration surface existed and was dropped.

This directly violates the brief's "do not remove unrelated features merely because the lighting architecture changes". It is scheduled for restoration in Stage 1.

### 2.3 Implementation status table

Status vocabulary: **working** (code present, plausible, statically compiles), **partial** (present but with a verified design or correctness defect), **broken** (verified compile or logic failure), **unverified** (present, no runtime evidence), **removed** (existed upstream, deleted here).

| Subsystem | Current status | Evidence and affected files | Known failure or limitation | Recommended action |
|---|---|---|---|---|
| **Voxel scene representation** | partial | `include/lighting/voxel/voxel_storage.glsl` (78 L), `voxel_update.glsl` (173 L), `voxel_constants.glsl` (66 L); `shaders.properties:406-414`; `program/shadow.vsh:67-90` | Cubic `R32UI`; 512³ = 512 MiB; single LOD; **only** written by `shadow.vsh`; entity draws excluded by `!defined PROGRAM_SHADOW_ENTITIES`; DH/Voxy not voxelized at all; coverage limited by `shadowDistance=128` | **Replace** (Stage 4 clipmap), keep packing format |
| Voxel packing (RGB555/ID/light/flags) | working | `voxel_storage.glsl:38-77`; unit test `tools/shadercheck/voxel_packing_test.py` | 4-bit light quantisation; `imageAtomicMax` is **not additive** — two coloured emitters in one air voxel resolve to whichever packed payload is numerically larger, so light colours never blend | **Fix** (Stage 4: additive light field in a separate image) |
| Radial point-light injection | broken by design, default off | `voxel_update.glsl:99-171` (9³ loop + occlusion raycast per emitter vertex) | Occlusion tested against partially-written image (vertex-stage race — correctly diagnosed in Step 13); per-voxel `max` not sum; runs inside a **vertex shader** at 729 offsets × 4 steps | **Replace** (Stage 8 DDGI); keep default-off until then |
| Voxel DDA traversal | working | `include/lighting/rt/voxel_dda.glsl` (248 L) | Seam jitter is a hashed hack; first-hit normal uses `mask=0` fallback; `sample_voxel_sun_shadow` uses fixed `normal*0.15` bias instead of the pack's `get_shadow_bias()`; no level transitions | **Rewrite** (Stage 5) against clipmap |
| DDA step budget | partial | `voxel_constants.glsl:24` `voxel_dda_max_steps = SIZE*7/8+8` | Static loop bound → shader compile time and register pressure grow with `VOXEL_VOLUME_SIZE` | Resolve with clipmap (fixed 64-texel levels) |
| Screen-space GI (SSGI) | partial | `include/lighting/rt/ssgi.glsl` (166 L) | Samples **last frame's composite** (`colortex5`); 16 fixed steps + 2 refinement; rejects any hit behind translucency; self-block rejection is heuristic | **Replace estimator** (Stage 3/6), keep raymarcher |
| Hybrid composition | partial | `include/lighting/rt/hybrid_rtgi.glsl` (102 L) | SSGI hit short-circuits DDA; no MIS, no weighting by confidence; sky fallback multiplies `sqr(surface_skylight)` | **Rewrite** (Stage 6) with explicit MIS weights |
| Bounce count | **broken (capability)** | `voxel_dda.glsl` returns one hit's direct lighting | Exactly **1** bounce; no recursion, no radiance-cache feedback | **Replace** (Stage 8) |
| Coloured light bleeding | partial | `voxel_dda.glsl:186` `blocklight_color * (sqr(sample_data.block_light) * blocklight_scale)` | Colour is a per-emitter constant × vanilla scalar lightmap; not transport | **Replace** (Stage 8) |
| Emissive illumination | partial | `get_voxel_material().emission`; `is_point_light_emitter()` | Emissive radiance only when a ray *hits* the emitter voxel; small emitters are made transparent only when injection is on | **Fix** (Stage 6 + 8) |
| Direct sun/sky in bounces | working | `sample_voxel_sun_shadow()` → shadow map; `sky_radiance` from `sky_ambient_color` | Sun visibility re-tested per bounce at block-centre resolution | Keep, re-validate bias |
| Temporal accumulation | partial | `program/rtgi/rtgi_temporal.csh` (163 L) | α = mix(0.08, 0.70, |motion|·0.08); depth tolerance `max(dist*0.20, 0.50)` then ×2; **no moments, no variance, no neighbourhood clamp** | **Replace** (Stage 7 SVGF) |
| Spatial filter | partial | `program/rtgi/rtgi_filter.csh` (165 L) | 25 taps, `step_size = 2` fixed, tangent-plane depth + `pow(dot,4)` normal weight, **no luminance/colour weight**, no sky rejection | **Replace** (Stage 7 à-trous + variance guidance) |
| Firefly control | partial | `rtgi_trace.csh` `max_radiance_lum = 16.0` | Hard clamp distorts energy; no outlier rejection against history | **Replace** (Stage 7 variance clamp) |
| AO / contact AO | partial + regression | `program/d3_ao.fsh` (8-tap); `settings.glsl:160-161` | Only `SHADER_AO_NONE` defined; GTAO/SSAO deleted; `RTGI_CONTACT_AO_STRENGTH` default `0.00` → **no AO at all by default** | **Fix** (Stage 1 restore fallback) |
| Direct block lighting | working, double-counted | `diffuse_lighting.glsl:299-342`: RTGI local **plus** unconditional `lighting += mc_block` (line 342) | Direct block light contributes both through RTGI local bounces and through the analytic term | **Fix** (Stage 6 energy audit) |
| RTGI brightness normalisation | partial | `diffuse_lighting.glsl:306` `rtgi_indirect * (1.6 * RTGI_BRIGHTNESS)` | Magic 1.6 with no derivation | **Replace** (Stage 6, derive from measurement) |
| Sky/emissive split | working | `rtgi_sky_accum_img`, `rtgi_sky_history_img`, `rtgi_filtered_img.a` | Two extra full-res images to carry one scalar; probe cache makes this obsolete | Keep until Stage 8, then simplify |
| Specular / reflections | working | `specular_lighting.glsl` (483 L), `include/lighting/rt/rt_reflections.glsl` (47 L), `shadows/ssrt.glsl` (193 L) | `RT_REFLECTIONS` undefined for Nether and `!SHADOW` (Step 0 workaround) | Keep; extend to clipmap in Stage 5 |
| Shadows | working | `shadows/pcss.glsl` (292 L), `shadow.vsh`, `distortion.glsl` | Nether program early-returns `gl_Position = vec4(-1.0)` so no Nether shadow map | Keep |
| Volumetric light / fog | working, minus LPV fog | `program/c0_vl.fsh`, `include/fog/*` | `AIR_FOG_COLORED_LIGHT_SHAFTS` option survives but `lpv_fog.glsl` is gone | **Investigate→Restore** (Stage 1/9) |
| Translucent GI | partial (deliberate) | `diffuse_lighting.glsl:23-28` gates RTGI to `PROGRAM_DEFERRED4` | Water/glass/particles use analytic lighting only | Keep as documented limitation; revisit in Stage 10 |
| Photonics integration | **removed** | 8 files deleted vs upstream | External mod integration surface lost, incl. `restir_gi_modifier` hook | **Restore** (Stage 1) |
| TAAU interaction | working | `include/global.glsl:85-104` `taau_framebuffer_uv()` etc.; `world*` compute passes use them | Convention is centralised; consistent across the three compute passes | Keep |
| Debug views | **absent** | no `DEBUG_SAMPLER` consumer found in `lighting/rt/*` | `DEBUG_SAMPLER` is listed in `sliders` but GI passes expose nothing | **Add** (Stage 2) |
| Static validation harness | working | `tools/shadercheck/{check,matrix,matrix_compute,properties_lint,voxel_packing_test}.py`, `run_checks.sh` | Requires `glslang` (not vendored, not in CI); `NO_INJECT=shadowtex0` workaround; vertex shaders approximated | **Extend + wire to CI** (Stage 0) |
| `#if` on float sliders | **broken → fixed** | `voxel_dda.glsl:130,148`, `voxel_update.glsl:99` before `216b896` | Illegal preprocessor expression; 120 of 308 static cases failed | **Fixed in `216b896`** [MEASURED] |
| `RTGI_RESOLUTION` semantics | partial | `settings.glsl:63`; `shaders.properties:419-439` | 0 → quarter-res, 1 → half, 2 → full: inverted vs the name | Rename to `RTGI_SCALE` (Stage 10) |
| Menu / language strings | working | `properties_lint.py` → 305 keys, 3 known upstream duplicates, 14 RTGI options | Non-`en_US` translations still upstream-era | Stage 10 cleanup |

### 2.4 Verified technical blockers

| # | Blocker | Severity | Evidence |
|---|---|---|---|
| B1 | GI reads its own previous output through `colortex5` (TAA-composited scene colour) | **Critical** — root cause of view-dependent GI | `rtgi_trace.csh:31,156`; `c4_taa_exposure.fsh:17` `RENDERTARGETS: 0,5`; `buffers.glsl:9` |
| B2 | No second bounce anywhere in the pipeline | **Critical** — fails the multi-bounce requirement | `voxel_dda.glsl` single-hit return |
| B3 | Voxel coverage = shadow-pass draws only; no entities, no DH, no Voxy | **High** — GI is wrong outside 128 blocks and around mobs | `grep -rln voxel_update.glsl shaders/` → only `program/shadow.vsh` |
| B4 | Voxel volume memory scales as N³ (512³ = 512 MiB) | **High** — caps range | `shaders.properties:406-414` |
| B5 | `imageAtomicMax` makes the light field non-additive | **High** — coloured emitters cannot blend | `voxel_storage.glsl:38-58`; `voxel_update.glsl:88` |
| B6 | Direct block light double-counted (`RTGI local` + `mc_block`) | **Medium** — energy error | `diffuse_lighting.glsl:313-345` |
| B7 | No AO in default config; `SHADER_AO` is a dead macro | **Medium** — visible quality regression | `settings.glsl:160-161`; deleted `ao/*.glsl` |
| B8 | Photonics integration removed | **Medium** — compatibility regression | 8 deleted files |
| B9 | No variance estimate → fixed-α temporal and fixed-radius filter must be hand-tuned per scene | **Medium** — the recurring noise/ghosting complaints | `rtgi_temporal.csh`, `rtgi_filter.csh` |
| B10 | Vertex-stage voxelization races with occlusion tests | **Medium** — correctness | `voxel_update.glsl`, Step 13 notes |

### 2.5 What is genuinely good and must be preserved

- The **three-pass compute decomposition** (trace / temporal / filter) is the right shape and maps cleanly onto the SVGF-class design in Stage 7.
- **Deterministic 32-bit voxel packing** with a pure-Python round-trip test is exactly the right way to make a bit layout safe. Keep the test, change the layout.
- **TAAU coordinate centralisation** (`taau_framebuffer_uv` / `taau_projection_uv` / `taau_uv_outside_viewport`) is correct and should be used by every new pass.
- **`tools/shadercheck/`** is the project's most valuable asset: a working static compile matrix (308 + 780 cases) plus a properties linter. It caught B10-class bugs and caught the P0 fix. It must become a gate, not an optional script.
- **Sky/emissive separation** (`sky_weight`) is the right *idea* even if implemented expensively; the probe cache will make it cheaper.
- Upstream's material/BSDF layer (`bsdf.glsl`, `material.glsl`, labPBR support, `fresnel_lazanyi_2019`, Hammon diffuse, Kulla-Conty compensation) is high quality and needs no changes.

---

## 3. Architecture decision

### 3.1 The decision to be made

Five candidate architectures were considered against the brief's requirements: physically plausible direct+indirect light, real-time GI with an explicit quality/perf trade-off, multi-bounce with coloured bleeding and emissive sources, temporal stability, and a defensible path-tracing mode.

| # | Architecture | Multi-bounce | Coloured bleeding | Stability | PT possible | Complexity | Verdict |
|---|---|---|---|---|---|---|---|
| A1 | Shaderpack-only screen-space GI (current, improved) | No | Only via feedback (unstable) | Poor | No | Low | **Reject** — cannot meet multi-bounce or stability |
| A2 | Voxel GI + per-pixel stochastic bounces (no cache) | Yes, but per-pixel cost = bounces × rays | Yes | Needs heavy denoising | Yes | Medium | **Partial** — this *is* the PT mode, but too expensive to be the only mode |
| A3 | Voxel GI + **DDGI probe radiance cache** | Yes (cache feedback) | Yes | Good | Yes (cache as bounce source) | Medium-high | **SELECT** for RTGI |
| A4 | Voxel cone tracing / mipmapped radiance | Yes | Yes | Medium | Poor fit | Medium | Reject — blocky wide cones, needs mip chain rebuild, worse than DDA at this scale |
| A5 | Iris extension exposing hardware RT / BVH | Ideal | Ideal | Ideal | Ideal | Very high + upstream maintenance | **Reject** — no evidence of need; would fork the mod |

### 3.2 Why A3 (voxel + DDGI cache) and not "just add more bounces to A2"

Adding a second stochastic bounce per pixel to the current design multiplies the ray budget (2 rays → 2×2 = 4 rays minimum for two bounces, and variance grows multiplicatively), while the existing denoiser already struggles with one bounce. DDGI inverts the cost structure: probe radiance is gathered **once** and reused by every pixel; multi-bounce emerges from probe→probe feedback across frames rather than from per-pixel recursion.

Concretely [PROPOSED, arithmetic checked]:

| | Current per-pixel trace | DDGI probe update |
|---|---|---|
| Rays per frame | 1920×1080×2 = **4.15 M** | 256 probes × 64 rays = **16 K** |
| Multi-bounce | 1 | ~4 (feedback) |
| Cost scales with | screen resolution | probe count (fixed) |

DDGI is therefore **~250× cheaper in ray count** and provides strictly more transport. The per-pixel trace is retained only for near-field detail that a 4-block probe spacing cannot represent.

### 3.3 Why a clipmap, with the arithmetic

Current: one cubic volume, `VOXEL_VOLUME_SIZE`³ texels × 4 B.

| Setting | VRAM (voxel_img alone) | Range |
|---|---:|---:|
| 64 | 1 MiB | 32 blocks |
| 128 (default) | 8 MiB | 64 blocks |
| 256 | 64 MiB | 128 blocks |
| 512 (offered in the menu) | **512 MiB** | 256 blocks |

[MEASURED: `image.voxel_img = ... 512 512 512` at `r32ui`]

Proposed clipmap: **4 levels, 64³ texels each**, spacing 1/2/4/8 blocks per texel:

| Level | Texels | Blocks covered | Spacing | VRAM |
|---|---:|---:|---:|---:|
| L0 | 64³ = 262,144 | 64 | 1 block | 1 MiB |
| L1 | 64³ | 128 | 2 blocks | 1 MiB |
| L2 | 64³ | 256 | 4 blocks | 1 MiB |
| L3 | 64³ | 512 | 8 blocks | 1 MiB |
| **Total** | | **512 blocks** | | **4 MiB** |

[MEASURED arithmetic] 4 MiB total vs 8 MiB for the current 64-block range: **half the memory for 8× the range**. L0 at 1-block spacing is 4× finer than the current default's reach in the region that matters most, and L3 finally puts *something* beyond 128 blocks.

Cost: DDA must handle level transitions, and a coarse level produces blockier secondary visibility. Mitigations are specified in Stage 5 (per-level normal reconstruction from occupancy, stitch seams via one-texel overlap, fade contributions across a boundary band).

### 3.4 Why one renderer with two estimators, not two shaderpacks

The brief asks explicitly: *two separate modes, a shared renderer with different sampling budgets, or another architecture?*

**Shared renderer with different estimators.** Justification:

- Scene core (clipmap, packing, materials, light list), spatial structures, denoiser, TAAU interaction, and all of Photon's non-GI features (sky, clouds, fog, water, shadows, bloom, grading) are **identical** between modes. Duplicating them would double the maintenance surface for zero quality gain.
- The two estimators differ in exactly one place: *what happens at a shading point*. RTGI = one stochastic indirect sample + cache; PT = a recursive stochastic path. Both consume the same `SceneQuery` interface and both emit a radiance signal into the same temporal/denoise chain.
- They must differ in **denoiser parameterisation** (PT has per-pixel path length, RR survival, and needs path-length-aware filtering), so the shared denoiser takes a small per-pixel "estimator metadata" input rather than being two filters.

Consequence: one `RTGI_MODE` option with values `OFF | HYBRID | PATH_TRACED`, implemented as a uniform-ish macro switch over one shared interface, with `OFF` preserving today's analytic path bit-for-bit.

### 3.5 Explicit answers to the "information you cannot get from screen-space buffers" question

| Question | Answer in this architecture | Limitation to state in docs |
|---|---|---|
| Geometry outside the screen | Clipmap voxels; DDA traverses it in world space | Only geometry that was voxelized (see next row) |
| Geometry behind visible surfaces | Same clipmap; no depth buffer involved | Block-granular; interior of solid blocks not represented (fine for GI) |
| Partially transparent | Stained glass tints `ray_transmittance` by albedo; clear glass passes through; water is **not** in the voxel grid at all | No refraction, no caustics, no absorption media |
| Animated | Terrain animation only via `shadow.vsh`'s `animate_vertex` (grass/leaves); entities excluded | Falling sand, boats, armour stands, mobs cast no GI |
| Distant terrain (DH/Voxy) | **Not represented today**; Stage 4 adds coarse L3 voxelization hooked into DH/Voxy programs if their interfaces permit | If not achievable, GI must fade out beyond L3 and be documented |
| Sub-block shapes (stairs, slabs, fences, walls) | Voxelized as full cubes (`should_voxelize` treats them as solid) | Visible GI error at block-scale detail; Stage 5 adds a per-block "shape class" nibble to approximate |

### 3.6 Iris capability verification (no extension required)

Read from Iris 26.3 `671a5c87`:

| Capability | Iris support | Where | Used by this plan |
|---|---|---|---|
| Compute shaders | `FeatureFlags.COMPUTE_SHADERS` | `features/FeatureFlags.java:15` | Yes (already) |
| Custom images (incl. 3D, `R32UI`) | `CUSTOM_IMAGES`, gated on `supportsImageLoadStore` | `FeatureFlags.java:12` | Yes (already) |
| Image format `r32ui` + `imageAtomicMax` | GL 4.2 core image load/store | already used by fork | Yes |
| Relative-size images | `image.<name> = … <w> <h> [<d>]` with fractional dims | `ImageInformation.create` | Yes |
| SSBOs | `FeatureFlags.SSBO`; `bufferObject.<n> = <size> [name]`, **index ≤ 12** | `ShaderProperties.java:387-433` | **New** — light list, emissive voxel list |
| Max colortex buffers | `IrisLimits.MAX_COLOR_BUFFERS = 32` | `gl/IrisLimits.java` | Budget headroom exists |
| Max image units | `GL_MAX_IMAGE_UNITS` (runtime) | `gl/image/ImageLimits.java` | Keep ≤ 4 simultaneous images per program |
| Per-buffer blending | `PER_BUFFER_BLENDING` | `FeatureFlags.java:13` | Not needed |
| Separate hardware samplers | `SEPARATE_HARDWARE_SAMPLERS` | `FeatureFlags.java:11` | Useful for the added samplers |
| Program enable directives with macro conditions | `program.<dim>/<pass>.enabled` | `ShaderProperties.java:385` | Yes (already) |
| Compute pass naming `deferred<n>_a` / `composite<n>_a` | pass-array suffix convention | already used by fork | Yes |
| **Hardware ray tracing / BVH / scene geometry** | **Not exposed** | absent from `FeatureFlags` and pipeline | **Never** |

**Conclusion: zero Iris changes.** The brief permits "minimal Iris-side extensions, if the shaderpack API demonstrably lacks capabilities necessary for the intended result". Nothing in this plan lacks a shaderpack-side capability. Adding SSBO usage is a pack-side change only. The one Iris-adjacent risk is that a pack now depends on `GL_MAX_IMAGE_UNITS`; the plan keeps ≤4 images per program, well inside the GL 4.3 minimum of 8.

---

## 4. Rendering data flow

### 4.1 Current data flow (verified)

```
                    ┌──────────────────────────── per frame ────────────────────────────┐
 gbuffers_all_solid ──► colortex1 (normal, light levels)                        [full res]
                    ──► colortex2 (normal map, material)                        [full res]
                    ──► colortex3 (refraction/overlay)                          [full res]

 shadow.vsh ─────────► voxel_img  (R32UI 3D, imageAtomicMax, CLEARED each frame)
                        ▲ only writer in the entire pack

 deferred0  d0_sky_map      ──► colortex4 (sky LUT, light colours, SH)
 deferred1  d1_clouds
           deferred1_a ────► rtgi_trace.csh      reads depthtex1, colortex1/2/4,
                                                   colortex5 (!!), voxel_sampler
                                              writes rtgi_raw_img
 deferred2  d2_clouds_upscaling
           deferred2_a ────► rtgi_temporal.csh   ping-pong history, alpha 0.08..0.70
                                              writes rtgi_{accum|history}_img
                                                      rtgi_sky_{accum|history}_img
 deferred3  d3_ao           ──► colortex6 ambient, colortex14 history
           deferred3_a ────► rtgi_filter.csh     25-tap bilateral, step_size 2
                                              writes rtgi_filtered_img (rgb + sky weight)
 deferred4  d4_deferred_shading  reads rtgi_filtered_sampler  ◄── single consumer
                                 + analytic get_sky_lighting() *fallback*
                                 + mc_block  (unconditional → double count)

 composite0 c0_vl   composite1 c1_blend_layers (translucents, analytic lighting only)
 composite3 c3_taau_prep   composite4 c4_taa_exposure ──► colortex0 + colortex5
                                                              ▲
                                                              └── next frame's SSGI input
```

The red thread: `colortex5` is produced by `c4` (after all shading) and consumed by `rtgi_trace` at `deferred1` of the **next** frame. GI → scene colour → GI.

### 4.2 Proposed data flow

```
 ── geometry ────────────────────────────────────────────────────────────────
 gbuffers_all_solid ──► colortex1/2/3   (unchanged G-buffer)
 shadow.vsh ─┐
 gbuffers_all_solid (terrain stages) ─┴─► ClipmapVoxelize ──► voxel_clipmap[L0..L3]  (4 MiB)
                                                          └─► emissive_list SSBO
                                                          └─► radiance_direct  (NEW: direct-light-only,
                                                                                full or half res)
 ── per-frame compute chain ─────────────────────────────────────────────────
 deferred1_a  rtgi_probe_update.csh  ──► probe_irradiance[L_near, L_far]
   (256 probes/frame, round-robin)  ──► probe_moments[L_near, L_far]
 deferred2_a  rtgi_trace.csh         ──► rtgi_signal (rgb + moment + depth + path_len)
   reads: depthtex1, colortex1/2, radiance_direct, probes, clipmap
 deferred2_b  rtgi_temporal.csh      ──► rtgi_history (ping-pong) + moments
 deferred3_a  rtgi_atrous.csh  ×3    ──► rtgi_filtered
 ── shading ─────────────────────────────────────────────────────────────────
 deferred4  d4_deferred_shading   lighting = direct_analytic
                                          + indirect(rtgi_filtered)
                                          + emission
                                          (single origin for each term — no double counting)
 ── post ────────────────────────────────────────────────────────────────────
 composite0..  unchanged (VL, translucency, TAAU, TAA, bloom, grading)
```

Key structural changes versus today:

1. **`radiance_direct` breaks B1.** SSGI samples a *direct-lighting-only* buffer for the current frame. Question 8 in §11 covers the residual one-frame cost.
2. **Probe update runs before the trace**, so the per-pixel trace can use this frame's cache.
3. **The clipmap is written by more than `shadow.vsh`** (B3), and its levels are fixed-size, so DDA loop bounds are constant regardless of range (B4).
4. **`deferred4` becomes the single place where direct and indirect are summed**, removing the `mc_block` double count (B6).

### 4.3 Buffer budget [PROPOSED]

| Buffer | Format | Size | Purpose | New? |
|---|---|---|---|---|
| `voxel_clipmap_L0..L3` | `r32ui` 3D | 64³ ×4 | Scene representation | replaces `voxel_img` |
| `voxel_light_L0..L3` | `rgba16f` 3D | 64³ ×4 | **Additive** coloured light field (fixes B5) | new |
| `probe_irradiance_near/far` | `rgba16f` 2D atlas | 10·16 × 10·16 | Octahedral irradiance (8×8 + border) | new |
| `probe_moments_near/far` | `rgba16f` 2D atlas | 18·16 × 18·16 | Octahedral depth moments (16×16 + border) | new |
| `radiance_direct` | `rgba16f` | half res | Direct-only radiance for SSGI | new |
| `rtgi_signal` | `rgba16f` | half res | rgb + mean | new |
| `rtgi_moments` | `rg16f` | half res | mean, mean² → variance | new (replaces sky_weight plumbing) |
| `rtgi_history` ×2 | `rgba16f` | half res | ping-pong history + depth + path length | replaces 4 images |
| `rtgi_filtered` | `rgba16f` | half res | denoised output | kept |
| `emissive_list` SSBO | uint/float | ≤ 64 KiB | Emitter list for light sampling | new |

Net: **fewer** RTGI images than today (six → four), plus ≈4 MiB clipmap, ≈4 MiB additive light field and ≈2 MiB probes. At 1920×1080 half-res each RGBA16F image is ≈4 MiB, so today's six cost ≈24 MiB and the proposal's four cost ≈16 MiB.

---

## 5. Algorithm comparison

For each technique: source, public implementation, idea, adaptation, artifacts, cost, why chosen, licence.

### 5.1 Voxel traversal — Amanatides & Woo DDA

1. **Reference:** Amanatides, J., Woo, A. *A Fast Voxel Traversal Algorithm for Ray Tracing.* Eurographics '87.
2. **Implementation:** `cgyurgyik/Fast-Voxel-Traversal-Algorithm` (MIT, ~199★, verified on GitHub).
3. **Idea:** step exactly one voxel boundary per iteration using three `t_max` values and a per-axis `delta_t`.
4. **Adaptation:** already implemented; extend to clipmap level transitions (on exit from L0, re-seed the DDA in L1 at the current `t`, halving the step size).
5. **Artifacts:** seam traversal when a ray component is exactly 0 or ±1 (the current fix is a hashed perturbation — replace with a deterministic epsilon push-out along the two minor axes); blocky hit positions; level seams.
6. **Cost:** O(steps) with constant work; 64–120 steps typical. Cheapest option per query.
7. **Why chosen over cone tracing:** cone tracing needs a mipmapped 3D radiance texture that must be rebuilt every frame (O(N³) with N=64 per level ⇒ 4 × 262 K voxel writes/frame just for mips), and gives blocky wide cones that are poor for a 1-block world. DDA gives exact first-hit and exact transmittance accumulation for the same memory.
8. **Licence:** algorithm is public domain; any reused code must keep the MIT notice.

### 5.2 Multi-bounce — DDGI (irradiance probe fields with depth-moment visibility)

1. **Reference:** Majercik, Z., Marrs, A., Ramamoorthi, R., McGuire, M. *Dynamic Diffuse Global Illumination with Ray-Traced Irradiance Fields.* JCGT 8(2), 2019.
2. **Implementation:** `NVIDIAGameWorks/RTXGI-DDGI` (877★, verified). **Licence is `NOASSERTION`** — the NVIDIA RTX SDK licence, **not** an OSI licence. Treat as **reference only**; do not copy source. Also `guoxx/DDGI` (BSD-3-Clause, 26★) as a licence-clean reading reference.
3. **Idea:** store irradiance (octahedral 8×8) and depth moments (16×16) per probe; update a few probes per frame with `rayCount` cosine rays; per-pixel shade by trilinearly blending the 8 surrounding probes, weighting by normal-facing and Chebyshev visibility from the moments; apply hysteresis per probe.
4. **Adaptation:** probe updates run as a compute pass (`deferred1_a`) tracing the clipmap DDA; irradiance stored in a 2D atlas (Iris has no 3D RGBA16F image limitation, but 3D avoids atlas border duplication — either works; use 3D `rgba16f` for simplicity). Two levels: near (spacing 4, 16³ probes) and far (spacing 16, 16³ probes) anchored to world-aligned integer positions.
5. **Artifacts:** light leaks through thin geometry (mitigated by moments + a "backface" weight); probe grid popping when scrolling (mitigated by whole-probe scrolling + hysteresis + relocation); over-smoothing at 4-block spacing (mitigated by combining with the per-pixel trace for the first bounce).
6. **Cost:** 256 probes × 64 rays = 16 K DDA casts/frame, ~4 MiB × 2 levels for irradiance + moments. Cheaper than the current per-pixel budget by two orders of magnitude.
7. **Why preferred:** it is the only candidate that provides multi-bounce *and* view-independent stability *and* bounded cost inside a shaderpack. Radiance caching (Krivánek et al., *Radiance Cache Splatting*, EGSR 2005) is the same family but needs a dynamic cache structure; irradiance probes are the static-grid specialisation, which suits a block world.
8. **Licence:** implement from the paper. RTXGI source is **not** reusable.

### 5.3 Temporal reconstruction — SVGF

1. **Reference:** Schied, C., Kaplanyan, A., Wyman, C., Patney, A., Chajdas, M., Dachsbacher, C., Lefohn, A. *Spatiotemporal Variance-Guided Filtering.* HPG 2017.
2. **Implementation:** no canonical OSS; Microsoft's Falcor samples are archived (`NVIDIA/Falcor` archived, verified). Reference implementations are widely readable. Implement from the paper.
3. **Idea:** accumulate first and second moments temporally to estimate per-pixel variance; feed variance into (a) the temporal α and (b) an à-trous wavelet filter's step size and edge-stop width, so smooth regions are filtered hard and edges are preserved.
4. **Adaptation:** replace `rtgi_temporal.csh`; add `rtgi_moments`. Disocclusion test = depth + normal + object/instance ID + a neighbourhood colour-clamp (variance clipping) that the current code lacks entirely.
5. **Artifacts:** ghosting when reprojection is wrong (accepted, bounded by variance clipping); over-blur when variance is underestimated; fireflies survive if moments are accumulated naively — use a first-frame clamp plus a variance-based radiance clamp.
6. **Cost:** 4 extra floats/pixel + 3 à-trous passes at 5×5 (or a 3-pass 5×5 with increasing step).
7. **Why preferred over the current fixed-α scheme:** the fixed-α/`step_size` scheme has ~6 hand-tuned constants that interact (α range, motion scale, depth tolerance, ×2 tolerance, plane tolerance, step size) and the audit log shows they were retuned four separate times (Steps 9, 10, 14, 15) with regressions each time. Variance guidance replaces that tuning with a measurable quantity.
8. **Licence:** paper only.

### 5.4 Light sampling / reservoirs — ReSTIR and ReSTIR GI

1. **References:** Bitterli, B., Wyman, C., Pharr, M., Shirley, P., Lefohn, A., Jarosz, W. *Spatiotemporal Reservoir Resampling for Real-Time Ray Tracing with Dynamic Direct Lighting.* SIGGRAPH 2020. Ouyang, Y., Liu, S., Kettunen, M., Pharr, M., Pantaleoni, J. *ReSTIR GI: Path Resampling for Real-Time Path Tracing.* HPG 2021.
2. **Implementation:** `DQLin/ReSTIR_PT` (**BSD-3-Clause**, 535★, verified) — licence-clean for the reservoir structures.
3. **Idea:** keep *M* candidate light samples with a weight; resample across pixels and frames with unbiasing; dramatically reduces variance for many-light scenes.
4. **Adaptation:** PT mode only. Photon's world has few co-located emitters, so full ReSTIR DI is overkill; use **reservoir resampling over the `emissive_list` SSBO at the first diffuse hit** only (one light sample per path instead of N). One temporal reservoir per pixel in an RGBA16F image.
5. **Artifacts:** temporal bias if the unbiasing weight is wrong (visible as slowly-drifting lighting); correlation artifacts when reusing across disocclusions.
6. **Cost:** ~1 image + a light-list build; replaces N shadow rays with 1.
7. **Why preferred over naive NEE:** with ≤64 emissive voxels in range, naive NEE is 64 rays; reservoir resampling cuts that by ~1/N with mild bias risk. **But** given Photon's light density, the plan makes this **optional (PT mode, high tier only)** rather than foundational — see Stage 9.
8. **Licence:** BSD-3 requires retaining copyright + licence text if code is copied. Prefer implementing from the paper.

### 5.5 Path sampling primitives

| Technique | Reference | Adaptation | Cost |
|---|---|---|---|
| Cosine-weighted hemisphere | Malley's method (1958), as in PBRT §13.6 | `cosine_weighted_hemisphere_sample` already exists in `utility/sampling.glsl` | free |
| GGX importance sampling (VNDF) | Heitz, E. *Sampling the GGX Distribution of Visible Normals.* JCGT 5(4), 2018 | Add `sample_ggx_vndf` to `bsdf.glsl` for PT-mode specular bounces | ~20 ALU |
| Multiple importance sampling (balance heuristic) | Veach, E., Guibas, L. *Optimally Combining Sampling Techniques.* SIGGRAPH 1995 | MIS between light sampling and BSDF sampling at each bounce; needed or emissive hits will be noisy | ~30 ALU/bounce |
| Russian roulette | Arvo & Kirk, SIGGRAPH 1990 (as popularised by PBRT §13.7) | Start at bounce 2 with survival `max(0.05, min(0.95, throughput_luminance))` | negligible |
| Blue-noise / IGN dithering | Jimenez, J. *Next Generation Post Processing in Call of Duty: AW*, SIGGRAPH 2014 | Already used (`noisetex.b` + `r2()`) | free |

### 5.6 Techniques considered and rejected

| Technique | Why rejected |
|---|---|
| **Voxel cone tracing** (Crassin et al. 2011) | Mip-chain rebuild cost per frame; blocky wide cones; inferior first-hit accuracy vs DDA for a block world |
| **LPV** (Kaplanyan & Dachsbacher 2010) | Upstream's system; scalar-ish propagation with 4 propagation steps/frame is a coarse diffusion, and the fork already proved it hard to maintain. Replaced by DDGI which has explicit visibility. |
| **Full ReSTIR PT** (Lin et al. 2022) | Requires path-space reservoirs + a hash grid + temporal reuse of full paths; expected bias and ghosting with Minecraft's animated world; complexity far beyond the benefit for a 1-block scene |
| **Neural / ML denoisers** | No network inference path in a GLSL shaderpack without extra data and tooling; out of scope |
| **Async compute / hardware RT via Iris extension** | Not exposed; would fork the mod for no demonstrated need |
| **Irradiance volumes / light probes baked offline** | Fails "changes in lighting" and dynamic emitters |

### 5.7 SEUS PTGI HRR GFME — what is worth taking, what is not

Inspected selectively [VERIFIED]: 446 entries, `shaders/program/template/BlockShapes_CompileTime.glsl` (717 lines) and `BlockShapes_Performance.glsl` (1,335 lines) contain hand-written analytic intersection routines for individual block shapes (stairs, fences, panes, slabs) parameterised by a **block-shape ID** (`RAYTRACE_GEOMETRY_QUALITY` 0/1/2 selects full-cube-only vs shape-aware), with `GI_RAY_COUNT [1..5]`, `GI_SECONDARY_SAMPLES [1..8]`, and a separate `PathTraceDenoiser.glsl` template. Voxelization happens in `shadow.vsh.glsl` at `floor(worldPos - cameraPosition + at_midBlock/64 + fract(cameraPos) - 1 + RAY_TRACING_DIAMETER/2)`.

| SEUS technique | Assessment for this project |
|---|---|
| Block-shape IDs + analytic intersection for sub-block geometry | **Valuable idea, independently reimplementable.** Directly addresses the "stairs/slabs are cubes" limitation. Cost: a per-block shape class in the voxel payload + a shape-intersection branch on hit. Adopt as **Stage 5 option**, implemented from the documented shape list (Minecraft block geometry is public knowledge), not from their code. |
| Single world-space voxel volume in the shadow vertex shader | Already the fork's approach; confirms it is the practical route inside Iris |
| Separate denoiser per mode (`PathTraceDenoiser.glsl`) | Partially contradicts this plan's "one shared denoiser"; adopt the *idea* of path-length-aware filtering, share the code |
| Obfuscated single-letter identifiers and minified GLSL | **Do not** adopt. Unmaintainable; this project's brief requires readable, documented code |
| `CAVE_GI_LEAK_FIX`, `GI_SUNLIGHT_STAINED_GLASS_TINT` toggles | Concepts are standard; implement independently |

**Licence status:** the SEUS pack carries **no licence granting redistribution or derivation**. The only MIT notice in the archive covers an embedded Shadertoy noise function (`lib/Common.inc:325-345`, "Copyright © 2013 Nikita Miropolskiy", MIT). Therefore: **SEUS code must not be copied, adapted, or transliterated.** It is used here only to confirm that a technique is viable and to compare design choices. Provenance record is in §9.6.

---

## 6. Staged roadmap (summary)

Every stage ends in a shaderpack that loads in all three dimensions and passes `./tools/shadercheck/run_checks.sh`. No stage depends on a later one.

| Stage | Title | Runnable deliverable | Depends on | Acceptance gate |
|---|---|---|---|---|
| **0** | Baseline truth and regression gate | Pack compiles on a strict compiler in all dimensions/options; documented in-game baseline protocol; `run_checks.sh` wired into CI/pre-push; baseline frame-time table | — | All static matrices 0 failures; the 6 known on-GPU symptoms reproduced and recorded |
| **1** | Restore removed capability | `SHADER_AO` works again (SSAO/GTAO restored as fallback); Photonics stub + `ph_lights.json` restored; LPV-fog option either restored or explicitly removed with a documented decision | 0 | RTGI off ⇒ upstream-equivalent AO; Photonics mod loads without error |
| **2** | Diagnostics | `DEBUG_SAMPLER` views for raw/accum/filtered GI, voxel occupancy/ID/light, ray hit-miss, history rejection, variance; per-pass GPU timing readout | 0 | Each view renders and is documented with a screenshot; zero cost when disabled |
| **3** | Break the GI feedback loop | `radiance_direct` buffer; SSGI samples current-frame direct light instead of `colortex5`; block-light double count removed; brightness constant replaced by a measured, documented normalisation | 1, 2 | Rotating the camera ±90° with a stationary light changes GI by < 5 % (measured by image diff); no light appears only from certain angles |
| **4** | Scene core v2 | 4-level clipmap (4 MiB, 512 blocks); additive coloured light image; dedicated voxelization from shadow + camera passes; entity/optional DH/Voxy coverage | 2, 3 | Voxel memory ≤ 8 MiB at any setting; GI occluders exist out to 512 blocks; two coloured emitters blend additively |
| **5** | Ray queries v2 | Clipmap DDA with level transitions; block-shape classes; any-hit shadow query; deterministic seam handling; Python mirror test | 4 | Python DDA trace matches GPU output on a synthetic volume; no seam light leaks in the sand-wall test |
| **6** | Single-bounce correctness | MIS-weighted hybrid (SSGI vs DDA vs sky); emissive hits correct; `1/π` audit; energy-conserving composition in `deferred4` | 3, 5 | White-room test: indirect energy within ±10 % of an analytic reference; no double counting |
| **7** | SVGF reconstruction | Moments + variance + adaptive α + 3-pass à-trous; variance clipping; firefly clamp | 3, 6 | Static scene converges to < 2 % temporal noise in ≤ 32 frames; camera pan shows no trails at 1080p |
| **8** | Multi-bounce via DDGI | Probe radiance cache; near+far levels; probe update pass; per-pixel cache lookup | 4, 6, 7 | Coloured-bleeding test shows ≥ 2 distinct bounce colours; sealed cave has zero sky leak; probes scroll without popping |
| **9** | Path-tracing mode | `RTGI_MODE = PATH_TRACED`: N bounces (1–8), GGX/cosine MIS, RR, reservoir light sampling (high tier), progressive accumulation | 5, 7, 8 | PT converges to the RTGI reference in a static scene; documented bias analysis vs a CPU reference |
| **10** | Production hardening | Quality tiers (4), perf validation, DH/Voxy compatibility, translations, naming cleanup, legacy analytic path clearly marked, docs | 0–9 | Full test matrix passes; perf budget met; no unsupported combination silently degrades |

---

## 7. Detailed stage specifications

### Stage 0 — Baseline truth and regression gate

**A. Purpose and scope**

*Primary objective:* replace "the audit says it should work" with a reproducible, machine-checkable baseline of what actually works today.

*Included:* the `216b896` compile fix (already applied); a strict-compiler pass over every option profile; a documented in-game baseline capture protocol; a written list of reproducible failures with exact reproduction steps; wiring the existing static harness into a gate.

*Excluded:* any change to rendering behaviour. Any visual difference in this stage is a bug.

*Why here:* the audit's 751 lines of history contain repeated "needs in-game validation" notes and four retunes of the same denoiser constants. The project cannot plan architecture on a foundation whose observable state is undocumented. Everything after this stage is judged against Stage 0 captures.

**B. Starting state**

The tree at `216b896`: 308 compute/fragment and 780 wrapper/option static cases pass [MEASURED]. `glslang` is not vendored; `check.py` finds it via `GLSLANG` env var or `PATH`. `NO_INJECT=shadowtex0` is required for the harness (an injection-stub workaround, not a shader defect).

**C. Implementation**

1. Vendor or document `glslang`. Add `tools/shadercheck/README.md` instructions for building 15.0.0 and set `GLSLANG`. Optionally add a `tools/shadercheck/bootstrap_glslang.sh` that clones `KhronosGroup/glslang` at tag `15.0.0` (Apache-2.0) and builds silently.
2. Add `.github/workflows/shadercheck.yml`:
   ```
   on: [push, pull_request]
   job: static
     - bootstrap glslang
     - ./tools/shadercheck/run_checks.sh
   ```
   This is the first automated gate the project has had.
3. Add `tools/shadercheck/baseline.sh` that zips the pack to `build/photon-<sha>.zip` (excluding `tools/`, `docs/images/`, `RTGI_AUDIT.md`, `RTGI_IMPLEMENTATION_PLAN.md`) so a tester can install exactly the committed state.
4. Write `docs/testing/baseline_protocol.md`. For each of the 6 symptoms reported in `RTGI_AUDIT.md` (camera-dependent torch light, sealed-cave brightness, corner "muddy AO", block-joint white stripes, ghosting trails, light flicker), record: world seed + coordinates, time of day (`/time set`), weather (`/weather clear`), exact option values, and a fixed camera position/orientation (a command block teleport + `/tp @s ~ ~ ~ <yaw> <pitch>`). One PNG per state, captured with TAA settled (wait 60 frames after teleport) and with F3 hidden.
5. Record baseline frame times: per-pass timing via Iris's debug screen or an external overlay, at 1080p, fixed render distance 12, for the four shipped profiles. Store as `docs/testing/baseline_perf.md`.
6. Add a `NO_INJECT` note to the README explaining precisely what the harness stub does and what it cannot catch (uniform binding, image feedback hazards, driver preprocessor leniency).

**D. Runnable deliverable**

- `./tools/shadercheck/run_checks.sh` green on a fresh clone after `bootstrap_glslang.sh`.
- CI runs it on every push.
- `build/photon-<sha>.zip` installable in Iris 26.3.
- `docs/testing/baseline_protocol.md` + `baseline_perf.md` + a `docs/testing/baseline/` image set reproduced by the user.
- All existing features work: sky, clouds, fog, water, VL, TAAU, bloom, grading, all three dimensions.

**E. Acceptance criteria**

- [MEASURED] 308/308 compute-fragment and 780/780 wrapper-option cases pass with `glslang 15.0.0`.
- [MEASURED] `voxel_packing_test.py` and `properties_lint.py` pass (3 known duplicate warnings tolerated).
- In-game: no shader compile errors in `latest.log` for Overworld / Nether / End, with `SHADOW` on and off, `RT_REFLECTIONS` on and off, `RAYTRACED_GI` on and off, `TAAU` off/0.75/0.50. [ASSUMPTION — requires the user's machine]
- The 6 symptoms are reproduced and each has a dated capture, **or** is recorded as "did not reproduce" with the exact configuration used.
- Baseline frame time recorded for the four profiles.
- **Blocking:** no Stage 1 work starts until the 6 symptoms have a recorded baseline, because Stage 1 changes AO and Stage 3 changes GI; without a baseline, regressions are indistinguishable from fixes.

**F. Regression and recovery**

Risks: the CI job flags pre-existing harness-only failures (COLORWHEEL/Voxy injection artifacts) as regressions. Mitigation: the harness's known-artifact list is explicit in `README.md`; new failures must be triaged against `6e67b36` before being waived.

Recovery: Stage 0 touches no shader rendering code, so `git revert` of the CI/docs commits restores behaviour exactly.

**G. Risks and alternatives**

- Most likely problem: the user's GPU (NVIDIA, per the audit's implied setup) accepts the float-in-`#if` code, so the P0 fix may appear to "change nothing". Document that the fix is for strict compilers (Mesa/Intel/AMD on Linux) and that NVIDIA leniency is the reason it was missed.
- Alternative: if CI on GitHub is unavailable, use a `pre-push` hook with the same script.

**H. Effort and dependencies**

Low complexity. No technical uncertainty in the static part; the in-game part depends on user availability. Blocks every later stage.

---

### Stage 1 — Restore removed capability (no silent removals)

**A. Purpose and scope**

*Primary objective:* make the fork a strict superset of upstream in *capability*, so that replacing the lighting system is not entangled with deleting unrelated features.

*Included:* restore selectable SSAO/GTAO as the non-RTGI AO path; restore the Photonics integration stub and `ph_lights.json`; decide and document the fate of LPV volumetric fog; correct `README.md` if any claim was over-broad.

*Excluded:* the contact-AO implementation itself (kept, but no longer the only AO); any GI algorithm change.

*Why here:* the brief requires "no silent removal of existing features" and "do not remove unrelated features merely because the lighting architecture changes". Stage 1 is a small, low-risk stage that removes a class of user-visible regression before more invasive work.

**B. Starting state**

Stage 0 complete. Verified gaps: `settings.glsl:160-161` defines only `SHADER_AO_NONE`; `include/lighting/ao/{gtao,ssao}.glsl` deleted; `shaders/photonics/*` and `ph_lights.json` deleted; `lpv_fog.glsl` deleted while `AIR_FOG_COLORED_LIGHT_SHAFTS` remains in `shaders.properties`.

**C. Implementation**

1. Restore AO. Re-add `include/lighting/ao/ssao.glsl` and `include/lighting/ao/gtao.glsl` from `6e67b36` (`git checkout 6e67b36 -- shaders/include/lighting/ao/`), and re-add the three `SHADER_AO_*` defines with `SHADER_AO` defaulting to `SHADER_AO_GTAO` when `RAYTRACED_GI` is **off**, and `SHADER_AO_NONE` when it is on. Implementation: in `settings.glsl`,
   ```glsl
   #define SHADER_AO_NONE 0
   #define SHADER_AO_SSAO 1
   #define SHADER_AO_GTAO 2
   #ifdef RAYTRACED_GI
     #define SHADER_AO SHADER_AO_NONE
   #else
     #define SHADER_AO SHADER_AO_GTAO // [SHADER_AO_NONE SHADER_AO_SSAO SHADER_AO_GTAO]
   #endif
   ```
   Then update the five profile strings in `shaders.properties` to drop the hardcoded `SHADER_AO=SHADER_AO_NONE`, and re-add `SHADER_AO` to `screen.raytracing` or `screen.shadows` as appropriate.
2. Restore Photonics. `git checkout 6e67b36 -- shaders/photonics/ shaders/ph_lights.json`. Then verify `run_checks.sh` still passes with the restored includes, and add the `photonics` include point into the new GI chain so the mod's `write_indirect()` still receives GI (the upstream consumer is `deferred4`; keep that name so the mod's expectations hold).
3. LPV fog decision. Two options: (a) restore `lpv_fog.glsl` behind `AIR_FOG_COLORED_LIGHT_SHAFTS` fed by the new clipmap instead of LPV — more work, deferred to Stage 8; (b) remove the `AIR_FOG_COLORED_LIGHT_SHAFTS` option and document that coloured light shafts are unavailable in this fork. **Recommendation: (b) now, (a) revisited at Stage 8** — a dangling option that does nothing is worse than an honest absence. Use `properties_lint.py` to enforce that no option is orphaned.
4. Extend `tools/shadercheck/properties_lint.py` with an "orphan option" check: every identifier in `screen.*` and `sliders` must appear in `settings.glsl` and be consumed by at least one shader (`grep` for the macro beyond its `#define`). This is the mechanical guard against repeating the pattern.
5. Update `README.md` features list accordingly.

**D. Runnable deliverable**

Pack with: RTGI on ⇒ hybrid GI as today, no AO; RTGI off ⇒ upstream-equivalent SSAO/GTAO path, analytic sky/block lighting, working reflections. Photonics mod loads and its light list resolves. `properties_lint.py` enforces no orphan options.

**E. Acceptance criteria**

- `SHADER_AO=SHADER_AO_GTAO` with `!RAYTRACED_GI` compiles in all three dimensions and all option combinations (add 3 matrix variants).
- `SHADER_AO` no longer appears in any profile string.
- `properties_lint.py` reports 0 orphan options.
- In-game: toggling `RAYTRACED_GI` off restores a visibly AO-shaded image in corners (compare against an upstream `6e67b36` build of the same scene at the same camera).
- Photonics: mod initialises, `latest.log` shows no missing-file errors. [ASSUMPTION — needs the mod installed]

**F. Regression and recovery**

Breakable: the restored AO includes reference `colortex6`/`colortex14` semantics that `d3_ao.fsh` now also writes. Conflict risk is real: upstream `d3_ao` *was* the GTAO/SSAO pass. Mitigation: keep `d3_ao.fsh` as the contact-AO pass and put restored SSAO/GTAO behind a distinct `#if SHADER_AO != SHADER_AO_NONE && !defined RAYTRACED_GI` branch that fully replaces the contact-AO body.

Recovery: `RTGI_AO_FALLBACK` is a compile-time option; setting `SHADER_AO=SHADER_AO_NONE` returns to today's behaviour exactly.

**G. Risks and alternatives**

- Restoring GTAO may bring back its own upstream artifacts (it was replaced for a reason). Acceptable: it is only active when RTGI is off.
- Photonics' `shader_interface.glsl` may reference uniforms that changed. Verify by compiling it in the matrix; if it does not compile, restore it but exclude it from the active include graph and note the mod incompatibility explicitly rather than shipping a broken include.

**H. Effort and dependencies**

Low complexity, ~1 day. Depends on Stage 0. Blocks nothing, but must precede Stage 10's "no silent removal" audit.

---

### Stage 2 — Diagnostics

**A. Purpose and scope**

*Primary objective:* make GI failures observable, so that every later stage can be validated by looking at a buffer instead of guessing from the shaded image.

*Included:* `DEBUG_SAMPLER`-style numeric debug selection; views for `rtgi_raw`, `rtgi_accum`/history, `rtgi_filtered`, voxel occupancy / block ID / albedo / light levels / sky weight, ray hit–miss masks, per-pixel ray count, temporal history-rejection mask, variance; a GPU timing breakdown per GI pass.

*Excluded:* any change to the lighting maths.

*Why here:* the audit's hardest bugs (seam leaks, non-additive light, view dependence) were diagnosed by reading code because no buffer could be inspected. `DEBUG_SAMPLER` already exists in `sliders` but has no consumer in the RTGI path [VERIFIED].

**B. Starting state**

Stage 0 complete. `shaders.properties:119` lists `DEBUG_SAMPLER`; no consumer exists in `include/lighting/rt/*` or `program/rtgi/*`.

**C. Implementation**

1. Define a shared enum in `include/global.glsl` (or a new `include/debug/gi_debug.glsl`):
   ```glsl
   #define GI_DEBUG_OFF 0
   #define GI_DEBUG_RAW 1
   #define GI_DEBUG_HISTORY 2
   #define GI_DEBUG_FILTERED 3
   #define GI_DEBUG_VOXEL_ID 4
   #define GI_DEBUG_VOXEL_LIGHT 5
   #define GI_DEBUG_VOXEL_ALBEDO 6
   #define GI_DEBUG_HIT 7
   #define GI_DEBUG_REJECT 8
   #define GI_DEBUG_VARIANCE 9
   #define GI_DEBUG_PROBE 10   // added in Stage 8
   ```
   `DEBUG_SAMPLER` becomes this selector, kept in `settings.glsl` and already in `sliders`.
2. In `deferred4` (`d4_deferred_shading.fsh`), after lighting is computed, `if (GI_DEBUG != OFF) gl_FragColor = debug_encode(GI_DEBUG, …); return;`. `debug_encode` lives in `include/debug/gi_debug.glsl` so no debug code leaks into the hot path when off (the branch is uniform-selected; keep all debug reads inside it so dead-code elimination works).
3. Pass-through channels: `rtgi_raw_img.a` currently carries `sky_weight`. For debug, also accumulate a packed hit mask — cheapest route is a second small output image (`rtgi_debug_img`, `rgba8`, half res) written only when `GI_DEBUG != OFF`, containing `(hit_ssgi, hit_voxel, hit_sky, rejected)` bits plus a 4-bit ray count.
4. Voxel ID / light / albedo debug views read `voxel_sampler` directly in `deferred4` by reconstructing `scene_to_voxel_space(scene_pos)` — no extra pass needed.
5. Timing: add `#if defined GI_PROFILE` blocks that write `frameTimeCounter` deltas to `colortex4` unused rows, or simpler and safer, document reliance on Iris's built-in pass timing. **Recommendation:** do not implement custom timers (GL timer queries are unavailable from a shaderpack); use Iris's debug profiler and document how.
6. Document each view in `docs/testing/debug_views.md` with one screenshot per view and what a healthy image looks like.

**D. Runnable deliverable**

`DEBUG_SAMPLER` cycles through 9 GI views plus OFF. `run_checks.sh` unchanged and green (add `GI_DEBUG=…` matrix variants for at least 3 values).

**E. Acceptance criteria**

- Each view renders a non-uniform, interpretable image in the white-room test.
- `GI_DEBUG_HIT` shows SSGI coverage falling off with distance and voxel coverage filling the rest — this is the first objective measure of the hybrid split.
- `GI_DEBUG_VOXEL_ALBEDO` shows correct per-block colours (red wool red, grass green) with no grey blocks outside the palette fallback.
- `GI_DEBUG_VOXEL_ID` reveals the `should_voxelize` exclusions directly (water and block 80 absent).
- `GI_DEBUG_REJECT` on a camera pan should show the disocclusion band; this becomes Stage 7's acceptance image.
- Zero measurable frame-time cost with `GI_DEBUG_OFF` (≤ 1 % at 1080p).

**F. Regression and recovery**

Risk: debug branches get inlined and inflate register pressure. Mitigation: keep every debug read inside a single non-uniform-branch guard; verify with the existing matrix and a frame-time comparison against Stage 0.

Recovery: `DEBUG_SAMPLER = 0` is the default and short-circuits.

**G. Risks and alternatives**

Alternative: rely on RenderDoc/apitrace. Rejected — the whole point is a *user* being able to say "here is the variance view at this spot", and RenderDoc captures are not reproducible for a non-developer tester.

**H. Effort and dependencies**

Low complexity, ~2 days. Depends on Stage 0. Blocks the ability to validate 3, 5, 6, 7, 8 — treat as required.

---

### Stage 3 — Break the GI feedback loop and fix energy accounting

**A. Purpose and scope**

*Primary objective:* make GI a function of the scene, not of the previous frame's shading. This is the highest-value correctness change in the plan.

*Included:* a new `radiance_direct` target holding **direct lighting only**; SSGI reads it instead of `colortex5`; removal of the `mc_block` double count; replacement of the `1.6 * RTGI_BRIGHTNESS` magic constant with a documented normalisation; removal of the `RTGI_SSGI_LOCAL_LIGHT_SCALE` and `RTGI_CAVE_AMBIENT_SCALE` damping crutches (they exist only to compensate for B1).

*Excluded:* multi-bounce, new scene representation, new denoiser. Those are Stages 4–8.

*Why here:* B1 is the root cause of the user's primary complaints. Fixing it before adding bounces prevents building multi-bounce on an estimator that is itself view-dependent.

**B. Starting state**

Stage 1, 2 complete. `rtgi_trace.csh` reads `colortex5`; `ssgi.glsl` reprojects the hit into the previous frame and samples that colour; `diffuse_lighting.glsl` adds `mc_block` unconditionally.

**C. Implementation**

1. **Where to write `radiance_direct`.** The cleanest point is the end of `deferred4`, but SSGI needs it earlier (at `deferred1_a` of the *next* frame is acceptable — that is one frame of latency, not a feedback loop, because direct light is a function of the scene, not of GI). Two options:
   - **(3a) One-frame-latency direct buffer (recommended, minimal risk).** Add `colortex18` = `RGBA16F`, full res, `colortex18Clear = false`. Write it at the end of `d4_deferred_shading.fsh` with **direct diffuse + direct specular** only (before adding `rtgi_local`/`rtgi_sky`/`analytic_sky`). `ssgi.glsl` then samples `colortex18` with the **same** reprojection it already does. This removes the feedback loop while keeping the existing reprojection machinery: the sampled value no longer contains GI, so there is nothing to feed back.
   - **(3b) Same-frame direct buffer.** Compute direct light in a separate pass before the trace. Cleaner, but duplicates a large part of `d4` and risks divergence. Not recommended.
   State clearly in the option comment that 3a keeps a **one-frame** latency for screen-space hits, which is acceptable (direct light of a static scene is frame-invariant) but will still show a one-frame lag on fast scene motion. Stage 6 replaces the screen-space path's colour source with a current-frame G-buffer + direct evaluation, removing the lag entirely.

2. **Energy accounting — remove the double count.** In `diffuse_lighting.glsl`, replace
   ```glsl
   lighting += rtgi_local + rtgi_sky * sky_retention + analytic_sky * (1.0 - sky_retention) * rtgi_sky_weight;
   …
   lighting += mc_block;                     // unconditional
   ```
   with a single origin per term:
   ```glsl
   // RTGI carries traced bounce light (sky-origin + emissive/blocklight-origin).
   // Direct block light is NEVER added here when RTGI is on, because voxel hits
   // already carry the emitter's contribution through the bounce.
   vec3 indirect = rtgi_local + rtgi_sky * sky_retention
                 + analytic_sky * (1.0 - sky_retention) * rtgi_sky_weight;
   vec3 direct_block = get_block_lighting(scene_pos, flat_normal, light_levels, ao, directional_lighting);
   float edge_fade = smoothstep(voxel_edge_fade_end, voxel_edge_fade_start, get_voxel_edge_distance(scene_pos));
   // Outside the voxel volume only the analytic term is trustworthy, so blend
   // the direct term in there and let RTGI dominate inside.
   lighting += indirect + direct_block * edge_fade;
   ```
   Note: `edge_fade` is 0 inside the volume and 1 outside, which is the *opposite* of the current code's unused `voxel_edge_fade` (currently computed and discarded — a verified dead variable).
   **Careful:** `direct_block` here is the vanilla lightmap term, which is *not* a tracer result. Using it only outside the voxel volume means interiors inside the volume rely on RTGI alone — which is why Stage 8 (DDGI) is required before the analytic term can be retired. Keep a temporary `RTGI_DIRECT_BLOCK_FALLBACK` option (default on) so the transition is reversible.

3. **Replace the magic 1.6.** Derive the normalisation: for a Lambertian surface with albedo ρ radiance from a sampled indirect signal, `L_o = ρ/π · E` and the trace returns radiance, so `final_diffuse = albedo * lighting / π`. The current code applies `1.6 * RTGI_BRIGHTNESS` to radiance *before* that division, which double-scales. Replace with a single, documented `RTGI_INTENSITY` (default 1.00) whose calibration procedure is: in the white-room test (Stage 6), tune until indirect illuminance on the floor matches `ρ·E_incident/π` computed from the sun/sky constants, then freeze.

4. **Retire the damping crutches.** Set `RTGI_SSGI_LOCAL_LIGHT_SCALE`'s default to `1.00` (the reason it was zeroed — view dependence — is removed by 3a) and `RTGI_CAVE_AMBIENT_SCALE` to `1.00`, then re-evaluate in Stage 6 testing. If caves are too bright afterwards, the cause is transport, not damping, and Stage 8 fixes it properly.

5. **Remove dead code** found during this audit: `voxel_edge_fade` (computed, unused) in `diffuse_lighting.glsl:337-341`.

**D. Runnable deliverable**

Pack where GI is a function of scene state: pointing the camera away from a lit wall and back does not change that wall's indirect light. Menu defaults updated, with the changed defaults documented in `docs/testing/option_changes.md`.

**E. Acceptance criteria**

- **Camera-independence test [primary]:** sealed 7×7×5 sandstone room, one torch in a wall niche, fixed player position. Capture at yaw 0°, 90°, 180°, 270°. The mean absolute difference of the *indirect-only* channel (`GI_DEBUG_FILTERED` minus TAA) between any two yaws must be **< 5 %** of the mean indirect value. Today the difference is large and directional [ASSUMPTION: quantified by the user in Stage 0].
- **No-double-count test:** single torch, white walls. Total wall luminance must be within ±10 % of the value obtained with `RTGI_DIRECT_BLOCK_FALLBACK` on vs off when the surface is inside the voxel volume, i.e. the two paths are equivalent in magnitude, not additive.
- Static matrices: 308 + 780 → ≥ 330 + 800 cases, 0 failures (new `colortex18` requires a `check.py` update).
- `latest.log` clean in all three dimensions.

**F. Regression and recovery**

Breakable: (i) `colortex18` allocation changes the buffer count — verify against `IrisLimits.MAX_COLOR_BUFFERS = 32` and against `check.py`'s known-image list; (ii) changing the block-light path makes interiors darker/lighter, which users will read as a regression; (iii) `rtgi_filtered_img.a` semantics unchanged, so `sky_retention` logic still holds.

Detection: the Stage 0 baseline captures are the reference; any change larger than the acceptance windows above is investigated before proceeding.

Recovery: `RTGI_GI_INPUT = LATENCY_ONE_FRAME | DIRECT_ONLY` plus `RTGI_DIRECT_BLOCK_FALLBACK` give four combinations, including today's exact behaviour (`LEGACY`), so a bisect is always possible from the menu.

**G. Risks and alternatives**

- Most likely problem: with the feedback removed, screen-space GI becomes **noisier**, because the previous frame's smoothed composite was acting as an implicit denoiser. This is expected and is precisely why Stage 7 (SVGF) exists. Do not respond by reintroducing feedback; respond by improving reconstruction. State this in the stage notes so the temptation is pre-empted.
- Fallback if 3a proves visually unstable: restrict SSGI to on-screen **hit validation** only (use it for visibility, but take radiance from the current-frame G-buffer + direct evaluation). That is Stage 6's design and can be pulled forward.

**H. Effort and dependencies**

Medium complexity, ~4–6 days. Depends on Stages 1–2 (AO restored, debug views available to measure the camera-independence metric). Blocks 6, 7, 8.

---

### Stage 4 — Scene core v2: clipmap, additive light, full coverage

**A. Purpose and scope**

*Primary objective:* replace the single cubic voxel volume with a hierarchical clipmap and fix the two data-model defects that make multi-bounce impossible (non-additive light, vanilla-lightmap block light).

*Included:* 4-level clipmap at 64³ texels; per-level spacing 1/2/4/8; a separate **additive** coloured light image; voxelization from the shadow pass **and** the camera terrain pass; entity voxelization behind an option; optional DH/Voxy coarse voxelization; a per-block shape class nibble reserved for Stage 5; material table extended with emission and roughness.

*Excluded:* level-transition DDA (Stage 5 — Stage 4 keeps the DDA reading L0 only, so it remains runnable), DDGI (Stage 8).

*Why here:* the clipmap is a prerequisite for range, and the additive light image is a prerequisite for coloured transport. Both are data-model changes that must land before the algorithms that consume them.

**B. Starting state**

Stage 3 complete. `voxel_img` is one `r32ui` 3D image at `VOXEL_VOLUME_SIZE`³, cleared each frame, written only by `shadow.vsh`.

**C. Implementation**

1. **Image declarations** in `shaders.properties`. Note Iris's `image.<name>` directive must be declared per size variant; clipmap levels are fixed at 64³ so the declaration is unconditional:
   ```
   image.voxel_clipmap_l0 = voxel_l0_sampler red_integer r32ui unsigned_int true false 64 64 64
   image.voxel_clipmap_l1 = voxel_l1_sampler red_integer r32ui unsigned_int true false 64 64 64
   image.voxel_clipmap_l2 = voxel_l2_sampler red_integer r32ui unsigned_int true false 64 64 64
   image.voxel_clipmap_l3 = voxel_l3_sampler red_integer r32ui unsigned_int true false 64 64 64
   image.voxel_light_l0   = voxel_light_l0_sampler rgba rgba16f half_float true false 64 64 64
   … (l1..l3)
   ```
   Verify the exact argument order against Iris 26.3 `ImageInformation.create(...)` before writing — the existing `image.voxel_img` line is the template.
   Memory: 4 × (64³ × 4 B) = 4 MiB for geometry, 4 × (64³ × 8 B) = 8 MiB for the additive light field. Total 12 MiB, replacing 8 MiB.

2. **World-stable addressing.** The current `scene_to_voxel_space` uses `fract(cameraPosition)` plus a look-direction grid centre, so the grid *translates with the camera* every frame and every stored value is effectively re-derived each frame. For a clipmap this is still acceptable *if* everything is rebuilt each frame (it is), but the **origin must snap to whole blocks per level** so that a level's texel grid aligns with its spacing:
   ```glsl
   vec3 clipmap_origin(int level) {           // world-block aligned
       float spacing = exp2(float(level));
       vec3 cam = floor(cameraPosition);
       return floor(cam / (spacing * 64.0)) * (spacing * 64.0);
   }
   vec3 scene_to_clipmap(int level, vec3 scene_pos) {
       return (scene_pos + cameraPosition - clipmap_origin(level)) / exp2(float(level));
   }
   ```
   Compute in **absolute world space** (`scene_pos + cameraPosition`) to avoid the fractional-offset trick; keep a `cameraPosition`-relative variant only where float precision demands it (beyond ~10^5 blocks, use a per-level relative origin — document the limit).

3. **Levels are written by snapping the vertex position** rather than by re-voxelizing per level: for a vertex at world position `p`, for each level `l` compute `coord = floor(scene_to_clipmap(l, p))` and write if inside. Four atomic writes per vertex instead of one. Cost is acceptable because the write is `imageAtomicMax` on a 32-bit integer.
   Guard: skip levels the fragment's chunk does not intersect (a cheap `is_inside` test already exists).

4. **Additive coloured light field (fixes B5).** Geometry stays in `r32ui` with `imageAtomicMax` (deterministic winner, correct for *presence*). Light is accumulated **separately** in `voxel_light_l*` with `imageAtomicAdd` on `rgba16f`, encoding `(r, g, b, weight)`:
   ```glsl
   // per emitter vertex, for each voxel in its influence radius with clear line of sight
   imageAtomicAdd(voxel_light_l0, coord, vec4(emitter_color * attenuation, attenuation));
   ```
   The `.a` channel is the accumulated weight, so the DDA can normalise and also measure how many emitters contribute. `imageAtomicAdd` on `rgba16f` is **not** guaranteed by GLSL for all formats — `r32ui` and `rgba32f` are the portable choices for atomics. **Therefore use two `r32ui` images per level** with packed 16-bit RGBA, or `rgba32f` (which is 16 B/texel). Decision: use **`r32ui` with two half-float pairs packed** (portable, 4 B/texel, 1 MiB/level) and accept 16-bit accumulation precision with a documented clamp. Total light field = 4 MiB.
   *This detail must be verified on the target GPU in Stage 4's first task; if `imageAtomicAdd` on `rgba16f` is available and tested, prefer it for simplicity.*

5. **Emitter reach without the radial hack.** Delete the 9³ injection loop (`voxel_update.glsl:99-171`). Replace with: emitters write their own voxel (already done) and the **probe cache** (Stage 8) carries their light into the volume. Until Stage 8 lands, keep `RTGI_POINT_LIGHT_STRENGTH` default `0.00` and document that emissive GI is limited to direct hits — a *known, temporary* limitation, not a permanent hack.

6. **Voxelization coverage (fixes B3).** Add a second caller: include `voxel_update.glsl` in `gbuffers_all_solid.vsh` behind `#if defined RAYTRACED_GI`, gated by the same `is_voxel_terrain_stage()`, so camera-visible terrain is always voxelized even when it lies outside the shadow frustum. Union of both passes covers strictly more than either.
   - Entities: add an option `RTGI_VOXELIZE_ENTITIES` (default off) that allows writes from `PROGRAM_SHADOW_ENTITIES`. Entity geometry is not block-aligned, so voxelizing it produces blocky shadows of mobs — document that.
   - DH/Voxy: `dh_terrain.vsh` and `voxy_opaque.glsl` do not include `voxel_update.glsl` [VERIFIED]. Add coarse writes at level 3 only (spacing 8), provided the DH/Voxy vertex shaders expose a usable world position. If they do not, record it as an unresolved limitation in `docs/known_limitations.md` and make the plan's "distant terrain" test expectation explicit.

7. **Reserve shape class.** Repack the 32-bit geometry payload to include a 3-bit shape class (`cube / slab / stairs / fence / pane / plant / glass / other`) so Stage 5 can use it without another format change. Current layout has a free slot after flags; verify with `voxel_packing_test.py` and extend that test to cover the new field.

**D. Runnable deliverable**

Pack with a 4-level clipmap; the DDA still reads L0 only (unchanged behaviour inside 64 blocks); GI covers camera-visible terrain; two differently-coloured lamps in one corridor produce additively blended light in `GI_DEBUG_VOXEL_LIGHT` (new view). `VOXEL_VOLUME_SIZE` is removed from the menu.

**E. Acceptance criteria**

- Total custom-image VRAM for the scene core ≤ 12 MiB at every setting (readable from `shaders.properties`; record the arithmetic in `docs/testing/memory_budget.md`).
- `voxel_packing_test.py` covers the new layout and passes 1,000 randomized round trips including shape class.
- `GI_DEBUG_VOXEL_ID` shows terrain behind the camera (outside the shadow frustum) is now present — this is the direct test of the coverage fix.
- Two lamps (red + blue) 4 blocks apart in a corridor: the light-field debug view shows a red→purple→blue gradient, proving additive accumulation. Today the value would be one colour or the other.
- No frame-time regression vs Stage 3 beyond 10 % (the extra atomic writes are the main new cost).
- Static matrices green after adding the 10 new image declarations to `check.py`.

**F. Regression and recovery**

Breakable: (i) image count and `check.py` stub list; (ii) `imageAtomicMax` + `imageAtomicAdd` on the same volume needs distinct images (done); (iii) clearing: Iris clears non-persistent custom images per frame — verify all 8 clipmap images are declared with the appropriate clear flag, and that the light field is cleared (it must be, since it is rebuilt from scratch).
Detection: `GI_DEBUG_VOXEL_*` views plus frame-time comparison.
Recovery: `RTGI_SCENE_CORE = LEGACY | CLIPMAP` compile option keeping `voxel_img` alive for one stage so a bisect is one option toggle, then delete the legacy path at Stage 6.

**G. Risks and alternatives**

- `imageAtomicAdd` portability (described above) — highest technical uncertainty in this stage. Verify first.
- Coarse levels L2/L3 will look blocky; if that is judged unacceptable, collapse to 3 levels (1/2/4 blocks, 256 blocks range, 3 MiB) — acceptable fallback, still 4× today's range.
- Alternative to a clipmap: keep one volume but make it `RGBA8`-packed with a 2-level mip chain. Rejected: mip rebuild cost per frame and no range gain.

**H. Effort and dependencies**

High complexity, ~2 weeks. Depends on 2 and 3. Blocks 5, 8, 9.

---

### Stage 5 — Ray queries v2: clipmap DDA, shapes, any-hit

**A. Purpose and scope**

*Primary objective:* a single, tested ray-query interface over the clipmap that every later consumer (per-pixel trace, probe update, reflection fallback, PT bounces) uses.

*Included:* clipmap DDA with level transitions; deterministic origin/seam handling (replacing the hash jitter); block-shape intersection using the reserved shape class; an `any_hit` shadow query for probe visibility and NEE; a Python mirror of the traversal for unit testing; removal of the `normal*0.15` fixed bias in favour of the existing `get_shadow_bias()`.

*Excluded:* radiance estimation policy (that is Stage 6/8); probe updates (Stage 8).

*Why here:* every later stage multiplies ray consumption. A wrong or leaky traversal then multiplies too. This is the last point where it can be fixed cheaply.

**B. Starting state**

Stage 4 complete; L0-written clipmap with shape class; existing `trace_voxel_dda` reads a single volume.

**C. Implementation**

1. **Interface** (`include/lighting/rt/ray_query.glsl`, new):
   ```glsl
   struct RayHit {
       bool   hit;
       vec3   position;      // world-relative scene space
       vec3   normal;
       vec3   albedo;
       vec3   emission;
       float  roughness;
       float  distance;
       vec3   transmittance; // accumulated stained-glass tint
       uint   block_id;
       uint   shape;         // shape class of the hit block
   };

   RayHit trace_ray(vec3 origin, vec3 dir, float max_dist, float dither, int level_hint);
   bool   trace_any_hit(vec3 origin, vec3 dir, float max_dist, float dither); // shadow / visibility
   ```
   Keep the old signature as a thin wrapper until Stage 6 finishes migrating call sites.

2. **Level transitions.** Traverse the level containing the origin. On exit (or when `t > level_max_dist`), re-seed at the next coarser level using the same `t`, scaling `delta_t` by the spacing ratio. Because levels are block-aligned and overlap, the seam is handled by starting the coarse DDA at `t - 0.5 * coarse_spacing` to avoid a gap. Document the invariant: *a ray must never be able to pass from level l to l+1 without advancing t.* Add an assertion-style debug counter for "t did not advance".

3. **Deterministic seam handling.** Replace `rtgi_voxel_ray_jitter`'s hashed ±0.05 perturbation with: (a) bias the origin by `0.25` along the surface normal (already done) and `0.05` along the ray (already done); (b) if any component of `dir` is within `1e-4` of 0, push it to `±1e-4` with a sign from the dither — this removes the multi-step degenerate case rather than hoping a hash hides it. Keep a `RTGI_SEAM_JITTER` option to compare against today's behaviour.

4. **Shape intersection.** For hits whose shape class is not `cube`, refine the hit distance with an analytic test for that shape (slab half-height, stair quarter, fence post + rails, pane thickness). This is where SEUS's `BlockShapes_*` files prove the technique is viable [VERIFIED: they implement exactly this, keyed by a shape ID]. Implement independently from public block geometry (`slab` = 8 px, `stairs` = two boxes, `fence` = post + 2 rails per connection, `pane` = 2 px centre). Keep the set small: `cube, slab, stairs, fence, pane, plant`. Anything else falls back to cube.

5. **`any_hit` fast path.** For probe visibility and shadow rays, terminate on the first opaque voxel; skip emission/light-field accumulation entirely. This is the single biggest performance win available for Stage 8.

6. **Python mirror** `tools/shadercheck/dda_test.py`: reimplement `trace_ray` in Python over a synthetic 8³ volume with hand-placed blocks; assert (i) monotonic `t`, (ii) no missed voxel on axis-aligned rays, (iii) no traversal through a solid voxel on a diagonal, (iv) exact hit position within `1e-4`, (v) level transitions never skip a block. Run in `run_checks.sh`.
   To keep the GPU and CPU implementations honest, generate the Python volume from the same packing function (`voxel_storage.glsl`'s layout is already mirrored by `voxel_packing_test.py`).

7. **Bias.** Replace `sample_voxel_sun_shadow`'s `normal * 0.15` with the pack's `get_shadow_bias(...)` so voxel bounce shadows match the main pass. Add a `voxel_shadow_bias_scale` constant separate from the surface bias.

8. **Normal reconstruction on non-cube hits.** For a slab/pane hit, return the face normal of the intersected sub-box, not the block's face normal. For a `plant` shape, return the ray-facing hemisphere normal so GI does not darken foliage incorrectly.

**D. Runnable deliverable**

Pack where all GI consumers call `trace_ray` / `trace_any_hit`; `GI_DEBUG_HIT` now shows correct sub-block silhouettes on stairs and fences; the Python DDA test passes in CI.

**E. Acceptance criteria**

- `dda_test.py`: all 5 properties pass over ≥ 10,000 randomized rays, including rays exactly axis-aligned and exactly corner-diagonal.
- **Seam leak test:** the "sunlit sand wall" scene from Step 12 — a 1-block-thick sand wall with the sun behind it — must show **zero** indirect contribution on the shadowed side (`GI_DEBUG_FILTERED` at 0, not merely small).
- **Shape test:** a staircase in a lit room shows a staircase-shaped GI gradient on the wall behind it, not a blocky one.
- **Bias test:** a masonry wall lit by a torch shows no dark banding at contact (peter-panning) and no light bleeding through the corner.
- No DDA step-budget increase: the fixed 64-texel levels mean `MAX_STEPS` is a constant (~96 per level, 4 levels) regardless of any user setting. Confirm the generated shader has a constant loop bound.
- Static matrices green; `dda_test.py` in `run_checks.sh`.

**F. Regression and recovery**

Breakable: shape intersection changes hit distances, which changes *everything* downstream (light levels, AO, denoise cues). Expect a visible one-time shift in GI on stairs/fences/panes; capture it as the new baseline.

Detection: `dda_test.py` + seam test + shape test, all of which are binary and automated.

Recovery: `RTGI_SHAPE_QUALITY = 0 | 1 | 2` (cube-only / slabs+stairs / full set), mirroring SEUS's `RAYTRACE_GEOMETRY_QUALITY` concept, so a bisect is a single option. `RTGI_SEAM_JITTER` selects old vs new seam handling.

**G. Risks and alternatives**

- Shape intersection multiplies branch divergence inside the hottest loop. Mitigation: only run shape refinement **once**, on the final hit (not per step), and only when `shape != cube` — one branch, predictable for the common all-cube case.
- Level transitions are the most bug-prone part. Mitigation: implement with L0 only and L0+L1 first, ship L0+L1, then add L2/L3 behind an option.
- Alternative if transitions prove too costly: "single-level-at-full-resolution within 64 blocks, one coarse 8-block level beyond" — a 2-level clipmap. Acceptable degrade.

**H. Effort and dependencies**

High complexity, ~2 weeks. Depends on 4. Blocks 6, 8, 9 (all of which consume the interface).

---

### Stage 6 — Single-bounce correctness and MIS hybrid composition

**A. Purpose and scope**

*Primary objective:* make one bounce of indirect light physically correct and reproducible, so that Stage 8's multi-bounce rests on a validated base and Stage 9's PT mode has a trustworthy reference.

*Included:* current-frame radiance for screen-space hits (removing the residual one-frame lag from Stage 3a); explicit MIS weights between the screen-space, voxel and sky estimators; a `1/π` audit of every radiance-producing path; correct emission handling for hit emitters; an analytic reference scene with a measured tolerance; retirement of the legacy `voxel_img` path.

*Excluded:* more than one bounce (Stage 8); the new denoiser (Stage 7) — Stage 6 ships on the Stage 3 temporal/filter chain, accepting noise.

*Why here:* MIS and energy are cheap to get right and expensive to retrofit; and a measured reference is the only way to prove Stage 8 and 9 are improvements.

**B. Starting state**

Stage 5 complete. `evaluate_hybrid_rtgi_ray` short-circuits on SSGI hit, else voxel hit, else sky. `voxel_dda.glsl` multiplies bounce terms by `voxel_bounce_rcp_pi`. `diffuse_lighting.glsl` applies `1.6 * RTGI_BRIGHTNESS`.

**C. Implementation**

1. **Current-frame screen-space radiance.** Change `ssgi.glsl` so that on a validated hit it does not sample a colour buffer at all. Instead:
   - take the hit's G-buffer normal, albedo and light levels from `colortex1/2` at `hit_framebuffer_uv` (already fetched for validation);
   - evaluate the hit surface's **direct** lighting analytically using the same functions `deferred4` uses (`get_sky_lighting`, `get_block_lighting`, sun term with `shadowtex0` PCF);
   - return `albedo/π × direct_irradiance`.
   This removes `colortex18` from the SSGI path entirely and makes screen-space and voxel hits produce the **same kind of quantity** — which is what MIS needs. `colortex18` remains useful for the *validation* heuristic only (compare colours to reject false hits).

2. **MIS weights.** With three estimators for the first indirect bounce (screen-space, voxel, sky), use the balance heuristic over their probabilities of producing the sampled direction. In practice the cleanest formulation inside a shaderpack is:
   - Screen-space and voxel DDA are **not** competing samplers of the same integral — they are *disjoint region* estimators (on-screen vs off-screen geometry). MIS between them reduces to a hard partition with a **feathered boundary**: weight `w_ss = smoothstep(0, edge_width, screen_edge_distance)` and `w_vx = 1 - w_ss`.
   - The sky fallback *is* a competing estimator of the environment term, so apply genuine MIS there: `w_sky = p_sky / (p_sky + p_bsdf)` with `p_sky` the probability that next-event estimation sampled the environment.
   Implement as:
   ```glsl
   vec4 eval_indirect(vec3 pos, vec3 n, vec3 dir, float dither) {
       SSGIHit s = trace_screen_space_gi(...);        // validated, current-frame radiance
       VoxelHit v = trace_voxel_dda(...);             // full clipmap
       float w_ss = s.hit ? smoothstep(0.0, 0.08, s.edge_fade) : 0.0;
       vec3 rad = s.radiance * w_ss + (v.hit ? v.radiance : sky_term()) * (1.0 - w_ss);
       return vec4(rad, sky_fraction);
   }
   ```
   This replaces the current short-circuit, whose bias is unquantified.

3. **`1/π` audit.** Grep every `radiance`-producing expression and confirm the factor. Known states after the audit fix: `voxel_dda` applies `voxel_bounce_rcp_pi` ✔; `emission_radiance` is radiance and must **not** be divided ✔; `sun_radiance = direct_sun_color * sun_vis * NoL` is *irradiance* and must be divided when converted to radiance ✔ (it is, in `bounce_radiance`). Add a unit comment block in `ray_query.glsl` documenting which quantities are radiance vs irradiance, because this is the single most common source of silent energy error in such code.

4. **Emission correctness.** An emitter hit should return its emission **plus** its reflected light. Currently a small emitter is only reachable if `RTGI_POINT_LIGHT_STRENGTH > 0`. With the radial hack gone, do the opposite: emitters are always opaque hits returning `emission`, and their *lighting of other surfaces* comes from the probe cache (Stage 8). Until Stage 8, this means a torch lights only surfaces it is visible to — correct, just dim. Document it.

5. **Reference scene and tolerance.** Add `docs/testing/reference_scenes.md` describing a **white furnace room**: 11×11×5 interior, all surfaces `white_concrete` (albedo 1.0 nominal), no sky (sealed), one centred light. Analytic reference: for a diffuse enclosure with uniform albedo ρ and a single Lambertian emitter of radiance L_e and area A_e, the average interior radiosity satisfies `E = (ρ/(1-ρ)) · (A_e/A_total) · π L_e` for the *infinite-bounce* solution; for **one bounce** it is simply `E_1 = (A_e/A_total) · π L_e`. Compare the one-bounce measurement to `E_1`. This gives a numerical target, not a vague "looks right".
   Also add a **coloured cabinet**: red wall, white floor, sun through one opening. One bounce must produce red on the floor whose chromaticity matches `albedo_red × sun_spectrum`, measurable by sampling a fixed pixel.

6. **Retire `voxel_img`.** Delete the legacy single-volume image and `VOXEL_VOLUME_SIZE` handling once Stage 4's `RTGI_SCENE_CORE` legacy path is no longer needed. Update `settings.glsl`, `shaders.properties`, all five profiles, `en_US.lang`, `properties_lint.py`, `check.py`, and the reproduce list in `RTGI_AUDIT.md`.

**D. Runnable deliverable**

Pack with a validated single-bounce estimator, MIS composition, documented radiance/irradiance conventions, and a measured reference room. `RTGI_BRIGHTNESS` replaced by a calibrated `RTGI_INTENSITY = 1.00`.

**E. Acceptance criteria**

- **White furnace, one bounce:** mean interior illuminance within **±10 %** of `E_1 = (A_e/A_total)·π·L_e`. Upper failure bound 15 %.
- **White furnace, colour neutrality:** the measured interior chromaticity is within Δ(u′v′) < 0.005 of the emitter's (a pure grey/white room must stay neutral — this catches channel-dependent errors).
- **Coloured cabinet:** floor pixel chromaticity matches `albedo_red`-tinted sun within Δ(u′v′) < 0.01.
- **Camera independence (re-run of Stage 3's test):** now must be **< 2 %**, because the screen-space path no longer depends on history at all.
- **No double counting:** with `RTGI_DIRECT_BLOCK_FALLBACK` on and off, interior luminance differs by < 5 % inside the volume.
- Dead code removed: `voxel_img`, `VOXEL_VOLUME_SIZE`, `voxel_edge_fade` if still unused, `rtgi_voxel_ray_jitter` if `RTGI_SEAM_JITTER` is retired.
- Static matrices green with the retired images/options removed from the lint lists.

**F. Regression and recovery**

Breakable: replacing the screen-space colour source makes SSGI **much** noisier and changes its character (analytic direct evaluation has no denoising). This is intended; Stage 7 immediately follows. Communicate it as an intermediate state.

Detection: the furnace and cabinet tests are numeric; the camera test is numeric.

Recovery: `RTGI_SSGI_RADIANCE = PREVIOUS_FRAME | CURRENT_DIRECT` retains the old path for one stage.

**G. Risks and alternatives**

- Analytic direct evaluation for SSGI hits requires `shadowtex0` at the hit — an extra shadow lookup per screen-space hit, roughly doubling SSGI's texture cost. Mitigation: evaluate the shadow term once per hit (not per tap) and reuse; skip the sun term for hits facing away.
- If MIS across three estimators proves fiddly, ship the feathered partition (2a) first and add the sky MIS term second — they are separable.

**H. Effort and dependencies**

Medium-high complexity, ~1.5 weeks. Depends on 3 and 5. Blocks 8 and 9 (both need a validated single-bounce reference).

---

### Stage 7 — SVGF-class temporal reconstruction and à-trous filtering

**A. Purpose and scope**

*Primary objective:* replace six interacting hand-tuned constants with a measured, variance-driven reconstruction chain that survives camera motion, disocclusion and fireflies.

*Included:* per-pixel first and second moments; variance estimation; disocclusion detection using depth + normal + (optional) object ID; adaptive temporal α driven by variance and motion; variance clipping of history; a 3-pass à-trous edge-avoiding wavelet filter with variance-scaled step size; firefly clamping that respects energy.

*Excluded:* probe-cache integration (Stage 8); PT-specific metadata (Stage 9 extends, does not replace).

*Why here:* Stage 6 deliberately makes the signal noisier. Reconstruction is the enabling technology for both RTGI and PT modes, and it retires the single largest source of recurring regressions (four retunes in `RTGI_AUDIT.md` Steps 9/10/14/15).

**B. Starting state**

Stage 6 complete. `rtgi_temporal.csh` (α 0.08→0.70 from motion, depth tolerance `max(dist·0.20, 0.50)` ×2 smooth step), `rtgi_filter.csh` (25 taps, `step_size=2`, plane-depth + normal weights, no colour weight).

**C. Implementation**

1. **Buffers.** Replace `rtgi_sky_accum/history` (4 images) with:
   - `rtgi_moments` `rg16f` at half res — `(mean, mean²)`;
   - `rtgi_history` `rgba16f` — `(rgb, depth)`; keep ping-pong;
   - `rtgi_aux` `rgba16f` — `(variance, path_length_or_sky_weight, sample_age, unused)`.
   Net buffer count goes **down** while carrying more information.

2. **Temporal pass** (`rtgi_temporal.csh`):
   ```
   // 1. Reproject (unchanged plumbing: reproject_scene_space + taau_framebuffer_uv)
   // 2. Disocclusion test — three independent tests, all must pass:
   //    depth  : |z_cur - z_prev| < max(z_cur * 0.06, 0.10)   [tighter than today's 0.20]
   //    normal : dot(n_cur, n_prev) > 0.9                    [NEW — needs a normal history channel]
   //    clamp  : previous rgb must lie within the 3x3 neighbourhood AABB
   //             of the current frame's raw samples              [NEW — variance clipping]
   // 3. Adaptive alpha from the reciprocal sample count, clamped by motion:
   //    alpha_max = 1 / (1 + n_prev)          // n_prev in [1, 64]
   //    alpha     = max(alpha_max, motion_alpha) where motion_alpha = clamp(0.05, 1.0, |motion| / motion_scale)
   // 4. Moment accumulation with the same alpha, then variance:
   //    var = max(0, mean2 - mean*mean)
   // 5. Reject and reset on disocclusion (n_prev = 1)
   ```
   Store `n_prev` in `rtgi_aux.a`. Because `rgba16f` is enough for `n ≤ 64`, this is free.
   `motion_scale` is expressed in **radians of camera rotation plus blocks per second of translation per pixel** — derive from `taa_offset`/previous matrices rather than tuning a magic `0.08`.

3. **Normal history.** Add `n_prev` as two 16-bit channels in `rtgi_aux.bg` (octahedral), or append to history (would need `rgba32f`). Prefer a 3rd small `rg16f` image `rtgi_normal_history` if the buffer budget allows — it does (we removed two).

4. **À-trous filter** (`rtgi_atrous.csh`, new, replacing `rtgi_filter.csh`), run 3 times:
   ```
   for (pass in 0..2) {
       step = 1 << pass;                       // 1, 2, 4
       sigma_z   = max(z_center * 0.05, 0.10) * step;
       sigma_n   = mix(128.0, 8.0, variance_normalised);   // variance-guided normal width
       w = h(step) * exp(-|Δz_plane| / sigma_z) * pow(max(0,dot(n,n0)), sigma_n)
                   * exp(-|Δluma| / (sigma_l * sqrt(var0) + eps));
       // 5x5 taps, variance-weighted, with edge-stop widening from pass 0 to 2
   }
   ```
   Crucially: **step size no longer depends on `RTGI_RESOLUTION`** — it depends on measured variance, which is what makes it correct at quarter, half and full res simultaneously. This directly fixes the Step 14/15 "mosaic grid" and "too narrow at half res" oscillation.

5. **Firefly control.** Replace `max_radiance_lum = 16.0` with a variance-aware clamp applied **before** moment accumulation:
   ```glsl
   float clamp_lum = max(1.0, mean_lum + 4.0 * sqrt(var_lum));
   radiance = min(radiance, radiance * clamp_lum / max(lum, eps));
   ```
   Keep the hard cap as a final safety (`RTGI_MAX_RADIANCE`, default 64) so a shading bug cannot poison history.

6. **Sky handling.** The soft `sqr(surface_skylight)` sky term in `hybrid_rtgi.glsl` should be folded into the estimator's MIS (Stage 6) rather than into the filter. Remove the filter's implicit smoothing of sky/non-sky boundaries by keeping the sky fraction in `rtgi_signal.a` and filtering it with the same weights (as today) — this part of the current design is already right.

**D. Runnable deliverable**

Pack with SVGF reconstruction. `GI_DEBUG_VARIANCE` shows interpretable variance; `GI_DEBUG_REJECT` shows a clean, thin disocclusion band instead of broad patches.

**E. Acceptance criteria**

- **Static convergence:** sealed white room, torch, static camera. Temporal standard deviation of the indirect channel over 120 frames must fall below **2 % of its mean** within **32 frames**.
- **Camera pan:** 90°/s pan in a torch-lit corridor, 1080p. No trail may persist more than **2 frames** (measured by differencing consecutive indirect-only captures after motion compensation; visual acceptance: no visible comet tails).
- **Disocclusion:** rotating from a dark wall to a lit room. No flash of raw noise: max frame-to-frame luminance jump **< 15 %** of local mean.
- **No stippling:** the sea-lantern ceiling test (Step 15's screenshot) must show a smooth gradient with no regular grid; verify by FFT of a flat-lit ceiling region showing no peak at the filter period.
- **Resolution invariance:** at `RTGI_RESOLUTION` 0, 1, 2 the same scene must produce the same mean indirect value within 3 % and the same variance ranking. This is the direct test of variance-driven step size.
- **Fireflies:** 1,000-frame run with 2 rays/pixel must contain no frame where a single pixel's indirect luminance exceeds 20× the 99.9th percentile of the frame.
- Static matrices green; `rtgi_filter.csh` removed from `check.py` stub lists.

**F. Regression and recovery**

Breakable: tighter depth tolerance (0.20 → 0.06) may reject history too aggressively on grazing surfaces, reintroducing noise; variance clipping may over-darken bright indirect. Both are measurable with the tests above.

Detection: the six tests are all numeric; keep them as a scripted capture + Python analysis pair in `tools/shadercheck/quality_metrics.py` so they can be re-run after any tuning.

Recovery: `RTGI_RECONSTRUCTION = LEGACY | SVGF` for one transition stage; then delete legacy.

**G. Risks and alternatives**

- À-trous is 3 passes × 25 taps at half res — a real cost. Mitigation: gate to 2 passes at the low tier; the variance guidance makes 2 passes acceptable.
- Alternative reconstruction: bilateral + temporal only (today, but with variance) — cheaper, worse. Keep as the low tier.
- The normal-history channel is the main new complexity. If it proves noisy, fall back to depth-only disocclusion plus the neighbourhood clamp (still a large improvement over today).

**H. Effort and dependencies**

High complexity, ~1.5 weeks. Depends on 3 (buffer restructure) and 6 (signal definition). Blocks 8's quality and all of 9.

---

### Stage 8 — Multi-bounce via DDGI probe radiance cache

**A. Purpose and scope**

*Primary objective:* real multi-bounce transport with coloured bleeding and emissive sources, view-independent and bounded in cost — the core unmet requirement of the original brief.

*Included:* two probe levels (near spacing 4 blocks, far spacing 16); octahedral irradiance (8×8 + border) and depth moments (16×16 + border); round-robin probe updates via `trace_any_hit` + cosine sampling of the clipmap; per-pixel trilinear probe lookup with Chebyshev visibility weighting; per-probe hysteresis; probe relocation and whole-probe scrolling; the sky/emissive split now derived from probes rather than a second image pair.

*Excluded:* PT mode (Stage 9). Debug view `GI_DEBUG_PROBE` is included.

*Why here:* multi-bounce needs (i) a scene representation that can be traversed cheaply (Stage 4/5), (ii) a validated single bounce to seed and to compare against (Stage 6), and (iii) reconstruction good enough to hide probe update noise (Stage 7). All three now exist.

**B. Starting state**

Stage 7 complete. Single bounce, validated. `RTGI_POINT_LIGHT_STRENGTH` is 0.00 with emissive GI effectively absent. `RTGI_INTERIOR_RETENTION` still exists to gate sky leaks.

**C. Implementation**

1. **Probe grid definition.**
   ```glsl
   // near: 16^3 probes at 4-block spacing, covering 64 blocks
   // far : 16^3 probes at 16-block spacing, covering 256 blocks
   const int   probe_dim        = 16;
   const float probe_spacing_n  = 4.0;
   const float probe_spacing_f  = 16.0;
   vec3 probe_origin(float spacing) {
       // world-block aligned, snapped in whole-probe steps so probes never
       // slide relative to geometry (prevents GI swimming)
       vec3 cam = floor(cameraPosition);
       float extent = spacing * float(probe_dim - 1);
       return floor(cam / extent) * extent;
   }
   ```
   Whole-probe snapping means the grid jumps by 4 blocks (near) at a time; hysteresis + relocation below hides the jump.

2. **Storage.** Two `RGBA16F` 2D atlases per level, sized `(8+2)·16 × (8+2)·16 = 160×160` (irradiance) and `(16+2)·16 × (16+2)·16 = 288×288` (moments). Memory: near+far irradiance = 2 × 160·160·8 B = 410 KiB; moments = 2 × 288·288·8 B = 1.33 MiB. **~1.7 MiB total** — an order of magnitude less than this plan's earlier estimate, because atlas layout with a 1-texel border is compact.
   Use a 3D image instead if atlas addressing complicates the à-trous; 3D `rgba16f` at 10×10×16 per level = 1.28 MB — comparable. **Recommend 3D** for simpler addressing; verify `GL_MAX_3D_TEXTURE_SIZE` (≥ 256 required, GL 4.3 minimum is 256, so 16 depth is fine).

3. **Probe update pass** (`rtgi_probe_update.csh`, dispatched at `deferred1_a`, before the trace):
   ```
   uint probe_index = (frameCounter * probes_per_frame + gl_GlobalInvocationID.x) % total_probes;
   decode probe -> (level, x, y, z) -> world position P
   vec3 E = 0; mat3 M = 0;
   for (r = 0; r < RTGI_PROBE_RAYS; ++r) {              // 32..64
       vec3 d = cosine_hemisphere(probe_normal_at(P), r2(r, hash(probe_index, frameCounter)));
       RayHit h = trace_ray(P, d, probe_max_dist, hash, level);
       vec3 L = h.hit ? (h.emission + h.albedo/π * direct_at(h) + probe_irl(h.position, h.normal) * ρ_h)
                      : sky_radiance(d);
       // ^ the last term is the multi-bounce: incoming radiance from the cache at the hit
       E += L;  M += outer(d, d) * L;
   }
   write irradiance E/N and moments
   ```
   `probe_irl(...)` (irradiance from the cache at a hit point) is the recursion that produces bounces 2..N. Because the cache is only a few frames old, this is a **fixed-point iteration** with a per-frame relaxation factor; document it as such, with `RTGI_PROBE_HYSTERESIS` (default 0.85) as the relaxation control.
   **Blocking requirement:** the probe update must not sample the probe it is writing (self-feedback). Skip the current probe's own texel in `probe_irl`.

4. **Per-pixel lookup.** In the RTGI composition, replace the single-bounce result's *far-field* component with the cache:
   ```glsl
   vec3 cache_irradiance(vec3 P, vec3 n) {
       // find the 8 surrounding probes at the appropriate level (near inside 32 blocks, blend to far)
       // trilinear weights; per-probe weight *= backface weight * chebyshev(P, probe_moments)
       // Chebyshev from the octahedral depth moments biased toward the direction of P
   }
   ```
   Blend near→far across a 8-block band so the level switch is invisible.
   Composition: `indirect = single_bounce_near_field + cache_irradiance * ρ/π`, with the near/far split by ray distance. Use MIS-style weights rather than adding both.

5. **Sky/emissive split.** Probes store total irradiance. Derive the sky fraction by running a *second*, cheap probe channel: store `sky_irradiance` in the unused channel(s) of the moments image (e.g. accumulate `L * sky_indicator` alongside `L`). Then `sky_weight = sky_irradiance / max(total_irradiance, eps)`. This replaces `rtgi_sky_accum_img`/`rtgi_sky_history_img` and lets `RTGI_INTERIOR_RETENTION` be **removed** — the leak it was compensating for is solved by visibility-weighted probes. Retirement criterion: sealed caves must show zero sky-origin irradiance with retention at 1.00 in Stage 8's test.

6. **Probe relocation.** If a probe is inside a solid voxel, move its sampling point along the surface normal of the nearest open voxel (standard DDGI practice) and store the offset. Without this, indoor probes inside walls produce black or leaking irradiance.

7. **Cost control.** `RTGI_PROBE_RAYS` (16/32/64) and `RTGI_PROBES_PER_FRAME` (64/128/256) are the two knobs. At 64 probes × 32 rays = 2 K casts/frame — negligible. Convergence time = `total_probes / probes_per_frame` frames = 8192/128 = 64 frames.

**D. Runnable deliverable**

Pack with multi-bounce GI. `GI_DEBUG_PROBE` shows the probe irradiance volume; coloured bleeding is visible; sealed caves are dark without damping hacks; the menu has 4 RTGI options instead of 14.

**E. Acceptance criteria**

- **Multi-bounce test (the brief's headline requirement):** a corridor with a **red** wall lit by sun and a **white** floor. After the first bounce the floor is red. After ≥ 2 bounces the *opposite* white wall must also show measurable red (chromaticity shift ≥ 2× the noise floor) — this cannot happen with a single bounce. **This is the gate test for the whole project.**
- **Sealed cave:** zero sky-origin irradiance; `RTGI_INTERIOR_RETENTION` can be removed with no change beyond noise. The interior must be lit only by emitters present, and pitch black when none are.
- **Emissive illumination:** a single torch in an otherwise dark 9×9×5 room lights the entire room (walls, ceiling, far corner) with a monotonic falloff and no view dependence. This replaces `RTGI_POINT_LIGHT_STRENGTH`.
- **Coloured emitter blend:** red + blue lamps produce purple light on the surface between them (additive), testable by chromaticity.
- **Probe stability:** walking 20 blocks in a straight line produces no visible GI "pumping"; measure by the standard deviation of a fixed wall's indirect value while walking, target < 8 %.
- **No leaks:** the sand-wall test stays at zero on the shadowed side.
- **Performance:** total GI cost (probe update + trace + temporal + à-trous) not more than **1.5×** Stage 7's cost at the same settings.
- Static matrices green with the new image/option set.

**F. Regression and recovery**

Breakable: probe feedback can diverge (brightness growing frame over frame) — this is a fixed-point iteration and needs a stability proof in code comments plus a runtime clamp (`hysteresis`, plus an absolute per-probe clamp). Also: probe relocation can produce disconnected light patches.

Detection: a 600-frame static-camera run must not drift: mean indirect luminance at frame 600 within 2 % of frame 60. This is the divergence test and must be in CI-adjacent tooling (`quality_metrics.py`).

Recovery: `RTGI_MULTIBOUNCE = OFF | PROBES` keeps Stage 7's single-bounce behaviour; `RTGI_PROBES_PER_FRAME = 0` freezes the cache.

**G. Risks and alternatives**

- Highest-risk stage. The most likely failure is **leaks** through 1-block-thin geometry (windows, doors) that moments cannot resolve. Mitigation: probe relocation + a "thin geometry" flag in the voxel payload so probes adjacent to thin surfaces use tighter Chebyshev bias. If still bad, fall back to 2-block probe spacing near the player only.
- Alternative to DDGI if it fails: **hierarchical radiance transfer** — store one bounce of irradiance per voxel in the light field image and iterate the *voxel field* itself across frames (a poor man's radiosity). Cheaper, blurrier, but leak-free because it is anchored to voxels rather than probes. Keep this as the documented fallback plan.

**H. Effort and dependencies**

High complexity, ~2–3 weeks. Depends on 4, 5, 6, 7. Blocks 9 (PT uses the cache as its bounce-1+ source) and 10.

---

### Stage 9 — Path-tracing mode

**A. Purpose and scope**

*Primary objective:* a defensible path tracer over the clipmap scene with 1–8 bounces, physical sampling, and progressive convergence — distinct in kind from RTGI mode.

*Included:* `RTGI_MODE = PATH_TRACED`; primary hit from the G-buffer; stochastic continuation with cosine (diffuse) and GGX-VNDF (specular) sampling; emissive/sun MIS via next-event estimation against the `emissive_list` SSBO; Russian roulette from bounce 2; reservoir resampling of the light list at the first diffuse hit (high tier only); progressive accumulation when the camera and scene are static; PT metadata into the shared SVGF chain.

*Excluded:* refraction/TIR transport, participating media, entities, sub-block shapes beyond the Stage 5 shape set, spectral rendering.

*Why here:* last, because it consumes every earlier interface, and because it is the mode with the highest cost and the smallest user base. It must not delay the multi-bounce RTGI mode that benefits everyone.

**B. Starting state**

Stage 8 complete. Clipmap, `trace_ray`/`trace_any_hit`, probe cache, SVGF chain, validated single-bounce reference.

**C. Implementation**

1. **Mode switching.** `RTGI_MODE` ∈ `{OFF, HYBRID, PATH_TRACED}` in `settings.glsl`, wired into `screen.raytracing`, all five profiles (`extreme`/`ultra` → `PATH_TRACED`), `en_US.lang`, and `properties_lint.py`. `OFF` must reproduce the Stage 1 analytic path exactly — add a matrix variant asserting it.

2. **Primary hit.** Reuse `deferred4`'s G-buffer data (position from depth, normal from `colortex1` + normal map, albedo/roughness/f0 from `colortex2`). Do not re-trace the primary ray — that would waste the rasteriser.

3. **Path loop** (`include/lighting/rt/path_trace.glsl`, new):
   ```
   vec3 trace_path(vec3 P, vec3 wo, Material m, inout uint seed) {
       vec3 L = 0, beta = 1;
       for (int b = 0; b < RTGI_PT_BOUNCES; ++b) {
           // --- sample a direction
           vec3 wi = (rand(seed) < spec_prob) ? sample_ggx_vndf(m, wo, rand2(seed))
                                              : cosine_hemisphere(m.n, rand2(seed));
           // --- next event estimation (MIS, balance heuristic)
           LightSample ls = sample_emissive_list(P, m.n, rand(seed));   // reservoir-resampled on high tier
           if (ls.valid) L += beta * m.eval(wo, ls.wi, m.n) * ls.Li * mis_weight_light(...);
           // --- continue
           RayHit h = trace_ray(P, wi, RTGI_PT_MAX_DIST, hash(seed), level_of(P));
           if (!h.hit) {
               L += beta * sky_radiance(wi) * mis_weight_bsdf(...);
               break;
           }
           // --- hit emitter or surface
           L += beta * h.emission * mis_weight_bsdf(...);
           beta *= m.albedo / π * abs(dot(wi, h.normal)) ... // throughput
           // --- Russian roulette from bounce 2
           if (b >= 1) { float q = clamp(max3(beta), 0.05, 0.95); if (rand(seed) > q) break; beta /= q; }
           P = h.position + h.normal * bias; wo = -wi; m = material_at(h);
       }
       return L;
   }
   ```
   Note `mis_weight_*` must use the same PDFs on both sides; implement `pdf_light` and `pdf_bsdf` as shared functions so the weights cannot drift.

4. **Emissive list.** Build an SSBO of emitters during voxelization: at most `RTGI_EMISSIVE_MAX` (default 64) entries of `(position, colour, normal)` for the near volume. Written via `imageAtomicAdd` on a counter in a `r32ui` image, or via `bufferObject.0`. Iris supports SSBOs with `index ≤ 12` [VERIFIED] — use index 0, and declare `iris.features.required = … SSBO`. **Fallback:** if SSBO support proves fragile on some drivers, pack the list into a `64×1` `RGBA32F` image, which is simpler and sufficient for 64 emitters.

5. **Progressive accumulation.** When `abs(cameraDelta) + abs(sceneDelta) < eps` for `N` frames, increase the accumulation count instead of blending: `alpha = 1/(n+1)` up to `RTGI_PT_MAX_SAMPLES` (default 256), then hold. Reset on any camera/scene change. Use the existing TAA/`frameCounter` machinery rather than a new detector; `gbufferPreviousModelView` + `previousCameraPosition` give the camera delta, and the voxelization generation counter gives a scene-delta proxy (increment it when any `imageAtomicMax` write occurs — or cheaper, treat `worldTime`-driven block changes as scene changes and accept that a redstone-only change is missed).
   This is what makes "progressively improved sampling quality where technically feasible" true rather than aspirational.

6. **PT metadata into the denoiser.** Store per-pixel `path_length` (bounces taken) and `rr_survival` in `rtgi_aux`. Use them to scale the à-trous edge-stop width: shorter paths = noisier = wider filter; and to skip filtering entirely on converged pixels.

7. **PT-specific cost knobs.** `RTGI_PT_BOUNCES` (1/2/4/8), `RTGI_PT_SPP` (1/2/4), `RTGI_PT_MAX_SAMPLES`, `RTGI_PT_RESERVOIR` (on/off). Map them into the quality tiers in Stage 10.

8. **Honesty in the UI and docs.** Menu label and `en_US.lang` must say what it is. Suggested: *"Path tracing (voxelised world, no entities)"*. `docs/known_limitations.md` must list: block-granular geometry, no entities/particles, no refraction, no caustics, no media, one-block-lightmap-independent emission, and no sub-block shapes beyond the shape set.

**D. Runnable deliverable**

Pack with three selectable modes. `PATH_TRACED` at extreme profile: 4 bounces, 1 spp at 1080p, progressive to 256 samples when static.

**E. Acceptance criteria**

- **Convergence to reference:** in the static white furnace, PT at 256 accumulated samples must match the Stage 6 one-bounce analytic reference within 5 %, and with 4 bounces must exceed it in the expected direction (additional inter-reflection energy = `E_1·ρ/(1-ρ)` for the first correction term).
- **Energy monotonicity:** measured interior illuminance must be monotonically non-decreasing in bounce count 1→2→4, and must converge (|E_4 − E_8| < 5 %).
- **Unbiasedness spot check:** the multi-bounce corridor test at 1,024 samples must agree with an independent CPU reference (a small Python path tracer over the same voxel volume, added to `tools/shadercheck/`) within 5 % on three sampled surfaces. This is the only real proof the estimator is correct, and it is cheap to build because the volume is small.
- **No fireflies:** 10,000-sample PT render contains no pixel above 30× the frame's 99.9th percentile after denoising.
- **Progressive convergence:** the difference between frame 64 and frame 256 accumulated renders must be < 3 % mean.
- **Cost transparency:** PT at 4 bounces / 1 spp must be at most 2.5× HYBRID mode's frame time at the same resolution.
- Static matrices green for all `RTGI_MODE` values plus `RTGI_PT_BOUNCES` 1/2/4/8.

**F. Regression and recovery**

Breakable: the path loop is the most likely place for NaN/Inf (division by a zero PDF, `beta` overflow). Guard every PDF with `max(eps, …)`; add a NaN check in debug builds that writes magenta so a failure is obvious rather than silently black.

Detection: the CPU reference comparison plus a magenta-on-NaN debug path.

Recovery: `RTGI_MODE = HYBRID` is always available and shares the scene core, so switching modes never requires a different pack.

**G. Risks and alternatives**

- Most likely problem: 1 spp PT at native resolution is very noisy and the SVGF chain was tuned for the RTGI signal. Mitigation: run PT at half res with temporal upscaling (Stage 10), or restrict PT to 2 spp and 2 bounces by default.
- ReSTIR reservoir resampling is optional. If the unbiasing weight proves unstable, ship NEE over ≤64 emitters (deterministic, unbiased, more expensive) and drop the reservoir.
- If progressive accumulation is judged out of scope, PT degrades to "1-spp path tracing with denoising" — still honest, but the brief explicitly asks for progressive improvement where feasible, so it should be included.

**H. Effort and dependencies**

Very high complexity, ~3–4 weeks. Depends on 5, 7, 8. Blocks only Stage 10's tier table.

---

### Stage 10 — Production hardening, tiers, compatibility

**A. Purpose and scope**

*Primary objective:* make the new renderer shippable: performance validated against the Stage 0 baseline, quality tiers that map cleanly onto GPU classes, compatibility preserved (DH, Voxy, Photonics, resource packs, all dimensions), documentation complete, and the legacy path retired only with evidence.

*Included:* four quality tiers; performance profile per pass; the full compatibility matrix; translation updates; `RTGI_RESOLUTION` → `RTGI_SCALE` rename with profile migration; `docs/known_limitations.md`; the evidence-based decision on retiring the analytic fallback.

*Excluded:* new rendering features.

*Why here:* last by definition, but its requirements (perf as a design constraint) are enforced from Stage 0 by the baseline table.

**B. Starting state**

Stages 0–9 complete.

**C. Implementation**

1. **Quality tiers** (replace the five existing profiles' RTGI strings):

   | Tier | Mode | Scale | Rays/px | Bounces | Probes/frame × rays | Recon | Expected target |
   |---|---|---|---|---|---|---|---|
   | Low | HYBRID | 0.25 | 1 | cache off | 64 × 16 | 2-pass à-trous | iGPU, ≥ 45 fps @1080p |
   | Medium | HYBRID | 0.5 | 2 | probes | 128 × 32 | 3-pass | mid dGPU, ≥ 60 |
   | High | HYBRID | 0.5 | 4 | probes | 256 × 48 | 3-pass | high dGPU, ≥ 60 |
   | Ultra | HYBRID/PT | 1.0 | 4 | probes | 256 × 64 | 3-pass | high dGPU, 45–60 |
   | Extreme | PATH_TRACED | 1.0 | 1 spp | 4 | 256 × 64 | 3-pass + progressive | enthusiast, 30–60 |

2. **Per-pass profiling procedure.** Document how to read Iris's profiler and produce a table of: voxelization, probe update, trace, temporal, à-trous, deferred4, post. Provide `docs/testing/perf_procedure.md` with the exact scene, resolution, and 5-run median methodology. Explain which knobs reduce *work* (scale, rays, probes, bounces) vs which trade quality for artifacts (recon passes, hysteresis, probe spacing).

3. **Compatibility matrix** (each cell: loads / correct / documented limitation):

   | Config | Expectation |
   |---|---|
   | Overworld / Nether / End | No compile errors; Nether GI from block light only |
   | `SHADOW` off | RTGI still works (voxelization decoupled in Stage 4) |
   | `SHADOW` off + `RT_REFLECTIONS` on | No undeclared `shadowtex0` (Stage 0 fix retained) |
   | TAAU 0.50 / 0.75 | All new passes use `taau_*` helpers |
   | Distant Horizons | GI fades at L3 edge; documented, not silently wrong |
   | Voxy | Same |
   | Photonics | Loads; `write_indirect()` receives GI |
   | labPBR resource packs | Emission and roughness flow into voxels; verify a pack with strong emissives |
   | Colored lighting disabled vanilla-style | `RTGI_VANILLA_LIGHTMAP_PROPAGATION` semantics documented or option removed |
   | Iris Vulkan path | Not verified; document as unsupported if untested |

4. **Rename and cleanup.** `RTGI_RESOLUTION` → `RTGI_SCALE` (0.25/0.5/1.0) with a one-time profile migration; remove `RTGI_VANILLA_LIGHTMAP_PROPAGATION` if Stage 8 made it obsolete; consolidate the option count (14 → ~8); update all `lang/*.lang` files (or explicitly document that only `en_US` is maintained).

5. **Retirement decision for the analytic fallback.** Evidence required before retiring `get_sky_lighting` on deferred surfaces: (a) Stage 6 furnace test within tolerance; (b) Stage 8 cave/leak tests pass; (c) a 3-GPU-vendor report showing no visual regression; (d) `RTGI_MODE = OFF` still provides a complete, correct image (so the fallback remains *reachable*, just not the default). **Recommendation: keep `RTGI_MODE = OFF` permanently** — it costs one compile-time branch and is the project's safety net, exactly as the brief's §10 requires.

6. **Documentation set:**
   - `docs/architecture.md` — the data flow from §4.2, kept current.
   - `docs/known_limitations.md` — the honest list.
   - `docs/testing/*` — protocol, perf, reference scenes, debug views.
   - `docs/option_reference.md` — every RTGI option, its cost, and its artifact.
   - Update `README.md`.

**D. Runnable deliverable**

Release-candidate pack: 5 tiers, complete docs, all compatibility cells recorded.

**E. Acceptance criteria**

- Every matrix cell in 10.3 is explicitly pass / documented limitation — no "unknown".
- Perf: High tier ≥ 60 fps at 1080p on the reference GPU class; Low tier ≥ 45 fps on an iGPU. [ASSUMPTION — requires hardware; the *procedure* is what this plan can guarantee]
- Every option in the menu has a documented effect and a measured cost; `properties_lint.py` reports 0 orphan options and 0 undocumented options.
- All five tiers load in all three dimensions.
- The full test matrix in §8 passes at High and Low tiers at minimum.

**F. Regression and recovery**

The whole point of Stage 10 is regression safety; the recovery mechanism is the retained `RTGI_MODE = OFF` plus the per-tier option sets, which let a user drop to the last known-good configuration without changing packs.

**G. Risks and alternatives**

- Tier calibration on unknown hardware is the main risk; mitigate by publishing the procedure and the option-cost table rather than claiming universal frame rates.
- Iris Vulkan: if it becomes the default backend, compute/image behaviour needs re-verification. Track as a standing risk (R9).

**H. Effort and dependencies**

Medium complexity but long duration, ~2 weeks. Depends on everything.

---

## 8. Test and benchmark plan

### 8.1 Principles

- Every assertion is **numeric or binary**, not "looks better". Where a number is impossible, define the observation precisely enough that two people would agree.
- One canonical scene per failure class, with exact commands, so a tester reproduces it in under two minutes.
- Debug views are the primary instrument; shaded screenshots are the confirmation.
- Metric extraction lives in `tools/shadercheck/quality_metrics.py`: load two PNGs (or a capture set) plus a region rectangle, and report mean/σ/chromaticity/AABB-clamped difference. Captures must be produced with TAA settled and HUD off.

### 8.2 Canonical scene set

All scenes specify: seed, coordinates, `/time set`, `/weather clear`, render distance 12, fixed resolution 1920×1080, `TAAU` off unless stated, `RTGI_RESOLUTION`/`RTGI_SCALE` at the tier under test.

| # | Scene | Build instructions | Observes | Likely failure modes | Pass/fail criterion |
|---|---|---|---|---|---|
| **T1** | White furnace room | 11×11×5 interior of `white_concrete`, sealed, one `sea_lantern` at centre ceiling; `/time set midnight` | Absolute indirect energy of one bounce | Double counting; wrong `1/π`; over/under-bright | Mean interior illuminance within ±10 % of `E₁ = (A_e/A_total)·π·L_e`; chromaticity neutral (Δu′v′ < 0.005) |
| **T2** | Coloured cabinet | 7×7×5, red wool one wall, white floor, sun through a 2×2 opening; noon, clear | One-bounce coloured bleeding | Colour desaturation; leaking white light | Floor chromaticity matches `albedo_red`-tinted sun within Δu′v′ < 0.01 |
| **T3** | Multi-bounce corridor | 3×3×24 corridor; red wall on one side; white floor/walls; daylight from one end | **Bounce count > 1** | Only one bounce present (the central failure of the current build) | Opposite white wall shows red shift ≥ 2× noise floor at 256 accumulated samples |
| **T4** | Sealed cave | Natural cave, or a 15³ sealed stone chamber with one torch; no sky access | Sky leaks; emitter reach | Outdoor light leaking in; pitch-black with a light present | Zero sky-origin irradiance (`GI_DEBUG_FILTERED` sky channel = 0); room lit monotonically by the torch |
| **T5** | Emissive object | 9×9×5 dark room, one `glowstone` block floating 3 blocks off the floor | Emissive illumination as a source, not only as a hit | Light only on surfaces directly visible | Ceiling, all four walls and the floor all receive light; falloff monotonic with distance |
| **T6** | Red/blue emitter blend | Two lamps 4 blocks apart, white surfaces between | Additive coloured transport | One colour wins (the current `imageAtomicMax` defect); no purple | Surface between lamps shows a red→purple→blue gradient; mid-point chromaticity between the two emitters |
| **T7** | Staircase / fence / pane | Stairs against a wall, fence row, glass panes; torch 2 blocks away | Sub-block shape fidelity | Cube-shaped GI silhouettes; missing contact darkening | Wall behind stairs shows a staircase-shaped gradient (`GI_DEBUG_FILTERED`), not steps of full blocks |
| **T8** | Thin wall / seam leak | 1-block-thick sand wall, sun behind; camera in the shadowed half | Seam traversal, thin-geometry leaks | Light bleeding through the wall (Step 12's reported bug) | Shadowed side indirect exactly 0 in the debug view |
| **T9** | Camera rotation (view independence) | T4's cave, torch fixed; `/tp` to 4 yaws (0/90/180/270), settle 60 frames each | Feedback loop (B1) | Light appearing only when the source is behind the camera | Max pairwise difference of indirect channel < 5 % (Stage 3), < 2 % (Stage 6) |
| **T10** | Fast pan / disocclusion | Torch-lit corridor; 90°/s pan; then a 180° snap | Ghosting, trails, noise flashes | Comet tails; full-frame noise flash on disocclusion | No trail beyond 2 frames; max frame-to-frame luminance jump < 15 % |
| **T11** | Static convergence | T1, static camera, 120 frames | Temporal stability, drift, divergence | Slow brightness drift (probe feedback); never converging | σ of indirect < 2 % of mean after 32 frames; frame 600 mean within 2 % of frame 60 |
| **T12** | Sun motion | T2 at `/time set` 06:00 / 12:00 / 18:00, and a `time add` sweep | Lighting changes without ghosting | Stale history after a sun jump; over-darkening | No history artifact beyond 5 frames after a jump; energy consistent with the new sun angle |
| **T13** | Weather | T2 with `/weather rain 200` then `clear` | Cloud/rain modulation of GI | GI not responding to cloud shadow | Indirect drops measurably (>5 %) in rain, recovers within 10 frames after clear |
| **T14** | Water and transparency | Pool with normal-mapped water; stained glass window; held item behind glass | Translucency interaction | GI computed for the surface behind; glass tint errors | Water refraction intact (P0-2 stays fixed); glass tint applies once; no GI smear across the water edge |
| **T15** | Foliage | Forest canopy, noon | Absorption handling, canopy darkness | Canopy glowing; hard shadows | Under-canopy is darker than open sky by a plausible ratio; no emissive-looking leaves |
| **T16** | Distant terrain | Vistas at 512 blocks with DH and with Voxy; `VOXEL_VOLUME_SIZE`/clipmap at L3 | Representation coverage (B3) | GI absent or wrong beyond 128 blocks; visible boundary | No visible GI boundary line at the L3 edge; the transition is a smooth fade |
| **T17** | Low light / night | T2 at midnight, moonlight only | Noise in low-signal conditions | Fireflies; black crush | No pixel above 30× the 99.9th percentile; shadow detail retained |
| **T18** | Resource pack materials | A labPBR pack with strong emission and varied roughness | Material plumbing into voxels | Emission ignored; everything same albedo | `GI_DEBUG_VOXEL_ALBEDO` shows pack colours; emissive blocks light the room |
| **T19** | All three dimensions | Any scene per dimension, including Nether `RAYTRACED_GI` on | Compilation and Nether-specific paths | Nether compile failure; Nether GI nonsense | No compile errors; Nether lit only by block light and lava |
| **T20** | TAAU | T2 at `TAAU_RENDER_SCALE` 0.5 and 0.75 | Coordinate handling in new passes | GI offset by half a viewport; misaligned | GI edges align with geometry edges within 1 px; no shimmer |

### 8.3 Debug-view checklist per stage

| Stage | Views that must be inspected before acceptance |
|---|---|
| 2 | all |
| 3 | `FILTERED`, `REJECT` |
| 4 | `VOXEL_ID`, `VOXEL_LIGHT`, `VOXEL_ALBEDO` |
| 5 | `HIT`, `VOXEL_ID` |
| 6 | `RAW`, `FILTERED`, `HIT` |
| 7 | `VARIANCE`, `REJECT`, `HISTORY` |
| 8 | `PROBE`, `FILTERED` |
| 9 | `RAW`, `VARIANCE`, plus a bounce-count visualisation |

### 8.4 Automated checks (`run_checks.sh`)

| Check | Type | Runs on |
|---|---|---|
| `voxel_packing_test.py` | bit-layout round trip + atomic priority | every push |
| `dda_test.py` (new, Stage 5) | traversal correctness vs a synthetic volume | every push |
| `properties_lint.py` | duplicate keys, orphan options, menu/lang coverage | every push |
| `matrix_compute.py` | 308+ compile cases | every push |
| `matrix.py` | 780+ compile cases | every push |
| `pt_reference_test.py` (new, Stage 9) | CPU path tracer vs GPU capture agreement | manual, per release |
| `quality_metrics.py` (new, Stage 7) | numeric scene metrics from captures | manual, per stage gate |

### 8.5 Reproducible baseline commands

```sh
# Build glslang once (Apache-2.0)
./tools/shadercheck/bootstrap_glslang.sh          # Stage 0 addition

# Full static validation (currently 308 + 780 cases, 0 failures)
export GLSLANG=$PWD/glslang/build/StandAlone/glslang
export NO_INJECT=shadowtex0
./tools/shadercheck/run_checks.sh

# Single-case reproductions used during this audit
python3 tools/shadercheck/check.py /world0/deferred1_a.csh comp
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag
python3 tools/shadercheck/check.py /world-1/deferred4.fsh frag
python3 tools/shadercheck/check.py /world0/gbuffers_water.fsh frag
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag '!SHADOW' '!SHADOW_SSRT'
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag TAAU TAAU_RENDER_SCALE=0.50
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_POINT_LIGHT_STRENGTH=0.00
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_POINT_LIGHT_RADIUS=2
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag RTGI_CAVE_AMBIENT_SCALE=0.00
python3 tools/shadercheck/check.py /world0/deferred1_a.csh comp VOXEL_VOLUME_SIZE=512
```

Measured during this audit with `glslang 15.0.0`:

| Run | Result |
|---|---|
| `matrix_compute.py` before `216b896` | **120 of 308** cases failed — `'preprocessor evaluation' : bad expression` at `#if RTGI_POINT_LIGHT_STRENGTH > 0` (the 120 failures are exactly the cases that include the voxel code) |
| `matrix_compute.py` after `216b896` | **308/308 pass** |
| `matrix.py` after `216b896` | **780/780 pass** |
| `voxel_packing_test.py` | 1,000 randomized round trips OK |
| `properties_lint.py` | 305 keys, 3 known upstream duplicates |

### 8.6 Performance evaluation

Per pass, recorded at 1080p, fixed scene, 5 runs, median:

| Pass | Knob that reduces work | Knob that trades quality |
|---|---|---|
| Voxelization | (no direct knob; tied to geometry) | level count |
| Probe update | `RTGI_PROBES_PER_FRAME`, `RTGI_PROBE_RAYS` | `RTGI_PROBE_HYSTERESIS`, probe spacing |
| Trace | `RTGI_SCALE`, `RTGI_RAY_COUNT`/SPP | — |
| Temporal | — | α floor, clamp width |
| À-trous | pass count | edge-stop widths |
| Deferred4 | — | — |
| Post | unchanged | unchanged |

Rules:
- **Work-reducing** knobs must show a monotonic frame-time decrease when lowered; verify by measuring 3 settings each.
- **Quality-trading** knobs must show **no** frame-time change (they trade artifacts, not cost). If one does change timing, it is mislabelled.
- Report the ratio of GI cost to total frame time; the target is ≤ 45 % at High tier.
- Compare every stage against the Stage 0 baseline and against the previous stage; a > 10 % unexplained regression blocks the stage gate.

---

## 9. Risk register

Ranked by severity (S), with likelihood (L) and detectability (D).

### 9.1 Technical

| ID | Risk | S | L | D | Mitigation | Fallback |
|---|---|---|---|---|---|---|
| R1 | **DDGI probe feedback diverges** (energy grows frame over frame) | Critical | Medium | Medium | Hysteresis + per-probe absolute clamp + the T11 drift test as a gate; document it as a fixed-point iteration | Freeze cache after N frames (`PROBES_PER_FRAME=0`); fall back to voxel-anchored radiosity field |
| R2 | **Clipmap level transitions leak or skip** | High | High | High | `dda_test.py` property tests; debug counter for non-advancing `t`; ship L0+L1 before adding L2/L3 | 2-level clipmap (1 and 8 blocks) |
| R3 | **`imageAtomicAdd` unsupported on the chosen format** | High | Medium | High (immediate) | Verify on the target GPU as the *first* task of Stage 4; prefer two `r32ui` packed images | Per-voxel 4-way slot pool with atomic max on a slot index |
| R4 | **Probe leaks through 1-block-thin geometry** | High | Medium | Medium | Thin-geometry flag in the voxel payload; probe relocation; tighter Chebyshev bias | Increase probe spacing near thin surfaces; accept, document |
| R5 | **PT becomes NaN/Inf** | High | Medium | High (magenta) | `max(eps, …)` on every PDF/division; loop-invariant clamps; NaN→magenta debug path | Disable PT mode at the tier level |
| R6 | **Denoiser over-blurs after the feedback loop is removed** | Medium | High | Medium | The T10/T11 numeric gates; variance-guided widths | Keep 2-pass à-trous at all tiers |
| R7 | **Voxelization cost doubles with 4 levels written per vertex** | Medium | Medium | Low | Write only levels that intersect the chunk; measure in Stage 4 | Write L0+L1 per vertex, L2/L3 from a coarse downsampled pass |
| R8 | **Shader compile time / register pressure explodes** | Medium | Medium | Low | Constant loop bounds from fixed 64³ levels; `matrix.py` runtime as a proxy metric | Reduce `RTGI_PROBE_RAYS` compile-time range |
| R9 | **Iris Vulkan backend behaves differently for images/compute** | Medium | Medium | Low | Mark the Vulkan path as untested in the compatibility matrix; verify when available | Document as unsupported |

### 9.2 Performance

| ID | Risk | S | L | Mitigation |
|---|---|---|---|---|
| R10 | High tier misses 60 fps | High | Medium | Tiers are calibrated by measurement (Stage 10), not by hope; publish the procedure, not promises |
| R11 | PT at 1 spp is unusable without upscaling | Medium | High | Half-res PT + temporal upscale; 2 bounces default |
| R12 | À-trous 3-pass cost too high on iGPU | Medium | Medium | 2-pass at Low; variance guidance makes 2 pass acceptable |

### 9.3 Compatibility

| ID | Risk | S | L | Mitigation |
|---|---|---|---|---|
| R13 | Removal of LPV fog is a user-visible regression | Medium | High (it is already removed) | Stage 1 decision: remove the option honestly, or restore fed by the clipmap |
| R14 | Photonics API drift breaks the restored stub | Medium | Medium | Stub is inert; verify compile in the matrix; document the supported version |
| R15 | DH/Voxy cannot be voxelized (no world position in their vertex shaders) | Medium | Medium | Investigate in Stage 4; if impossible, document and fade GI at L3 |
| R16 | Resource-pack emission not reaching voxels | Medium | Low | T18 test; albedo debug view |
| R17 | OptiFine users cannot run the pack | Low | Certain | Already documented in `README.md`; keep it explicit |

### 9.4 Licensing and provenance

| ID | Risk | S | L | Mitigation |
|---|---|---|---|---|
| R18 | **SEUS code copied or transliterated** | Critical (legal) | Low if disciplined | Hard rule: SEUS is a reference only. No copying, no transliteration, no line-by-line adaptation. Recorded in §9.6 |
| R19 | NVIDIA RTXGI-DDGI source reused | High (legal) | Low if disciplined | `NOASSERTION` licence = reference only. Implement DDGI from the JCGT paper |
| R20 | Photon's own licence constrains redistribution of the fork | High | Medium | `LICENSE` allows modification and redistribution **except** on monetised platforms (Modrinth/CurseForge) without written permission, and except demanding money. The fork must keep `LICENSE` intact and must not be published to those platforms without SixthSurge's permission. Flag for the user |
| R21 | BSD/MIT snippets from public implementations mixed in | Low | Medium | Any copied code must carry its notice; prefer paper-based implementation |
| R22 | Euphoria Patches tag usage | Low | Certain | Already attributed in `block.properties` ("Tags from Euphoria Patches by SpacEagle17, used with permission") — keep the notice |

### 9.5 Project

| ID | Risk | S | L | Mitigation |
|---|---|---|---|---|
| R23 | Scope: 10 stages is a multi-month effort for one maintainer | High | High | Each stage is independently shippable; stages 0–3 already deliver the user's top complaints; stop-points are explicit |
| R24 | Regression reintroduction during tuning (as happened 4× in the audit log) | High | High | Numeric gates replace subjective tuning; `quality_metrics.py` makes retunes measurable |
| R25 | No runtime verification available in the development environment | High | Certain here | Stage 0's user-run baseline protocol is mandatory; the plan never assumes a GPU exists in the dev sandbox |
| R26 | Squashed git history undermines bisecting | Medium | Certain | From Stage 0 onward, commit per accepted increment; do not squash again |

### 9.6 Provenance and licence record

| Component | Origin | Licence | Usable how |
|---|---|---|---|
| Photon Shaders | SixthSurge | Custom (see `LICENSE`) | Modified/redistributed with restrictions; keep licence file |
| Iris | IrisShaders | LGPL-3.0 | Read for capability verification; not distributed |
| SEUS PTGI HRR GFME | Sonic Ether | **No licence granting reuse** | **Reference only.** No copying or transliteration |
| `lib/Common.inc` noise snippet inside SEUS | Nikita Miropolskiy (Shadertoy XsX3zB) | MIT | Reusable **with notice**, if ever needed |
| glslang | Khronos | Apache-2.0 | Toolchain only |
| Amanatides & Woo DDA | EG '87 paper | Public algorithm | Implement freely |
| `cgyurgyik/Fast-Voxel-Traversal-Algorithm` | GitHub | MIT | Reusable with notice |
| DDGI (JCGT 2019) | Majercik et al. | Paper | Implement from paper |
| `NVIDIAGameWorks/RTXGI-DDGI` | NVIDIA | **NOASSERTION** (RTX SDK) | **Reference only** |
| `guoxx/DDGI` | GitHub | BSD-3-Clause | Reusable with notice (prefer paper) |
| SVGF (HPG 2017) | Schied et al. | Paper | Implement from paper |
| ReSTIR (2020), ReSTIR GI (2021) | Bitterli/Ouyang et al. | Paper | Implement from paper |
| `DQLin/ReSTIR_PT` | GitHub | BSD-3-Clause | Reusable with notice |
| ACES tonemapping | AMPAS | Already licensed in `include/post_processing/aces/license.md` | Unchanged |
| Euphoria Patches tags | SpacEagle17 | Permission stated in `block.properties` | Keep attribution |
| Blue noise texture | momentsingraphics.de | Stated in `README.md` acknowledgements | Keep attribution |

**Uncertain licences requiring action before any reuse:** RTXGI-DDGI (`NOASSERTION`), SEUS (none), and the fork's own redistribution terms (R20).

---

## 10. Immediate implementation backlog

Ordered by dependency. Each item names the file(s) and, where the plan depends on a verified fact, restates it.

### Tier A — do first (Stage 0, this week)

1. **Commit the P0 fix (done)** — `shaders/include/lighting/rt/voxel_dda.glsl`, `shaders/include/lighting/voxel/voxel_update.glsl`. Commit `216b896`. Verified: 308 + 780 static cases green.
2. **Add `tools/shadercheck/bootstrap_glslang.sh`** — clone `KhronosGroup/glslang` tag `15.0.0`, build `StandAlone`, print the `GLSLANG` export line. Apache-2.0; keep the notice.
3. **Add `.github/workflows/shadercheck.yml`** — run `bootstrap_glslang.sh` then `run_checks.sh` with `NO_INJECT=shadowtex0`.
4. **Add `tools/shadercheck/package.sh`** — produce `build/photon-<sha>.zip` excluding `tools/`, `docs/images/`, `RTGI_AUDIT.md`, `RTGI_IMPLEMENTATION_PLAN.md`.
5. **Write `docs/testing/baseline_protocol.md`** — the T1–T20 scene definitions from §8.2, with `/tp` command blocks and capture rules. This is the document the user executes.
6. **Record the baseline** — user runs T9 (camera independence), T10 (pan), T11 (static), T4 (cave), T8 (seam), and the sea-lantern ceiling. Six captures plus a frame-time table.

### Tier B — Stage 1 (low risk, removes regressions)

7. **Restore AO** — `git checkout 6e67b36 -- shaders/include/lighting/ao/`; re-add `SHADER_AO_SSAO`/`SHADER_AO_GTAO` in `shaders/settings.glsl` (currently only `SHADER_AO_NONE` at lines 160-161); default to GTAO when `!RAYTRACED_GI`; remove `SHADER_AO=SHADER_AO_NONE` from the five profile strings in `shaders/shaders.properties` lines 1-5.
8. **Adapt `shaders/program/d3_ao.fsh`** — keep the 8-tap contact AO for the RTGI path; add a compile-time branch so SSAO/GTAO replace it when `SHADER_AO != SHADER_AO_NONE && !defined RAYTRACED_GI`.
9. **Restore Photonics** — `git checkout 6e67b36 -- shaders/photonics/ shaders/ph_lights.json`; verify compile in the matrix; add the include back to `d4_deferred_shading.fsh` where upstream had it (check `git show 6e67b36:shaders/program/d4_deferred_shading.fsh` for the exact call site).
10. **Resolve `AIR_FOG_COLORED_LIGHT_SHAFTS`** — either implement, or remove the option from `shaders.properties` and `en_US.lang` and document the loss.
11. **Add the orphan-option check** to `tools/shadercheck/properties_lint.py`.

### Tier C — Stage 2 (diagnostics)

12. **`shaders/include/debug/gi_debug.glsl`** — the `GI_DEBUG_*` enum and `debug_encode()`.
13. **Wire `DEBUG_SAMPLER`** — `shaders/settings.glsl` (already in `sliders` at `shaders.properties:119`; no consumer exists today); add early-out blocks in `shaders/program/d4_deferred_shading.fsh` after lighting.
14. **Add `rtgi_debug_img`** — `rgba8`, half res, in `shaders/shaders.properties` next to the other `image.rtgi_*` declarations (lines 419-439), written only when debugging.
15. **Voxel debug views** in `d4_deferred_shading.fsh` via `scene_to_voxel_space()` — ID, light, albedo.
16. **`docs/testing/debug_views.md`** with one screenshot per view.

### Tier D — Stage 3 (the correctness fix)

17. **`colortex18` declaration** — `shaders/include/buffers.glsl` (add format/size/clear alongside `colortex17`), `shaders/shaders.properties` (size + clear + blend), `tools/shadercheck/check.py` (known-image list).
18. **Write direct-only radiance** at the end of `shaders/program/d4_deferred_shading.fsh`, before the indirect terms are added. Locate the boundary precisely in `shaders/include/lighting/diffuse_lighting.glsl`: direct `lighting` is complete at line 290 (`lighting *= light_color;`) plus the `CLOUD_SHADOWS` block at 292-296, and indirect begins at line 299 (`#ifdef DIFFUSE_USE_RTGI`).
19. **Switch SSGI's colour source** — `shaders/include/lighting/rt/ssgi.glsl` line ~131 (`textureLod(scene_color_sampler, prev_screen_pos.xy, 0.0)`, line 125) → sample `colortex18`; update the sampler argument in `hybrid_rtgi.glsl` and `rtgi_trace.csh` (line 31 uniform declaration and line 156 call site).
20. **Remove the double count** — `shaders/include/lighting/diffuse_lighting.glsl` lines 299-342: drop the unconditional `lighting += mc_block` at line 342 and gate it on the voxel edge fade (note `voxel_edge_fade` at lines 337-341 is currently computed and discarded — a verified dead variable).
21. **Replace `1.6 * RTGI_BRIGHTNESS`** — line 306, with a documented `RTGI_INTENSITY`; calibrate in T1.
22. **Re-default the crutches** — `shaders/settings.glsl` lines 71-72: `RTGI_SSGI_LOCAL_LIGHT_SCALE` and `RTGI_CAVE_AMBIENT_SCALE` back to `1.00`, then re-measure.

### Tier E — Stage 4 (the big one; start only when A–D are accepted)

23. Declare 4 clipmap levels + 4 light-field images in `shaders/shaders.properties` (verify the `image.*` argument order against Iris 26.3 `ImageInformation.create`).
24. Implement `clipmap_origin()` / `scene_to_clipmap()` in a new `shaders/include/lighting/voxel/voxel_clipmap.glsl`, using absolute world space rather than the current `fract(cameraPosition)` trick in `voxel_constants.glsl`.
25. Repack the geometry payload with a 3-bit shape class in `voxel_storage.glsl`; extend `tools/shadercheck/voxel_packing_test.py`.
26. Replace the radial injection loop (`voxel_update.glsl`, currently guarded by a runtime `RTGI_POINT_LIGHT_STRENGTH > 0.0` after commit `216b896`) with an additive light-field write.
27. Add `voxel_update.glsl` to `shaders/program/gbuffers_all_solid.vsh` behind `#if defined RAYTRACED_GI`.
28. Verify `imageAtomicAdd` support on the target GPU **before** item 23 is merged.

### Tier F — Stage 5

29. `shaders/include/lighting/rt/ray_query.glsl` with `RayHit`, `trace_ray`, `trace_any_hit`.
30. Clipmap traversal with level transitions; replace `rtgi_voxel_ray_jitter` with deterministic epsilon push-out.
31. `tools/shadercheck/dda_test.py` mirror test; add to `run_checks.sh`.
32. Replace `sample_voxel_sun_shadow`'s `normal * 0.15` bias (`voxel_dda.glsl` lines 39-66) with `get_shadow_bias()`.

### Deferred but recorded

33. `RTGI_RESOLUTION` → `RTGI_SCALE` rename with profile migration (Stage 10).
34. Translation cleanup for the 8 non-`en_US` language files (Stage 10).
35. Reorganise the squashed history into per-stage commits (ongoing from Stage 0; **do not** squash again — see R26).

---

## 11. Open questions and assumptions

Only items that materially change architecture or feasibility.

### 11.1 Questions for the user (ordered by impact)

| # | Question | Why it matters | Default if unanswered |
|---|---|---|---|
| Q1 | Which GPU/vendor and OS do you run, and does the pack currently compile there? | Determines whether the `#if`-float bug is a real user-facing failure or only a portability landmine; determines whether `imageAtomicAdd` on `rgba16f` is available | Assume NVIDIA, lenient preprocessor; keep the portable two-image atomic path |
| Q2 | Is the pack ever going to be published (Modrinth/CurseForge)? | Photon's `LICENSE` forbids redistribution on monetised platforms without SixthSurge's written permission (R20) | Assume private/personal use |
| Q3 | Do you use Distant Horizons or Voxy regularly? | Decides whether Stage 4's DH/Voxy voxelization is must-have or nice-to-have | Assume DH is important (it is already supported for shadows and textures) |
| Q4 | Is Photonics support required, or was its removal intentional? | Stage 1 scope | Restore the stub |
| Q5 | Which of the six reported symptoms matters most: camera-dependent light, cave brightness, corner AO, seam stripes, ghosting, or flicker? | Orders Stage 3 vs Stage 7 work if effort is limited | Assume camera-dependent light (it is the most fundamental and the most reported) |
| Q6 | Target hardware floor (iGPU? handheld? 4K?) | Tier calibration and whether PT ships at all | Assume "mid dGPU at 1080p" floor, PT as an enthusiast tier |
| Q7 | Is a second, larger voxel range (512 blocks) actually needed, or is 128–256 enough? | Decides 4-level vs 3-level clipmap | Assume 256 blocks is sufficient; ship 4 levels anyway since it costs 1 MiB |

### 11.2 Assumptions (explicit, and what breaks if wrong)

| # | Assumption | Breaks if wrong |
|---|---|---|
| A1 | Iris 26.3 is the target platform and the pack need not support OptiFine | Already true per `README.md`; if OptiFine is needed, the entire compute-based design is invalid |
| A2 | `GL_MAX_IMAGE_UNITS ≥ 8` on the target | The plan uses ≤ 4 images per program; only an extremely old GPU would fail |
| A3 | `GL_MAX_3D_TEXTURE_SIZE ≥ 64` and `MAX_COLOR_BUFFERS = 32` | Clipmap and buffer budget; both are GL 4.3 minimums |
| A4 | The shadow pass reliably draws all nearby terrain chunks when `program.*/shadow.enabled = true`, even with `SHADOW` off | If Iris skips the pass entirely when `SHADOW` is off, Stage 4's coverage fix must rely on the camera pass alone — workable but weaker |
| A5 | Probe→probe feedback converges with hysteresis 0.85 in ≤ 64 frames | If it diverges, R1's fallback path is taken |
| A6 | A one-frame-latency direct-radiance buffer is visually acceptable in Stage 3 | If not, Stage 6's current-frame analytic evaluation must be pulled forward into Stage 3 |
| A7 | The user can run the in-game protocol (has Minecraft + Iris + time) | Without it, no stage can pass its gate; the plan stalls at Stage 0 |
| A8 | Photon's upstream material/BSDF layer is correct and can be trusted for the PT mode | If not, Stage 9 needs a BSDF audit first |
| A9 | `glslang`-based static validation is a sufficient proxy for Iris runtime compilation | It has caught real bugs (P0-1, the `#if`-float bug) but cannot catch uniform binding or driver-specific issues |

### 11.3 Explicitly unresolved (must be resolved by evidence, not by the plan)

1. **Whether DH/Voxy vertex shaders expose a world position usable for voxelization.** Not determined here; `dh_terrain.vsh` and `voxy_opaque.glsl` contain no voxel writes, and their attribute set is not documented in this repo beyond `docs/voxy_fragment_parameters.txt` (fragment only). Stage 4 task.
2. **Whether `imageAtomicAdd` on `rgba16f` works on the target driver.** Stage 4, first task.
3. **Whether Iris clears non-persistent custom images before the pass that reads them.** The audit asserts `voxel_img` is cleared per frame; this plan's 8 clipmap images depend on the same behaviour. Verify against `ImageClearPass` in Iris 26.3.
4. **Whether the current pack actually compiles on the user's GPU with the default profile.** Strongly implied by the audit's screenshot-driven iteration, but not verified in this environment.
5. **The actual magnitude of the view-dependence defect** (T9's percentage). It is qualitatively obvious from the code; the number is required to set the Stage 3 gate, so Stage 0 must measure it before Stage 3 begins.

---

## Appendix A — Audit method and what was actually run

| Activity | Result |
|---|---|
| Repository inspection | `git log`, `git diff 6e67b36..HEAD --no-renames`, 570 shader files / 26,651 lines counted, every lighting/RTGI/voxel file read in full |
| Upstream comparison | Fetched `sixthsurge/photon` `main` via GitHub API: `6e67b36`, 2026-10-23 — identical to the local parent commit |
| Iris verification | Cloned branch `26.3` at `671a5c87`; read `FeatureFlags`, `IrisLimits`, `ShaderProperties` (SSBO + program directives), `ImageInformation`, `ProgramArrayId`, pipeline ordering |
| SEUS inspection | Extracted the ZIP (446 entries); read `lib/Settings.inc`, `program/shadow.vsh.glsl`, `program/template/BlockShapes_CompileTime.glsl`, `program/template/PathTraceDenoiser.glsl`, `lib/Common.inc` licence text |
| Static compilation | Built `glslang 15.0.0` from source (cmake 4.4.4, g++ 12.2); ran both matrices before and after the fix |
| Runtime | **Not possible** — no Minecraft, no Iris runtime, no GPU in this environment |
| Repository state preserved | No user changes existed (`git status` clean at start); only `216b896` (the P0 fix) and this document were added |

## Appendix B — Summary of the one code change made during this audit

Commit `216b896` — *Fix illegal float literals in `#if` preprocessor expressions*.

- `shaders/include/lighting/rt/voxel_dda.glsl`: two `#if RTGI_POINT_LIGHT_STRENGTH > 0` guards → constant-folded runtime conditions `RTGI_POINT_LIGHT_STRENGTH > 0.0 && …`.
- `shaders/include/lighting/voxel/voxel_update.glsl`: one guard → runtime condition; removed the now-orphaned `#endif`.
- Semantics unchanged: light-only voxels are only ever written when injection is enabled, so the guarded accumulations were already unreachable with the default `0.00`.
- Verified: 308/308 + 780/780 static cases pass with `glslang 15.0.0`; `voxel_packing_test.py` and `properties_lint.py` pass.
