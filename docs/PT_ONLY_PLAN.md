# PT-only fork plan — reconstruction-first, Kappa-inspired, clean-room

**Date:** 2026-11-03  
**Status:** active roadmap; planning only, no shader code changed in this document.  
**Supersedes:** `docs/RT_PT_FORK_PLAN.md` (RT-first, PT deferred) and `docs/PT_IMPLEMENTATION_PLAN.md` (Stage 9 readiness plan) as the active direction. Those documents remain useful technical references, especially for numerical acceptance and image budgets, but their **RT-default / HYBRID / OFF mode assumptions are no longer the product contract**.  
**Companion document:** `docs/rt_pt_lighting_comparison.md` — verified feature inventory, Kappa cross-check and licensing constraints.

---

## 1. Product decision

The fork will ship **one lighting mode: PT**.

- No separate RT gameplay mode.
- No `OFF` / original Photon lighting mode.
- No `HYBRID` SSGI + voxel GI mode.
- No `pt_*` placeholder profiles that are actually GI-off direct light.
- No `RAYTRACED_GI` on/off switch, `LIGHTING_MODE_RT`, or SSR/SSGI transport controls in the shipped UI.
- All shipped profiles become **PT quality tiers**: low / medium / high / ultra / extreme, or equivalent names.

**Important boundary:** “PT-only” is a user-facing product contract, not yet a claim of unbiased full path tracing. The first production target is a **Kappa-like hybrid path tracer**:

- Rasterized primary visibility from the G-buffer.
- Explicit path-traced diffuse and specular lighting over Photon's world-space voxel scene.
- Direct sun/moon and shadow maps may remain initially, as in Kappa.
- Progressive accumulation, motion-aware reconstruction and path-traced indirect transport are mandatory.
- Full path-traced primary visibility, participating media, entities and refraction are later optional expansions, not release blockers.

Do **not** build a new RT scaffold. Delete the RT/PT split instead. Keep Photon's clipmap scene, emitter palette, direct-light model and material lighting as the substrate; replace the mode system and the reconstruction stack.

---

## 2. Evidence and current state

### 2.1 User-reported performance

| Build | Resolution scale | Reported FPS | Source |
|---|---|---:|---|
| Photon stock settings before workload reduction | 1.0 | 60 | User report, 2026-11-03 |
| KappaPT v18.8 | matching test scene | 90 | User report, 2026-11-03 |
| Photon after force-pushed workload reduction | 1.0 | 100–120 | User report, 2026-11-03 |

These figures are **user-measured**, not reproduced in this sandbox. Matched settings, GPU, scene and driver should be recorded before using them as a hard gate. The key product conclusion is valid regardless: a separate RT profile no longer buys enough performance to justify a second renderer, because Photon now runs at or above Kappa's reported frame rate.

### 2.2 Force-pushed performance commit

Remote `arena/ce39d2b2-photon` contains `4dd4391 Reduce stock probe-update and ray-tracing workload`. It changes:

- `RTGI_PROBE_RAYS` 32 → 8.
- `RTGI_PROBE_HYSTERESIS` 0.80 → 0.85.
- `RTGI_RAY_COUNT` 2 → 1.
- Probe updates 2048 → 1024 per frame, so the 32³ DDGI cycle becomes 32 frames.
- `voxel_dda_max_steps` from `RT_CLIPMAP_SIZE * 3 + 8` to `(RT_CLIPMAP_SIZE * 7) / 4 + 4`.
- `trace_any_hit` now caps its step count by `ceil(max_dist * 1.8) + 2`.
- Hot voxel loops early-out on `packed != 0u` before unpacking.
- DDGI query occlusion threshold 0.02 → 0.10.

**Branch note (updated 2026-11-04, P0):** the active branch is `arena/d99fd523-photon` at `f1df4b7`. The user instructed this session to **skip** the "decide whether to cherry-pick `4dd4391`" item, so plan option 3 applies: `4dd4391` remains an **external performance reference only** and was never fetched into, merged into or cherry-picked onto the active branch. See [`docs/pt_baseline.md`](pt_baseline.md) §1.

### 2.3 Known state of the current reconstruction

From the active branch and the fetched `RT_REAUDIT.md` / `RT_LIGHTING_BUGS.md` history:

- The lighting estimator itself is comparatively mature: world-space voxel RTGI, shape-aware clipmap DDA, emitter palette, sky/local leak gate, DDGI probe cache, voxel reflections and world-space sun/sky visibility.
- The **final processing is the bottleneck**: temporal accumulation, accumulation accounting, spatial denoising and their image/aux contracts are not delivering stable visuals.
- User-reported square bloom around bright regions tracks the à-trous kernel footprint at ±16 buffer texels, not geometry; three weight-tuning attempts were rejected. The re-audit explicitly says **do not re-tune weights** — redesign the kernel/stride.
- Temporal history is a fixed 32-frame cap with pure `1/n`, bilinear radiance history, soft disocclusion and no variance clip.
- The à-trous luma weight is wide and uncapped; variance is tracked as M2, but the reconstruction still carries too much of the image-quality load.
- Static tests exist on the remote branch, but there is no golden-frame or in-game regression harness here.

### 2.4 Why Kappa looks stable “from the first frames”

Kappa does **not** lack adaptation or denoising. It hides a large reconstruction system very well:

- 3D blue noise and quasirandom sampling.
- Half-resolution L1 spherical-harmonic diffuse output with Y/CoCg chroma.
- A 128³ world-space SH irradiance cache with reprojection and spatial filtering.
- Separate `DiffAccumulate.comp` and `RefAccumulate.comp` histories.
- Per-pixel sample age, variance and reactive masks.
- Adaptive accumulation up to `maxFrames=256`, `minAccumMult` and `ADAPT_STRENGTH`.
- A 7×7 spatial preaccumulation fallback when history is invalid.
- Five diffuse SVGF iterations at strides 32→16→8→4→2.
- Four specular/SPF iterations at strides 16→8→4→2.
- Guide/variance prepasses, flip passes, converged filtering and roughness-dependent sharpening.
- 37 `.csh` compute wrappers in `world0` alone.

At 90 FPS, ten frames pass in about 0.11 seconds. A low-frequency SH signal, a persistent irradiance cache, preaccumulation and long history can therefore look “converged immediately” to the naked eye. This is exactly the subsystem to study, not evidence that reconstruction is unnecessary.

---

## 3. Legal and technical boundary

### 3.1 Legal boundary

Kappa's `LICENSE` §4 requires explicit permission from RRe36 and clear credit before using parts of its source code in another original project. The user has stated that they do **not** have author permission. Therefore:

- **No verbatim Kappa `.comp` / `.glsl` / `.fsh` code may be pasted into this fork.**
- No Kappa noise textures, blue-noise volumes, atlas-derived logic or other assets may be copied.
- Algorithms, data-flow patterns, buffer layouts as concepts and tuning strategies may be studied and independently reimplemented.
- If permission is obtained later, code fragments can be used as references, but §§1–3 still restrict public redistribution, require the same license for public modified versions, and prohibit monetization without permission.
- The local `KappaPT_v18.8.zip` is ignored by `.gitignore` and must not be committed or redistributed.

### 3.2 Yes — even with permission, adaptation is a rewrite

Kappa's reconstruction is not a drop-in module. Every major idea crosses a different data contract:

| Kappa idea | Photon contract mismatch | Required clean-room adaptation |
|---|---|---|
| L1 SH diffuse irradiance | Photon stores RGB mean radiance + sky-origin fraction in a half-res RGBA16F chain. | Define a Y/CoCg SH raw format, change temporal/filter/aux packing, update `diffuse_lighting.glsl`, preserve the sky leak gate and debug views. |
| 128³ SH irradiance cache | Photon has a 32³ toroidal DDGI cache with isotropic RGB + sky fraction and its own invalidation. | Either upgrade DDGI to SH with directional coefficients, or add a separate world cache; choose one estimator and avoid double counting. |
| Separate diffuse/specular accumulation | Photon has one diffuse GI history chain and no dedicated reflection history. | Add reflection raw/history/aux images, roughness and reactive mask, and a second composition path. |
| 5-pass diffuse SVGF + 4-pass SPF | Photon uses a 4-pass narrow→wide 1/2/4/8 à-trous pyramid with no guide prepass. | Redesign stride order, guide/variance buffers and flip passes; fix the square-bloom footprint by changing the kernel hierarchy, not φ. |
| Adaptive accumulation up to 256 frames | Photon uses fixed `RTGI_HISTORY_FRAMES=32` and pure `1/n`. | Add per-pixel SPP, static-state detection, invalidation reasons, adaptive alpha and converged bypass. |
| 3D blue noise / quasirandom sampling | Photon uses R2 sequences, `noisetex` dithering and deterministic `safe_ray_dir`. | Independently implement animated blue-noise sampling against Photon's frame index and ray indexing. |
| Dual 256³ voxel maps + `RAtlasSampler` | Photon uses three nested 32-bit packed clipmaps with a palette/shape field. | **Do not port the backend.** Keep Photon clipmaps; optionally add a final-hit material lookup only if profiling justifies it. |
| `RColorTable` SSBO and strict Iris features | Photon requires only `CUSTOM_IMAGES COMPUTE_SHADERS`. | Keep Photon's uniform/table model unless an SSBO spike proves a real benefit. |

So the answer to “we can use pieces of code, but we still need to adapt them, right?” is **yes, twice over**: legally we cannot copy the pieces without permission, and technically a literal piece would not compile or produce correct radiance against Photon's buffers.

---

## 4. Target architecture

```text
Photon voxel clipmaps + emitter palette + direct sun/sky/shadow model
        |
        v
One PT integrator: explicit diffuse/specular paths, NEE/MIS, VNDF, SPP, bounces
        |
        v
Raw radiance / SH + aux: age, SPP, variance, depth, normal, sky fraction,
path length, reactive mask, validity, reset reason
        |
        v
Static-state detector
   |                         |
   v                         v
Progressive accumulation   Motion-aware reprojection + bounded history
        \                   /
         v                 v
Multi-scale diffuse SVGF + specular SPF, converged-pixel bypass
        |
        v
Single deferred composition; no RT/OFF/HYBRID lighting fallback
        |
        v
Existing TAA / exposure / bloom / color grading / post
```

**Radiometric rule:** one production estimator owns indirect/emitter/sky-bounce light. DDGI may remain temporarily as a cache or denoising aid behind an internal macro, but it must not be a second shipped lighting estimator. Reference PT output must be testable without probe-cache feedback.

**Scene rule:** keep Photon's nested clipmaps, toroidal addressing and 32-bit palette. Do not replace them with Kappa's dual-image atlas/octree backend. That would discard the performance work that now reaches 100–120 FPS and would rewrite half the shader for a problem that is primarily reconstruction.

---

## 5. Work packages and gates

Do not combine P1, P3 and P6 into one unreviewable change. Each gate must have a compile matrix, a debug view and a before/after capture.

### P0 — PT-only contract, baseline and branch decision

**Status: DONE on 2026-11-04** (branch `arena/d99fd523-photon` @ `f1df4b7`; static baseline green).
Records: [`docs/pt_baseline.md`](pt_baseline.md) (branch decision, static baseline, FPS) and
[`docs/pt_image_budget.md`](pt_image_budget.md) (per-tier image allocation).

**Goal:** stop maintaining two renderer concepts and freeze a reproducible starting point.

Tasks:

- ~~Decide whether to cherry-pick or port `4dd4391` into the active branch~~ — **skipped by user instruction.** Option 3 applies: the commit stays an external performance reference only. Record the active branch and commit in every later gate: `arena/d99fd523-photon` @ `f1df4b7`.
- Record matched captures and frame times for Photon stock x1.0, Kappa and the reduced-workload Photon build.
- Remove `LIGHTING_MODE_RT`, `OFF`, `HYBRID`, `RAYTRACED_GI` on/off and RT/PT profile split from public settings, language strings and docs.
- Keep a single temporary `LIGHTING_MODE_PT` compile guard until all pass/resource guards are migrated; then delete the enum too.
- Rename profiles to PT quality tiers. Do not advertise “unbiased” or “full path tracing” yet.
- Keep the current `rtgi_trace.csh` as a **temporary internal raw estimator** behind a developer macro so reconstruction can be rebuilt without simultaneously rewriting the integrator. It is not shipped as RT mode.
- Produce a per-mode image allocation table and restore a green properties/compile baseline.

Gate:

- Only PT profiles exist. ✅ Five tiers (`low`/`medium`/`high`/`ultra`/`extreme`); every `rt_*` / `pt_*` profile deleted.
- No public RT/OFF/HYBRID/SSR/SSGI mode tokens remain. ✅ `LIGHTING_MODE_RT` is gone from every shader, property and language file; the mode is not a menu switch; dead `RAYTRACED_GI` / `RTGI_TRACER` / `RTGI_SSGI_*` strings were removed from all nine translations.
- Lint and compile matrix pass for all three dimensions. ✅ `run_checks.sh` exits 0 (357 compute/fragment + 1053 wrapper/option cases, 0 failures), with three pre-existing failures fixed on the way (see baseline §2).
- Baseline captures, FPS and image budget are recorded. ⚠️ Image budget and FPS are recorded ([`pt_image_budget.md`](pt_image_budget.md), [`pt_baseline.md`](pt_baseline.md) §3); **matched captures are still outstanding** — they need a GPU and are the first P1 action item.

**What P0 changed in code:** the RT/PT split was not deleted by removing code — it was deleted by making PT the only value. `LIGHTING_MODE_RT` no longer exists; every `LIGHTING_MODE == LIGHTING_MODE_RT` guard is now `LIGHTING_MODE == LIGHTING_MODE_PT`, so the world-space voxel path (GI, contact AO, reflections, irradiance cache, voxelizing shadow/gbuffer passes) is what ships, and the GI-off placeholder branches are gone. `LIGHTING_MODE_PT` / `LIGHTING_MODE` survive as a **temporary compile guard** so the remaining guard sites can be folded into unconditional code one review at a time; deleting the enum is P7 cleanup. `PT_RAW_ESTIMATOR` marks `rtgi_trace.csh` as the temporary internal raw estimator (P6 replaces it).

### P1 — Reconstruction data contract and static-state detector

**Goal:** make accumulation observable and correct before changing filter weights.

Tasks:

- Define one aux layout for sample count, history age, M2 variance, depth/normal or material identity, sky fraction, path length, reactive mask, validity and reset reason.
- Add a static-state detector using camera translation/rotation, projection/FOV, viewport/TAAU scale, dimension, scene revision, lighting revision and relevant option changes.
- Do not reset merely because TAA jitter or `frameCounter` advances.
- Store actual accumulated SPP per pixel. For valid static history use `new_count = old_count + current_spp` and `current_spp / new_count` until the cap.
- Separate raw/reference accumulation from denoised display output.
- Add debug views for SPP, reset reason, variance, invalid paths, reactive mask and converged pixels.
- Preserve Photon's sky/local split and cave leak gate through the new format.

Gate:

- Static sample count advances and caps correctly.
- Camera motion, resize, FOV change, block edits, emitter edits and lighting changes produce the expected invalidation.
- No NaN/Inf in a long static run.
- Every new aux channel is read by shader code and visible in a debug view.

**Status 2026-11-04: contract landed, invalidation sweep outstanding.**

Shipped (`e45b545` → this commit):

- **One aux layout**, defined once in `shaders/include/lighting/rt/pt_state.glsl`
  and consumed by the trace, temporal, filter and debug passes so they cannot
  drift. Aux ping-pong: `(radiance.rgb, view distance)` + `(M2, pack(sky 4 bits,
  count 7 bits), octahedral normal .ba)`. A third, single-buffered
  `rtgi_state_img` carries `(reset reason, reactive mask, valid-path fraction,
  converged)`; it is written by `rtgi_temporal` and read only by later passes and
  the debug view, never by the dispatch that writes it.
- **SPP, not frames.** `RTGI_SPP_CAP` replaces `RTGI_HISTORY_FRAMES`; the
  temporal pass adds `RTGI_RAY_COUNT` (this frame's rays) to the pixel's count
  and blends with `current_spp / max(count, current_spp)`. At one ray per pixel
  the recurrence is bit-identical to the old `1/n`; at eight rays per pixel the
  cap now means 32 samples of evidence instead of 32 frames of wall clock. The
  127 ceiling is the aux packing limit, not a design choice — P2 raises the cap
  together with the packing.
- **Static-state detector** (`pt_static_state()`): camera translation, camera
  rotation (view basis) and projection/FOV. Jitter and `frameCounter` are
  explicitly not signals. The count only *grows* when the camera and projection
  are static; when they are not, the count is held rather than reset, which
  preserves the tuned pan behaviour (no dump to raw dots) while making the
  count mean independent evidence.
- **Reset reasons** (`PT_RESET_*`, nine of them) written on every exit path,
  including the finite/negative guard. `rtgi_trace` rejects non-finite and
  negative per-ray radiance and divides by the rays that survived, so a NaN can
  no longer poison the accumulation, the M2 moment or the à-trous taps.
- **Debug views** `GI_DEBUG_SPP` (accumulated samples, read from the packed aux
  channel) and `GI_DEBUG_RESET` (one colour per reason, read from the state
  image), with swatches and language strings.
- **Checks**: `tools/shadercheck/pt_state_test.py` in `run_checks.sh` — packing
  round trip over every representable pair, the fp16 exact-integer budget, the
  sample-accounting recurrence against a Python reference (including "the cap
  is reached in `cap/spp` frames" and "a pan from a converged field does not
  change the blend rate"), and that no temporal exit path skips the state
  store. Both negative cases were verified to fail the gate.
- `clipmap_test.py`'s image-budget check is now configuration-aware (it
  preprocesses `shaders.properties` per `GI_DEBUG` value instead of counting
  declared names), because the debug images are mutually exclusive.

**First in-game run (2026-11-04), and the bug it exposed.** With both views on:

- `GI_DEBUG_SPP`: static blocks warm to yellow, sky stays blue at zero, and
  disoccluded edges (grass, moving blocks) go blue — all correct.
- `GI_DEBUG_RESET`: during a pan, blocks report `CAMERA` (blue), with
  `OFFSCREEN` (purple) on the strip revealed at the screen edge and `DEPTH`
  (red) along building outlines — also correct, and the first time the
  invalidation story of a frame has been visible at all.
- **Bug:** after a pan stopped, the sample count often froze at an
  intermediate value instead of climbing to the cap, and the reset view
  flickered between `CAMERA` and `NONE` on a motionless camera. Rotating the
  view two or three degrees cleared it.

Cause: the static-state detector's rotation test was
`1.0 - dot(normalize(v), normalize(v)) < 1e-7`, and that expression does not
return zero for a camera at rest — it returns a float32 rounding error.
Measured over 40k camera orientations (`tools/shadercheck/pt_state_test.py`
repeats the measurement): 67.0% return exactly 0, 29.1% return a small
negative value, and **3.9% return a positive value up to 1.79e-7**, which
fails the test. At those orientations a perfectly still camera was reported as
moving, so the sample count was held forever — and moving the camera a couple
of degrees changed the rounding, which is why jiggling "fixed" it.

Fix: two guards instead of one. (1) Bit-exact equality of the previous and
current camera position, modelview and projection — at rest Iris hands the pack
the matrices it built last frame, so this is the normal path and rounding
cannot touch it. (2) Tolerances an order of magnitude above the measured
noise: 1e-3 blocks of translation (clears the float32 spacing of
`cameraPosition` out to ±8192 blocks), 1e-6 for `1 - dot` (5.6× the worst
measured error, ≈0.08°/frame ≈ 1.7 px at 1080p), 1e-6 for the projection
terms. The test asserts both the margins and that a "static" frame cannot pan
more than 3 px, so the threshold cannot be quietly loosened or tightened into
the noise again.

Deviations from the task list, and why:

- **No scene-revision or lighting-revision signal.** Iris exposes no block-edit
  or emitter-edit counter, and the state image cannot be read by the dispatch
  that writes it, so a previous-frame revision hash has nowhere to live. A
  block edit changes depth at the edited pixels, which the existing
  disocclusion test catches; an emitter edit changes only radiance and is
  absorbed by the blend. Both show up as their reason codes in the reset view
  rather than as a targeted invalidation. Revisit if P2's adaptive alpha makes
  the lag visible.
- **The detector gates count growth, not hard resets.** Resetting on camera
  motion is exactly the behaviour P0 rejected (raw dots on every pan).
- **Debug views for invalid paths, reactive mask and converged pixels** are
  carried in the state image; only SPP and reset reason have dedicated views
  so far. The reactive mask is defined today as "how much history this pixel
  dropped", which is what P3's converged-pixel bypass needs; P5 adds the
  material-driven water/wetness term on top.

Behaviour that is by design, confirmed in-game: while the camera moves, newly
revealed surfaces stay blue in `GI_DEBUG_SPP` until the camera stops, because a
reprojected sample is the same light re-measured rather than new evidence. The
count is *held* during motion rather than reset, so a pan neither dumps the
field to raw dots nor invents samples; it resumes climbing the moment the
camera settles.

Outstanding before the gate can be closed:

- Matched captures and an **invalidation sweep**: stand still → `GI_DEBUG_RESET`
  should go `NONE` within a few dozen frames; pan → `CAMERA`; resize → `FIRST`/
  `NO_SURFACE` at the new texels; FOV slider → `PROJECTION`; place a block →
  `DEPTH` along the edited surface; place a torch → no reset (expected
  limitation above). `GI_DEBUG_SPP` should be flat during motion and ramp to
  the cap when still.
- A long static run with `GI_DEBUG_RESET` on, to confirm no `NON_FINITE`.

### P2 — Temporal accumulation rewrite

**Goal:** replace fixed 32-frame `1/n` with Kappa-class motion behavior, implemented independently.

Tasks:

- Replace the fixed history cap with a configurable, per-pixel sample count and a much larger cap, e.g. 128–256 frames, subject to image-format precision.
- Add adaptive responsiveness: a conservative `minAccumMult`-style floor, disocclusion-driven alpha and `ADAPT_STRENGTH`-style rejection, without reintroducing a motion alpha that dumps the field into raw dots on every pan.
- Add a 7×7 spatial preaccumulation fallback only when history is invalid; this is a major reason Kappa can look clean immediately.
- Keep bilinear radiance history and point-sampled packed aux.
- Keep the correct M2 EMA of sample luminance squared; do not blend toward the square of the filtered mean.
- Keep the current project rule of no variance clip in reference mode; measure any display-mode firefly suppression separately.
- Add separate specular history later in P5; do not pretend one diffuse history can serve both.

Gate:

- Camera pans no longer collapse into raw dots.
- Static convergence is visibly faster than 32 frames.
- Ghosting is bounded and has a debug view.
- First-frame / invalid-history fallback removes most raw noise without edge smearing.

**Status 2026-11-04: three of four tasks shipped; the spatial fallback deferred.**

Shipped:

- **Cap 32 → 128 samples, ceiling 255.** The aux channel was repacked for it:
  `pack_sky_count()` now spends 8 bits on the sample count (0..255) and 3 on
  the sky fraction instead of 7 and 4. The largest packed value is still 2047,
  inside the fp16 exact-integer range. The sky fraction is the channel that
  paid; it has no lighting consumer today (the leak gate is applied per ray in
  `rt_gi.glsl`), and P4 has to buy the bit back if it starts driving shading.
- **`RTGI_MIN_ACCUM` — the Kappa `minAccumMult` floor.** The blend rate never
  decays below `0.01 * RTGI_MIN_ACCUM`, so a pixel sitting at the cap still
  tracks a changing scene, and ghosting is bounded at `1 / (0.01 * mult)`
  frames no matter how high the cap is. `0` restores the P0 behaviour (a full
  history stops adapting).
- **`RTGI_ADAPT_STRENGTH` — adaptive rejection, formulated for this pack.**
  Kappa drives rejection from a stored lightmap value; Photon has no free aux
  channel to store one, but it does track M2, so it asks the sharper question:
  how far is this frame's sample from the history mean, measured in the
  history's **own sample sigma** (`z = |raw - M1| / sqrt(M2 - M1^2)`). A z near
  1 is ordinary Monte-Carlo noise; a z of several means the light changed.
  `smoothstep(2, 6)` in sigma units, scaled by the strength, `0` disables it.
  It **raises alpha** rather than clipping the history value, which is exactly
  why it is not the variance clip this pack deliberately does not have: nothing
  moves toward the new sample except by blending, so the estimate cannot pump
  in brightness the way a clamped history does.
- **The count is now consistent with the blend rate.** When a rejection fires,
  `sample_count` is set to `spp / alpha` (clamped), because 1/alpha *is* the
  effective history length. An earlier version merely halved the count and left
  a 1.4 s tail: the pixel kept a count of 86 while blending at 0.0116. The
  floor deliberately does not shorten the count — it is a steady-state
  responsiveness guarantee, not a statement about evidence.
- **`PT_RESET_ADAPTIVE`**, the tenth reset reason, with its own colour in
  `GI_DEBUG_RESET`, so "the lighting changed here" is visible per pixel.
- `pt_state_test.py` models the whole recurrence on the CPU and asserts both
  directions: a converged static pixel blends at the floor and its count never
  shortens (noise must not shorten history), while a lighting jump is absorbed
  in far fewer frames than the floor alone manages.

Measured on that model (1 ray/px, cap 128, sigma 0.2, light 0.30 → 1.20,
within 10% of the new value):

| `RTGI_ADAPT_STRENGTH` | frames to absorb the change |
|---|---:|
| 0.0 (disabled, P1 behaviour) | 229 |
| 0.25 | 45 |
| **0.5 (default)** | **17** |
| 0.75 | 9 |
| 1.00 | 3 |

**First in-game run (2026-11-04): the adaptive rejection as first shipped was
worse than off, at every strength.** Reported: at 0.5 persistent low-frequency
clumps (dark in the highlights, light in the shadows); at 0.75 raw
high-frequency dark dots; at 1.0 bright dots as well; at 0 stable. At 1.0 any
camera motion suppressed denoising entirely — raw dots everywhere, recovering
1–2 s after the camera stopped, with the light stable only within ~1.5 blocks
of a source. `GI_DEBUG_RESET` showed dots flashing over everything plus
screen-fixed pink/purple horizontal bands.

Four defects, all in the adaptive work (the cap and the floor were not
implicated):

1. **The test statistic was a single raw sample.** At one ray per pixel the
   sample's own sigma is comparable to the signal, so no threshold separates
   "the light changed" from "Monte-Carlo". Measured on the CPU model
   (4000 frames, Gaussian with a 5% heavy tail, sigma 0.25 on a 0.60 signal):
   the shipped version was **9.8× noisier** than adaptive-off at full strength.
   Fixed by testing the **3×3 neighbourhood mean** instead (nine independent
   samples, three times quieter) and dividing by the neighbourhood's sigma over
   three. That is also self-limiting at geometric edges, where the
   neighbourhood spans surfaces and inflates the same sigma it is divided by.
2. **No gate on motion.** On a pan the reprojected history and the current
   frame disagree by construction, so z was enormous and the field was dumped —
   exactly the motion alpha this pack removed on purpose. Now gated on the
   static-state detector, on reprojection confidence ≥ 0.9, and on a history of
   at least 16 samples (which also breaks the
   reject → short history → reject feedback loop).
3. **A rejection shortened the sample count** (`count = spp/alpha`). One z
   spike dropped a converged pixel from 128 samples to 3, and at one sample per
   frame that took about two seconds to rebuild — the observed recovery time,
   and why the clumps stayed. Reverted: the count is accumulated evidence; the
   floor and the rejection are responsiveness overlays on top of it, and the
   `converged` flag now accounts for a rejection instead.
4. **The reset debug view read a packed reason code bilinearly.** Averaging
   code 3 with code 9 reports a reason that was never written, which painted
   the screen-fixed bands between two real colours. Now point-sampled with
   `texelFetch`, like every other packed field in the pack.

Measured after the fix (same model, 3×3 statistic, sigma 0.25, signal 0.60,
step 0.30 → 1.20, within 10% of the new value):

| statistic | thresholds | noise vs off | false rejects | frames to a step |
|---|---|---:|---:|---:|
| single raw sample (shipped first) | 2 / 6 σ | **×9.8** | 27 / 4000 | 17 at strength 1.0 |
| 3×3 mean | 1.5 / 6 σ | ×1.12 | 5 / 1200 | 20 at strength 1.0 |
| **3×3 mean (shipped)** | **2 / 8 σ** | **×1.00** | **0 / 1200** | 272 off · 156 @0.25 · 130 @0.5 · 57 @1.0 |
| 3×3 mean | 4 / 12 σ | ×1.00 | 0 / 1200 | 272 off · 215 @0.25 · 187 @0.5 · 170 @1.0 |

So the honest trade: the first version's 17-frame response cost 9.8× the noise;
2/8 buys a 2.1× response at 0.5 and 4.8× at 1.0 for no measurable noise at all.
`RTGI_ADAPT_STRENGTH` defaults to 0.5.

The measurement is a CPU *model* of the recurrence, so a shader edit can leave
it green while shipping something else. `pt_state_test.py` therefore also
asserts the wiring in the source: the 3×3 mean, the sigma/3, all three gates,
no count shortening, and the point-sampled debug read. All three regressions
were verified to fail it.

Deferred, with the reason: **the 7×7 spatial preaccumulation fallback**. It is
the most expensive of the four tasks (49 taps on every invalid-history pixel),
and P3 redesigns spatial filtering anyway, so building it now means building it
twice. It gets its own gate and its own before/after captures.

A/B to run before closing P2 (the first three already ran once, against the
defective statistic, and need repeating against this one):

1. Stand still in a torch-lit interior and place a torch: with
   `RTGI_ADAPT_STRENGTH 0` the bounce crawls in over seconds; at 0.5 it should
   settle in a few frames. `GI_DEBUG_RESET` should flash `ADAPTIVE` (amber) on
   exactly the pixels whose light changed.
2. Pan fast, then stop: no raw dots (that is the floor, not the cap, holding
   the history), and `GI_DEBUG_SPP` should climb to full again.
3. `RTGI_MIN_ACCUM 0` with `RTGI_SPP_CAP 255`: the cleanest static image the
   pack can produce, at the cost of a scene that stops responding — useful as
   the "how much convergence is available" reference.
4. Watch for the failure mode on purpose: `RTGI_ADAPT_STRENGTH 1.0` in a dark,
   noisy scene. If noise starts to shimmer, the z thresholds (2σ/6σ) are too
   tight for that scene and should be widened, not the strength lowered.

### P3 — Spatial denoise redesign, not re-tuning

**Goal:** remove the square bloom footprint and get Kappa-class edge preservation.

Tasks:

- **Do not tune `RTGI_FILTER_PHI`, Gaussian weights or σ caps again.** The re-audit proved weight tuning does not change the footprint.
- Redesign the kernel hierarchy: wide→narrow multi-scale strides, e.g. 32→16→8→4→2 for diffuse and 16→8→4→2 for specular, with explicit flip passes.
- Add guide/variance prepasses or equivalent guide buffers.
- Add a conservative converged-pixel bypass so static pixels stop being blurred.
- Preserve normal/depth/luminance edge stops, but feed them from the new variance and aux contract.
- Redesign the upscale/filter footprint so bloom no longer inherits ±16 buffer-texel squares.
- Keep `GI_DEBUG_VARIANCE` and add stride/iteration debug views.

Gate:

- User-reported square glow around bright regions is gone.
- No new color bleed across high-contrast edges.
- Converged pixels are not progressively over-blurred.
- Filter cost and dispatch count are recorded.

### P4 — Directional L1 SH irradiance

**Goal:** give normal maps and one-sided window bounce a directional signal.

Tasks:

- Independently implement a compact L1 SH representation: four luma coefficients plus Co/Cg chroma, or an equivalent YCoCg packing.
- Decide whether SH replaces raw RGB in the screen chain, upgrades the DDGI probes, or both. Start with one path; do not double-count.
- Update temporal accumulation, M2 variance, spatial filter, sky-fraction handling and all debug views for the new layout.
- Evaluate SH against the receiver's normal-mapped normal in deferred composition, as Kappa does with `ProjectIrradiance`.
- Preserve the receiver-skylight leak gate; encode or separately store the sky/local origin fraction.
- Validate furnace, colored-bounce and normal-map scenes against the RGB baseline.

Gate:

- Normal-mapped brick/cobble/stone respond to indirect direction.
- No energy gain, channel bias or sky-leak regression.
- Raw SH, filtered SH and projected irradiance are separately debuggable.

### P5 — Separate specular reconstruction

**Goal:** make reflections as stable as diffuse GI.

Tasks:

- Add dedicated specular/raw reflection radiance, history and aux images.
- Store roughness, water/wetness reactive mask and path length.
- Add an independent SPF-like denoise chain and converged bypass.
- Extend Photon's world-space voxel reflections to multi-bounce with Fresnel/BRDF throughput and a bounded cap.
- Keep off-screen voxel tracing; do not reintroduce SSR as primary transport.
- Add refraction/TIR only after specular reconstruction is stable.

Gate:

- Rough reflections at 1–2 rays no longer shimmer.
- Water/wet surfaces do not smear during motion.
- No reflection double count in composition.
- Reflection cost stays within the measured budget.

### P6 — PT integrator on the Photon scene backend

**Goal:** replace the temporary raw estimator with explicit path transport, after the reconstruction contract is stable.

Tasks:

- Add `include/lighting/rt/path_trace.glsl` behind an internal macro first.
- Implement diffuse-only explicit bounces, SPP, emitter/sun NEE, MIS, Russian roulette and finite-value checks before adding glossy transport.
- Reuse Photon's `trace_scene_ray` / `trace_any_hit` / clipmap query interfaces; do not depend on Kappa's octree.
- Add GGX-VNDF specular sampling with an explicit PDF contract and shared Fresnel/material decode.
- Keep direct sun/moon shadowing consistent with the existing direct term; audit term-by-term for double counting.
- Keep reference PT output free of DDGI/probe feedback; a probe-assisted tail can be a later explicitly approximate performance mode.
- Reuse the independent CPU reference and furnace tests from the deferred Stage 9 plan.

Gate:

- Raw PT at 1024+ SPP agrees with an independent CPU reference within the agreed tolerance.
- Finite-bounce furnace and sealed-cave tests pass.
- No NaN/Inf, no double-counted albedo/direct/emitter light.
- Diffuse-only results remain stable when glossy transport is added.

### P7 — Profiles, cleanup and release validation

Tasks:

- Remove RT/OFF/HYBRID settings, language strings, tests, stale headers and stale docs.
- Update `README.md`, `shaders/lang/en_US.lang` and `shaders.properties` so PT is the only advertised lighting path.
- Decide the fate of inactive `shaders/photonics/` ReSTIR stubs: leave explicitly unsupported or remove; do not half-enable.
- Re-run the static matrix, image-allocation lint and all three dimensions.
- Record matched FPS, frame time, VRAM and first-frame convergence at stock x1.0.
- Publish known limitations: raster primary visibility, direct shadow maps, bounded clipmap range, no full media/entity/refraction path transport in the first release.

Gate:

- Only PT is user-selectable.
- No hidden analytic Photon lighting fallback remains.
- No Kappa source or assets were copied.
- Performance does not regress below the user-reported 100–120 FPS baseline at matched settings.
- Visual gates pass: square bloom gone, no raw-noise first frames, bounded ghosting, stable reflections, sealed caves dark, torch rooms lit by traced emitters.

---

## 6. Priority order

1. **P0 — PT-only contract and baseline.** Remove the RT/PT split; do not build a new RT scaffold.
2. **P1 — Reconstruction data contract.** Aux channels, SPP, static-state detector, reset reasons and debug views.
3. **P2 — Temporal accumulation rewrite.** Adaptive history, preaccumulation fallback, longer convergence.
4. **P3 — Spatial denoise redesign.** Multi-scale stride hierarchy, guide/variance prepasses, converged bypass, square-bloom fix.
5. **P4 — L1 SH diffuse irradiance.** Directional GI and normal-map response.
6. **P5 — Separate specular reconstruction.** Reflection history, reactive masks, SPF-like filter, multi-bounce specular.
7. **P6 — Explicit PT integrator.** Diffuse reference, NEE/MIS, VNDF, RR, numerical acceptance.
8. **P7 — Cleanup and release gates.** UI, docs, tests, performance report.

P1–P3 are the direct answer to “final processing is awful”. Do not add more rays, a new voxel backend or a full unbiased integrator before those gates pass.

---

## 7. Explicitly out of scope for the first PT-only release

- Kappa's dual 256³ `R32UI` voxel maps, 128³ octree and `RAtlasSampler` / `_Specular` payload.
- Kappa's 37-wrapper pipeline as a literal port.
- Full path-traced primary visibility, camera rays through every G-buffer surface, or path-traced media.
- ReSTIR / reservoir resampling. Kappa has no working ReSTIR in v18.8; Photon's Photonics hooks are inactive.
- Reflective caustics, path guiding, fog irradiance volume and other Kappa WIP/commented features.
- A second RT gameplay profile.
- Re-tuning existing denoiser weights as a substitute for kernel redesign.

---

## 8. Definition of done

The PT-only fork is ready when:

- There is one shipped lighting path and one set of PT quality profiles.
- No public RT, OFF, HYBRID, SSGI, SSR-primary or GI-off placeholder mode remains.
- Raw path transport can be validated without denoising or probe feedback.
- Progressive accumulation advances, caps and resets correctly.
- Motion-aware reconstruction is stable and the first clean frame arrives within a few frames at the target frame rate.
- The square à-trous bloom footprint is gone.
- Diffuse GI has directional SH response; specular has its own history and denoiser.
- Photon's clipmap scene, emitter palette, direct-light model and sky/local leak control remain intact and are not double-counted.
- All image allocations stay within Iris limits and are documented.
- Static, numerical, visual and performance gates pass at matched settings.
- No Kappa code or assets were copied without permission; all adopted techniques are clean-room implementations with credit where appropriate.

---

## 9. Resolved item — the force-pushed performance commit

**Resolved 2026-11-04 (P0): option 3.**

The force-pushed performance commit `4dd4391` is on remote `arena/ce39d2b2-photon`, while this session's active branch is `arena/d99fd523-photon` at `f1df4b7`. The user instructed this session to skip the decision, which settles it as **option 3: keep the current branch as-is and treat `4dd4391` as an external performance reference only.** It was not fetched, merged, cherry-picked or reset into the active branch.

Practical note for anyone revisiting this: the two trees have diverged in ways that make a literal port meaningless — `RTGI_PROBE_RAYS` / `RTGI_PROBE_HYSTERESIS` (which `4dd4391` changes) no longer exist here, because the DDGI probe cache was replaced by the voxel irradiance volume. A port would be a re-implementation plus a re-measurement, not a cherry-pick.

Successor item, still open: **matched captures.** No screenshot pair or frame-time trace for this branch exists. Every visual gate from P1 onwards compares against P0, and P0 currently has user-reported FPS numbers only. Produce them as the first P1 action.