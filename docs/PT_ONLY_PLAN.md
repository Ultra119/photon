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

**Status 2026-11-04: all four tasks shipped, and two motion defects found in
game and fixed.**

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

(Response times for the shipped version are in the measurement table after the
fix, below — the numbers first recorded here were measured with the defective
single-sample statistic and the count-shortening rejection, both since
reverted.)

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

**Second in-game run (2026-11-04): "the light freezes and doesn't stabilize
until you come to a complete stop; while moving it is pure noise made of dots,
and when panning it stabilizes with a delay, as vertical stripes."** Both
halves of that are one bug, and there is a second behind it.

1. **The sample count was frozen whenever the camera moved.** P1 decided that
   "a reprojected sample from a moving camera is the same light re-measured,
   not new evidence", so `sample_count` was *held* rather than grown. Half
   right: the light is the same, but the rays are new and independent, so
   averaging them does cut variance by 1/sqrt(N) — that is the entire basis of
   temporal reuse under a moving camera, and why Kappa is clean while you move.
   What the reasoning was really protecting against is *bias* from a wrong
   reprojection, and that is the disocclusion tests' job, not the count's.
   The consequence was worse than the bias it avoided: a pixel revealed by a
   pan — a disocclusion edge, or the strip of new world at the leading edge —
   restarted at about one sample and then **could never grow for as long as the
   camera kept moving**. Pan for a second and the whole screen is newly
   revealed and pinned at that one sample: the field of dots. The columns
   revealed last are the last to converge, which is the vertical stripes, and
   they only start converging after the camera stops, which is the delay.
   Now: `sample_count = min(prev_count + current_spp * total_confidence, cap)`.
   The confidence weighting keeps the honest part of the old reasoning — a
   pixel whose reprojection is barely trusted should not claim a full sample of
   new evidence — without freezing it.
2. **The depth disocclusion test compared distances measured by two different
   cameras.** It compared the distance the previous frame stored against the
   distance the *current* camera measures, so for a static world they differ by
   exactly the camera's own motion: walk one block toward a wall and the
   measurement changes by one block, although the wall and the light on it have
   not moved. The confidence then collapsed and the pixel fell back toward its
   raw sample. Now the current surface point is transformed into the previous
   camera's view space first, which is the first half of
   `reproject_scene_space()` — for a static surface the previous camera's
   view-space depth of the current point is exactly what the previous frame
   stored, so the difference measures geometric disagreement only.

Measured for the second one (static world, moving camera, both sides rounded to
fp32, points across the visible screen):

| case | old diff | new diff | tolerance | old confidence |
|---|---:|---:|---:|---:|
| standing still | 0.000 | 0.000 | 0.480 | 1.000 |
| walking, wall ahead | 0.070 | 0.000 | 0.356 | 1.000 |
| sprinting, 5.6 blocks/s | 0.093 | 0.000 | 0.220 | 1.000 |
| elytra, 20 blocks/s, near geometry | 0.330 | 0.000 | 0.136 | **0.000** |
| elytra, 20 blocks/s, far geometry | 0.330 | 0.000 | 1.753 | 1.000 |
| slow pan, near corner | 0.050 | 0.000 | 0.100 | 1.000 |
| slow pan, mid screen | 0.130 | 0.000 | 0.808 | 1.000 |
| fast pan, mid screen | 0.625 | 0.000 | 0.778 | 1.000 |
| fast pan, screen edge | 0.760 | 0.000 | 0.299 | **0.000** |
| walk and pan | 0.235 | 0.000 | 0.402 | 1.000 |

So the depth test was **not** the main cause — ordinary walking and moderate
pans were fine, and only fast translation near geometry and fast pans at the
screen edge collapsed. It is fixed because it is wrong in principle and cheap to
fix, not because it explains the report. The frozen count is what explains the
report.

**Third in-game run (2026-11-04): trails behind blocks while moving, the room
brighter while moving, "fills with light evenly" once stopped, and a 2-4 s
burn-in when a torch is removed.**

*The trails, the brighter-while-moving and the even fill are one bug, and it is
the fallback shipped below.* It gathered from every geometrically acceptable
neighbour, but depth and normal cannot separate a lit patch from the unlit
patch beside it on one flat wall — same depth, same normal, different light —
so the gather averaged straight across the lighting boundary. Measured on a
lit/unlit wall pair, a texel revealed next to the boundary came out **10.5× too
bright**, and 5.7× two texels away. Credited as six samples and then held for
the next hundred frames, that is a bright band painted along every newly
revealed strip: the trail behind a moving block, the room that fills with light
evenly, and the brightness that rises while the camera moves.

Fixed by restricting the gather to texels the **previous frame had to reset** —
texels that are as clueless as this one. A neighbour with converged history is
a texel of the frame that was visible before this surface was revealed, which
is exactly the lighting not to inherit. The gather is now self-limiting: it
averages freely when a large region appears at once (first frame, resize, fast
pan — where it is wanted) and leaves a slow pan's one-texel-wide reveal strip
to fend for itself. With the restriction the borrowed mean is the local
radiance to within 0.1% at every position.

*The burn-in is the Voxel Irradiance Volume.* It accumulates one ray per cell
per frame with `alpha = 1/N` and **no change detection of any kind** — the only
thing that ever invalidates a cell is the camera-scroll reprojection — so `N`
is also how long the volume takes to forget a removed light, and
`VOXEL_CACHE_MULTIBOUNCE` feeds the cache back into itself which stretches the
tail. Placing a torch is quick because the screen-space accumulator has an
adaptive test and the deferred pass has analytic direct light; removing one has
neither. Modelled (cell decay `1 - (1-k)/N`, multi-bounce feedback
`k = 0.8/pi * 0.85`, 60 fps, to 10%):

| cache history | fade to 10% | without multi-bounce |
|---|---:|---:|
| 128 samples (shipped) | **6.2 s** | 4.9 s |
| **24 samples (now)** | **1.2 s** | 0.9 s |

The volume feeds only the second bounce and is spatially filtered every frame
(six-neighbour air-constrained blur), so it does not need the deep history the
screen-space accumulator does. Two other mechanisms are in the same time range
and were **not** changed: the screen-space floor (`RTGI_MIN_ACCUM`, 0.01 →
3.8 s to 10%) and auto-exposure, which brightens the residual as the scene
darkens. If the burn-in survives this change, it is one of those two.

**Fourth in-game run (2026-11-04): the irradiance volume is black indoors, and
the torch has no bounce.** `GI_DEBUG_VOXEL_LIGHT` is *not* black — walls are
grey and only emissive blocks are coloured — so the voxel clipmap is fine and
the volume's own input is the problem. It is:

`voxel_dda.glsl`, the one place the RT path turns a surface hit into outgoing
radiance:

```glsl
// Solid voxels never inject analytic block ambient. Emission is
// intrinsic radiance and is not divided by pi.
vec3 emission_radiance = mat.emission;
vec3 bounce_radiance = bounce_albedo * sun_irradiance * voxel_bounce_rcp_pi;
result.radiance = emission_radiance + bounce_radiance;
```

`block_light` and `sky_light` are **never referenced anywhere under
`include/lighting/rt/`**. So a surface hit returns emission plus *sun* bounce
and nothing else, and in a closed room at night `sun_vis = 0` and the emission
is zero unless the ray happens to hit the torch itself. Consequences, all
matching observations:

- **The Voxel Irradiance Volume holds almost nothing indoors**, because it is
  fed by these same rays. That is why `GI_DEBUG_PROBE` is black. (The magenta
  at the render distance edge is not a bug — it is the "outside the fine
  clipmap volume" marker.)
- **`VOXEL_CACHE_MULTIBOUNCE` has been contributing approximately nothing
  indoors**, since it reads that volume.
- **Torch light has no indirect bounce at all.** The torch's *direct* light is
  analytic in the deferred pass and instant, which is why placing one looks
  right; the light it throws onto a wall is never re-radiated, because the
  wall's outgoing radiance as far as the RT path is concerned is zero. That is
  the "the room fills with light evenly" and the "very few bright spots on the
  walls": the spots are the rare rays that hit the emitter directly, and they
  are sparse enough that the à-trous averages them away.

This is a deliberate line in the code, not an oversight, and closing it is a
lighting-model change (P6), in two steps that both have to land:

1. populate `block_light` / `sky_light` during voxelization — right now the
   walls read as grey, i.e. zero, in `GI_DEBUG_VOXEL_LIGHT`;
2. add a block-light irradiance term to `voxel_dda.glsl`'s outgoing radiance,
   as `albedo * block_light_irradiance / pi`, alongside the existing sun term.

Until then the volume is close to inert indoors and costs 1.240 ms (23% of the
frame, `docs/pt_perf_baseline.md`). `VOXEL_CACHE_ENABLED` is now a real switch
— it used to be defined, set by every profile, and read by nobody, so the four
passes ran unconditionally. Turning it off recovers that time and loses
essentially nothing indoors; outdoors the volume does hold real sun/sky
irradiance, so it is not inert there and it stays on by default.

**Fifth pass (2026-11-04): the strip at the edge of the screen that takes
seconds to settle after the smallest camera movement.** Not an accumulation
problem — a *reporting* one. After a soft reset the estimate is 90% one raw
sample, so its variance is `0.9²` of a single sample's. The M2 EMA cannot say
that: it reports `0.9 · 0.1 · (new − old)²`, which shrinks towards zero the
**more** completely the history was discarded, so the noisiest pixel on screen
is the one the à-trous is told is cleanest.

Measured (40 000 trials, per-sample sigma 0.30, history 128 samples):

| | variance | std |
|---|---:|---:|
| reported by the M2 EMA | 0.0082 | 0.091 |
| true variance of the blend | 0.0729 | 0.270 |
| | **8.9× under-reported** | 3.0× |

`sigma_l = PHI · sqrt(var)` and `sigma_n = mix(128, 8, std / (m1 + 0.02))` are
then both ~3× too tight, so the filter barely touches the pixel and it has to
wait for 1/N accumulation. It also explains why a **first frame** looks better
than a pan: the first-frame path seeds `m2` from the local spatial variance and
gets it right, while every soft reset during motion overwrote that seed with
the EMA.

Fixed by reporting the variance of the blend itself,
`Var(aX + bY) = a²Var(X) + b²Var(Y)`, the same treatment the spatial fallback
branch already used.

Two related notes, not changed:

- **The reactive mask is written and never read.** `pt_state_reactive()` has no
  callers; the à-trous has no idea which pixels were reset this frame beyond
  what the variance tells it. The variance fix covers the same ground, so the
  channel stays dead for now rather than adding a second, overlapping signal.
- **The M2 EMA over-reports by ~2× on a converged pixel** (its
  `α(1−α)·d²` term is maximal mid-transition). That is the conservative
  direction — the filter blurs a pixel that is adapting, which hides the
  transition — so it was left alone.

**Sixth pass (2026-11-04): "the room is only evenly lit when I'm moving; when
I'm standing still I can see darker and lighter areas."** That inversion is the
resample kernel. The history is resampled at a fractional position **every**
frame, and every resample is a low-pass filter, so the blur accumulates for as
long as the camera moves and the sharp new samples can only replace it at 1/N
per frame. Measured over 128 frames of resampling:

| feature size | bilinear | Catmull-Rom |
|---|---:|---:|
| 8 texels | **0 %** | 56 % |
| 16 texels | **20 %** | 96 % |
| 32 texels | 67 % | 100 % |
| 64 texels | 90 % | 100 % |

At half resolution, 8–16 texels is 16–32 screen pixels: every GI feature
smaller than that is destroyed while the camera moves and only returns once it
stops. Point sampling is not the alternative — it makes the accumulated pattern
swim in texel steps under dolly — so the fix is an *interpolating* kernel with
a negative lobe: exact when the reprojection lands on a texel centre (a still
camera), sharp in between. Now `catmull_rom_weights()`, 16 taps instead of 4,
renormalised because the negative lobes do not sum to 1 at a clamped edge.

**Open, and agreed to defer — all three are P3 or P6, not tuning:**

- **The blur at the screen edge and behind moving blocks is one artifact and it
  is the à-trous doing its job.** A revealed pixel has one sample; the filter
  is told (correctly, since `90012dc`) that it is noisy and blurs it hard. The
  choice is noisy or blurred, and doing better needs a better prior than
  "average the neighbours" — that is P3's redesign.
- **Lava fireflies.** A bright emitter at one ray per pixel produces sparse
  direct hits that survive `RTGI_MAX_RADIANCE` and out-run the à-trous. The fix
  is importance sampling the emitter (P6), not a tighter clamp, which would
  cost legitimate brightness.
- **Torch/lava light has no bounce** (see above): P6, two steps.

**The 7×7 spatial preaccumulation fallback shipped after all** — it was
deferred at first as "the most expensive task, and P3 redesigns spatial
filtering anyway", but it is also the one that answers the last open gate item
directly. `RTGI_SPATIAL_FALLBACK` (on by default):

- A pixel whose history is invalid no longer restarts from ~1.1 samples (90%
  raw plus 10% of a geometrically wrong history). It gathers the **current**
  frame's raw neighbourhood — 4×4 taps at stride 2, so the same 7×7 footprint
  as 49 taps for a quarter of the fetches — edge-stopped against the current
  frame's G-buffer by depth (`exp(-Δz / max(0.06z, 0.10))`, the disocclusion
  scale) and by normal (`dot(n, n_centre)^8`), and starts from that.
- Edge-stopping uses the *current* G-buffer, not the stored history: the whole
  point is surfaces the history has never seen, and the history's normal/depth
  at those texels is whatever was there before the reveal.
- **The gather is credited with at most `PT_SPATIAL_MAX_WEIGHT` (6) samples**,
  not with its tap count. Neighbouring pixels are independent samples but not
  samples of one quantity — the signal varies across the neighbourhood — so
  crediting 16 taps as 16 samples would overstate the evidence. Measured on the
  CPU model (20 000 trials, sigma 0.25 on a 0.60 signal, all taps accepted):
  first-frame RMS falls from **0.248 to 0.064, 3.9× quieter**, while the
  credited count only claims sqrt(7) = 2.65×. Being quieter than it admits is
  the safe direction; claiming more than it delivers is not.
- **`m2` describes the noise of the estimate, not of one raw sample.** The
  à-trous reads `var = M2 - M1²` as "how noisy is this pixel", and a gathered
  pixel is an average of `spatial_samples + 1` samples, so its variance is
  divided by that count. Reporting the single-sample variance made the filter
  treat a freshly gathered pixel as ~4× noisier than it is and over-blur it —
  the edge smearing the gate warns about.
- `PT_RESET_SPATIAL`, the eleventh reset reason, in teal, so "this pixel has no
  history and was filled in from its neighbours" is visible per pixel and
  distinguishable from a soft reset.
- Cost: three fetches per tap on invalid-history pixels only. A static frame
  pays nothing. The expensive frames are the first frame after a load or resize
  (no history anywhere) and fast motion (disocclusion edges), which is exactly
  when the image is least converged.

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
   noisy scene. If noise starts to shimmer, the z thresholds (2σ/8σ) are too
   tight for that scene and should be widened, not the strength lowered.
00. **Trails:** pan past a torch in a dark room. There must be no bright band
    along the surface revealed by the pan. `GI_DEBUG_RESET` should show
    `SPATIAL` (teal) only in the strip revealed this frame, never in a band
    that persists after the camera stops.
0. **The one that matters now:** walk forward continuously for ten seconds,
   then pan continuously for ten seconds, in a torch-lit interior. The image
   must be as clean while moving as it is standing still, apart from a narrow
   band at the leading edge of the pan. If it is still noisy while moving, the
   count is not growing — check `GI_DEBUG_SPP`: it must climb to the cap within
   ~2 s of a surface appearing, whether or not the camera is moving. If it is
   smeared instead, the count is growing on pixels whose reprojection is wrong,
   and `total_confidence` is too generous.
5. The spatial fallback: walk around a corner so new surfaces come into view,
   with `RTGI_SPATIAL_FALLBACK` on and then off. On, the revealed strip should
   arrive already smooth; off, it should flash raw noise for a frame or two.
   `GI_DEBUG_RESET` marks the gathered pixels teal. Then check the cost — if
   panning loses more frame time than it did before, the fallback is running on
   more pixels than the disocclusion edges and the stride wants raising.

### P3 — Spatial denoise redesign, not re-tuning

**Goal:** remove the square bloom footprint and get Kappa-class edge preservation.

**Status 2026-11-05: increment 2 shipped — the converged-pixel bypass is now
gated on the standard error of the mean instead of the sample count. Start
here; the rest of the task list is below.**

**Increment 1 — strides and the bypass.** Two structural changes, no weight
touched (`RTGI_FILTER_PHI` is still 10.0, the B-spline weights and every sigma
are unchanged):

- **Strides now run 8 → 4 → 2 → 1, wide to narrow.** Every pass in an à-trous
  pyramid blurs, and the *last* pass is the one whose footprint the final image
  inherits. Narrow→wide put the widest, sparsest kernel last, so the image the
  player saw was the output of a ±30-texel blur. Total support is unchanged
  (±2·(8+4+2+1) = ±30), so the reorder is free: `deferred3_a…d` measured
  0.683 ms, 12.7 % of the frame (`docs/pt_perf_baseline.md`), and the tap count
  is identical. Edge-stopping is recomputed from the running centre every pass,
  so the chain is *not* order-independent: the wide passes now see the raw,
  noisy temporal centre and their edge-stops bite, whereas before the stride-8
  pass ran last on an already-smoothed centre with nothing left to reject.
- **The wide passes fade out for a converged pixel.** `sigma_l =
  PHI · sqrt(variance)`, and the variance fed to it is the **per-sample**
  variance: M2 is an EMA of sample luminance squared, so it converges to
  `E[X²]` and `variance = M2 − M1²` converges to `Var(X)`, which does *not*
  shrink as samples accumulate. Measured on a 96×96 CPU model of the temporal
  recurrence: reported sd **1.03** against a true per-sample sd of **1.10**. At
  the cap that leaves `sigma_l` about `sqrt(128) ≈ 11×` wider than the noise
  actually present in the estimate:

  | per-sample sd | reported sd | `sigma_l` | neighbour 0.10 away |
  |---:|---:|---:|---:|
  | 0.30 | 0.29 | 2.91 | accepted, weight **0.97** |
  | 0.60 | 0.58 | 5.82 | accepted, weight **0.98** |

  So for any converged pixel the luminance stop does nothing at all and the two
  wide passes run as unguarded box blurs — that is the flat, evenly lit room
  and the square glow. (An earlier table here claimed the variance *collapses*
  as the pixel converges. That was wrong; the conclusion survives, the
  mechanism did not, and the incident is recorded at the end of this section.)

**Increment 2 — what "converged" means.** Increment 1 gated the bypass on
`smoothstep(cap/4, cap, count)`. In game that traded the flat room for visible
noise, worst around lava: stray super-bright spots that flicker, plus a noise
floor that did not scale with local brightness. Both are one cause.

A light-15 emitter is `EMISSION_ANCHOR = 8.0`, and `RTGI_MAX_RADIANCE = 12.0`
sits *deliberately above* it so legitimate emitter hits do not saturate the
firefly cap. So one lava hit arrives **unclamped at ~8 against an ambient GI of
~0.3**. Among 128 samples it shifts the mean by ~0.06 — and then lands again.
For that term the effective sample count is **near 1 at any cap**, and
averaging it away across the footprint is exactly the work the wide passes were
doing. The count reads "converged" while the estimate is still moving.

That is also why the noise floor was flat rather than brightness-scaled: a
firefly's magnitude is set by the emitter, not by the local signal, so dark and
bright pixels are perturbed by the same absolute amount.

The fix is to gate on the **standard error of the mean**, `sd / sqrt(N)`, made
relative by the signal — the count's claim *and* the estimator's own verdict:

```glsl
float count_ramp  = smoothstep(cap * 0.25, cap, accum_count);
float relative_se = center_std / (sqrt(max(accum_count, 1.0)) * (center_m1 + 0.02));
float se_gate     = 1.0 - smoothstep(0.05, 0.15, relative_se);
float convergence = count_ramp * se_gate;
```

Measured on the CPU model with a compact lava pool (solid angle 0.05) and a
clean region with none, 200 frames static:

| variant | clean rmse | clean detail | clean grain | lava flicker | lava excursion |
|---|---:|---:|---:|---:|---:|
| pre-P3 (1-2-4-8, no bypass) | 0.0415 | 0.40 | 0.0293 | 0.0010 | −0.171 |
| increment 1 (count gate) | 0.0271 | 0.27 | 0.0261 | **0.0046** | **−0.001** |
| increment 2 (count × SE) | 0.0271 | 0.28 | 0.0260 | **0.0013** | −0.164 |

Increment 2 is **identical to increment 1 on clean pixels** and returns the
emitter region to baseline flicker. Increment 1 was the only configuration
whose extreme excursion was *bright* rather than dark — it kept the firefly —
and carried 4.6× the temporal flicker near the emitter. Under motion (8 frames
of history) increment 2 is also the best of the three on the emitter region
(flicker 0.0269 vs 0.0336 for increment 1 and 0.0369 for pre-P3).

Measured gate strength, which is why the bypass cannot fire on a fresh pixel:

| N | 1–32 | 64 | 128 |
|---|---:|---:|---:|
| clean | 0.000 | 0.257 | 1.000 |
| near emitter | 0.000 | 0.007 | 0.000 |

**Measured and rejected:** redefining `sigma_l` as `PHI · SE` rather than
`PHI · sd`. It is by far the best static result on clean pixels (rmse 0.0169 vs
0.0271, detail 0.60 vs 0.28, grain 0.0158 vs 0.0260) and it still returns the
emitter region to baseline flicker, but it is **worse under motion** on the
emitter region (rmse 0.3282 vs 0.2818, flicker 0.0453 vs 0.0269). M2
under-reports the variance while it is still filling — reported sd 0.366
against a true 1.096 at N = 8 — so `SE` is doubly wrong exactly when history is
short. It also redefines the edge-stop, which P3 holds fixed. Left out.

**What increment 2 does not fix.** Near a small bright emitter the wide passes
now stay on, because at 1 ray/frame and a cap of 128 the emitter term genuinely
cannot converge: spatial reuse *is* its estimator. The square glow is therefore
still present in exactly the case it was reported for. Removing it needs the
emitter term sampled properly (**P6, emitter importance sampling**) or split
into its own channel and blurred independently. Both are out of scope here.

**Two non-binding fixes, and why they matter.** Catmull-Rom history resampling
and the increment-1 bypass were both correct and both measured, and neither was
the binding constraint when it shipped. Lesson recorded: a measurement proves a
defect is real, not that it is dominant. Confirm the *symptom* moved before
treating the mechanism as settled.


**Measured and rejected: the guide/variance prepass.** The variance that guides
`sigma_l`, `sigma_n` and the bypass is each pixel's own M2, and at short history
it badly under-reports: measured sd **0.939** against a true per-sample sd of
**1.690** at N = 8, because with eight samples a heavy-tailed estimator simply
has not thrown a firefly yet. Pooling the variance over a 3×3 neighbourhood,
weighted by each texel's sample count, corrects the estimate almost exactly
(**1.576** against 1.690). It does **not** improve the image:

| N | variance | clean rmse | clean grain | lava grain |
|---|---:|---:|---:|---:|
| 8 | per-pixel | 0.0597 | 0.0292 | 0.0458 |
| 8 | pooled 3×3 | 0.0615 | 0.0294 | 0.0441 |
| 128 | per-pixel | 0.0270 | 0.0259 | 0.0420 |
| 128 | pooled 3×3 | 0.0281 | 0.0272 | 0.0419 |

The corrected variance is larger, so `sigma_l` is larger, so the filter blurs
slightly more — and the pixels whose variance was already correct pay for it.
Third incident of the same kind: the defect is real and measurable, and it is
not what the image is limited by. Do not ship it.

**Increment 3 — the upscale footprint** (task: "redesign the upscale/filter
footprint"). `sample_rtgi_smooth` was a bare `textureLod` despite the name. At
`RTGI_RESOLUTION` 0 or 1 the GI buffer is quarter or half resolution, and
bilinear cannot tell a foreground surface from the wall behind it, so it bled
indirect light around every depth silhouette and added its own 2×2 blockiness on
top of the filter's square support. It is now a joint bilateral upsample over
the 2×2 GI texels, weighted by depth and normal agreement against the full-res
pixel:

| | rmse all | silhouette band | worst bleed |
|---|---:|---:|---:|
| bilinear (before) | 0.0469 | 0.1143 | +0.344 |
| joint bilateral | 0.0167 | 0.0196 | +0.070 |

On a flat surface all four taps agree on depth and normal, so their weights are
equal and it degenerates to exactly the bilinear it replaces — nothing is lost
in the interior. It is also insensitive to its own tolerances: every relative
`sigma_z` in 0.02–0.10 and every normal exponent in 16–64 measured the same,
which is the signature of structure rather than a knob. No new buffers or
passes: the GI-resolution normal is already in the aux `.ba` (P1 state
contract) and is the same gbuffer normal `deferred4` decodes into `flat_normal`.
**Confirmed good in game.**

**Increment 4 — the edge stops are guided by the standard error** (task:
"preserve normal/depth/luminance edge stops, but feed them from the new variance
and aux contract"). `var_normalized` feeds **both** `sigma_n` and the anti-bleed
boost in the tap loop, and it is precisely the quantity a heavy-tailed estimator
destroys. Near any small bright emitter the per-sample spread saturates it at
~0.93, which floors the normal test (128 → ~16) *and* switches the corner
protection off (4.0 → 1.21). Measured on a bright wall with a dark alcove four
units behind it, both surfaces seeing the emitter so that neither luminance stop
can save it:

| `var_normalized` driven by | light leaking into the alcove | wall grain |
|---|---:|---:|
| per-sample sd (before) | **+0.5573** | 0.0710 |
| standard error (now) | **+0.0018** | 0.0734 |

99.7 % less bleed for 3.4 % more grain. The grain barely moves because on a flat
surface every tap's normal agrees with the centre, so `pow(1.0, sigma_n)` is 1
whatever the exponent is: the change only ever rejects taps *across* geometry
and never reduces averaging within a surface. At N = 1 the standard error *is*
the per-sample spread, so a fresh pixel behaves exactly as before and a moving
one cannot be starved — which is what killed the rejected `sigma_l = PHI · SE`
variant above.

This is the same correction as increment 2 applied one layer down: increment 2
fixed what the *bypass* is told, this fixes what the *edge stops* are told.


**In-game findings with `GI_DEBUG_BYPASS` (2026-11-05).**

The view was built to test one prediction: that increment 2's "the blots got
bigger and smoother" meant the wide passes had stayed on near the emitter rather
than switching off. Confirmed, and with a detail that pins the mechanism:

- **Red dots near lava on a blue field.** The wide passes are on only where the
  estimate is actually still moving, and off almost everywhere else. That is the
  SE gate working: increment 2's count gate fired at 1.000 on *every* pixel at
  the cap, this one fires on a scattered few.
- **The emitter block directly above the lava is completely blue.** This is the
  useful one. A source that subtends a *large* solid angle is hit often, so its
  samples are not rare and it carries no heavy tail — low variance, stays sharp.
  Fireflies come from sources that subtend a *small* one: rare, huge, and
  unclamped because `RTGI_MAX_RADIANCE = 12.0` sits above `EMISSION_ANCHOR =
  8.0` on purpose. So "emitter nearby" and "firefly" are not the same
  condition, and the gate does not confuse them.
- **Increment 4 (edge stops on the standard error) is confirmed good in game.**

**Ruled out by test: the sun as a firefly source.** The GI sky path is a plain
environment-map lookup (`texture(sky_map, project_sky(ray_dir))` in
`rt_gi.glsl`), which is textbook heavy-tailed: a cosine-weighted ray almost
never finds the sun disc and returns an enormous radiance when it does. Strong
hypothesis, and wrong — the user reports **no dots attributable to the sun**.
Do not build sun NEE to chase this.

**Open question: the sparse red dots on outdoor buildings and grass.** Two
candidates, and they want opposite responses:

1. *Fireflies from something other than the sun* — some emissive or very bright
   voxel reached by a rare ray.
2. *Genuinely bimodal geometry.* A grass blade or a building edge sends some
   rays at bright sky and some at dark ground, so the per-sample spread is
   legitimately large at those texels and the estimate really is uncertain. The
   wide blur is then the correct answer, not a defect.

The cheap discriminator is **stability**: fireflies flicker and migrate as new
rare hits land (the M2 EMA holds each one for ~cap frames, ~2 s at 60 fps),
whereas bimodal geometry keeps the same dots in the same places indefinitely.
A second cross-check is `GI_DEBUG_HIT` at the same moment — it names whether
the rays are escaping to sky or hitting voxels, which separates the two
candidates outright.


**Round 2 in-game findings (2026-11-05).** Four observations, one mechanism.

Every observation is `relative_se = sigma / (sqrt(N) * (m1 + 0.02))` against the
`se_gate = 1 - smoothstep(0.05, 0.15, relative_se)` threshold. Red means the
*standard error of the mean* exceeds ~15 % of the mean at full sample count. At
N = 128 that needs `sigma / m1 > 1.7`: the per-sample spread must exceed the
signal by more than half again. The view is therefore reading out the tail of
the sampling distribution, which is what it was built to do.

- **Foliage (grass, leaves).** Bimodal by construction: a cutout surface sends
  some rays at bright sky and some at dark ground, so the per-sample spread is
  genuinely large. "Completely red when seen against the sky, reddish at the
  edges against a wall, and worse when swaying" is the signature of a bimodal
  estimator, not of a firefly. The wide blur is the *correct* answer here. The
  samples converge, they just converge slowly: `sigma/m1 = 1.7` needs N > 1156
  to fall under the 0.05 threshold, about 19 s of a still camera at 1 spp.

- **Torch and lava outdoors.** Radially one would expect a symmetric halo from
  `passed_emission` (rays that pass through the emitter voxel pick up its
  emission; the solid angle shrinks as 1/r^2, which is exactly why the dots get
  sparser and more widely spaced with distance). What is observed instead is a
  one-sided ~45-degree wedge with nothing on the opposite side, stopping at the
  emitter's block. The user confirmed this tracks the sun. Two readings, and
  they are not yet separated: either it is the emitter block's sun shadow, where
  `m1` drops because the sun bounce is missing and the *denominator* inflates
  `relative_se`; or it is the sun-facing side. Both are the relative metric
  responding to `m1` rather than to a change in absolute noise.

- **Torch in a closed room: the whole lit space goes red, the direct shadows
  stay blue.** This is the important one, and it is not a filter artefact.
  Block-light bounce is not implemented (deferred), so an indoor GI sample is
  almost always ~zero. The only non-zero samples are the rare ones that hit or
  pass through the emitter voxel. So `m1` is a small average over mostly-zero
  samples while `sigma` is dominated by rare large ones: `sigma >> m1`, the
  ratio explodes, and every lit surface is flagged. The shadows stay blue for
  the opposite reason — nothing there at all, so `sigma` is ~0 too and the ratio
  collapses to 0/0.02.

  **The missing block-light bounce is therefore presenting as variance, not as
  darkness.** The estimator's *mean* is right; its tail is not. The filter
  answers by blurring, which is why torch light smears across a room instead of
  falling off — the light is real, it is just averaged over a wide footprint
  because a single sample cannot be trusted.

- **Increment 4 confirmed again, and no dots attributable to the sun** on open
  ground: with no small emitter in range the ground converges and stays blue.

**Consequence for the plan.** Every remaining red region except foliage is the
same defect: a small bright source subtending a tiny solid angle, hit rarely and
hard. Clamping and blurring both suppress it at the cost of energy or detail
(measured earlier: the clamp costs 30-40 % of indirect at 5 % solid angle). Only
sampling the emitter explicitly removes it. That is P6, and the measurement
above is the argument for doing it — the room is not "a bit noisy near lava",
it is 100 % flagged.

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

### P6.1 — Emitter NEE for the existing raw estimator (scoped)

The P6 entry above describes a full explicit path tracer with a 1024-SPP
against-a-CPU-reference gate. That is the right end state but it is not the
thing the measurement calls for, and it is not one reviewable change. This is
the narrow increment that answers the measurement, sized to land inside P6.

**What was measured.** With `GI_DEBUG_BYPASS`, every torch-lit interior is
flagged red at full sample count — the standard error of the mean exceeds 15 %
of the mean over effectively the whole lit surface area. Lava behaves the same
way. Foliage is red for a different and legitimate reason (bimodal cutout) and
is out of scope here.

**The mechanism, precisely.** `voxel_dda.glsl` splits emitters two ways:

- *Cube emitters* (lava, glowstone) terminate the ray and are shaded by
  `shade_voxel_hit`, so their emission enters `result.radiance`.
- *Thin emitters* (torch, lantern, end rod, glow lichen, chain) are tested with
  a **full-cell** shape and **do not terminate the ray**
  (`result.passed_emission += mat.emission * ray_transmittance`). The full-cell
  test was deliberate: gating on the emitter's half-cell shape produced a fake
  slab-shaped shadow and cell-aligned banding.

So the thin-emitter term is an indicator estimator: a ray either crosses the
emitter's cell and returns the whole emission, or it returns ~zero. The event
probability is the cell's cosine-weighted solid angle, ~1/r^2. In a room where
block-light bounce is not implemented, essentially every other sample is zero,
so `m1` is a small average over mostly-zero samples while `sigma` is set by rare
large ones and `sigma/m1` explodes. **The estimator's mean is correct; only its
tail is wrong.** The filter answers by blurring, which is why torch light
smears across a room instead of falling off.

**Two things that are NOT the problem, both checked this session:**

- *Not double counting with vanilla block light.* `diffuse_lighting.glsl` has no
  lightmap/block-light term at all — `direct_lighting` is analytic sun/sky plus
  `material.emission`. `passed_emission` genuinely is how torch light reaches a
  wall here, so removing it would darken torch-lit rooms rather than fix them.
- *Not the sun.* Ruled out in game.

**Constraints found, all of which bound the design:**

1. **There is no emitter list anywhere in the pack.** Nothing enumerates
   emissive voxels; `voxel_cache_generate` does not reference emission.
2. **The image budget is full.** 15 base images under PT: 3 voxel clipmap
   levels, 4 voxel cache, 8 RTGI (raw, history, accum, sky_accum, sky_history,
   filtered, filter_inter, state). `GI_DEBUG_HIT`/`GI_DEBUG_REJECT` add a 16th
   conditionally. `shaders.properties` already records that `rtgi_state_img`
   took the last free slot and that P5's specular history must free a channel.
   The voxel cache aux image has no spare channel either: `.rgb` carries the
   filtered irradiance and `.a` packs both an uninitialised flag (`a < 0.5`)
   and the sky fraction (`fract(a)`), so all four are used.
3. **LOD tricks do not reach the near field.** `mat.emission` is deliberately
   zeroed at `level > 0` so one distant light does not become a giant emissive
   cube. Dimming instead of zeroing (by the cross-section ratio `s^2`) would be
   unbiased and cut variance by `s^2`, but the clipmap's level 0 is 1:1 around
   the camera — so it does nothing for the torch across the room, which is
   exactly the case that is failing.
4. **`trace_sun_visibility` is reusable.** It is a camera-independent voxel
   march toward a light direction, already written to replace the cascade
   lookup. NEE needs exactly this shape of query, generalised from the sun's
   uniform `l_dir` to an arbitrary emitter direction.

**Options, with honest costs:**

- **(A) Emitter list + NEE + MIS.** Build a bounded emitter list during the
  voxel update pass (append with an atomic counter into a small 2D image),
  then per GI sample pick one emitter, march visibility with a generalised
  `trace_sun_visibility`, and combine with the BSDF path under MIS. This is the
  textbook fix and the only one that is both unbiased and correctly shaped: the
  emitter stays a point, the tail collapses, and the room goes blue. Cost: one
  image slot (the last one, which P5 was earmarked for, and which collides with
  the two conditional debug images), plus a build pass, plus MIS weights that
  must be right or the fix introduces bias that is harder to see than the
  noise it removes.
- **(B) Enlarge-and-dim the emitter cross-section.** Treat the emitter cell and
  its 6 face neighbours as one region, collect `emission/7` when the ray enters
  any of them. Unbiased to first order (7x the cross-section, 1/7 the value),
  variance /7, no new memory, no new pass. Cost: ~7x the voxel fetches per DDA
  step unless the neighbourhood test is gated on a precomputed proximity bit,
  and there is no spare bit in the packed voxel. The residual is spatially
  wrong in the same way blur is — light appears to leave a region one block
  wider than the emitter — at 1/7 the amplitude.
- **(C) Leave the estimator, improve the guidance.** Already measured and
  rejected in P3 increments 1 and 4: the filter cannot fix estimator variance,
  and smoothing made the fireflies more visible, not less.

**Recommendation: (A), built in three separately-gated steps** — (A1) emitter
list image + build pass with a `GI_DEBUG` view that renders the list so it can
be verified independently of the shading, (A2) NEE with the BSDF term left
untouched and the emitter term added (biased high by the double-count, but
verifiable: the room should stop flickering), (A3) MIS to remove the
double-count and make it correct. (A2) before (A3) is deliberate: it isolates
"does the tail collapse" from "are the weights right", and (A2)'s over-bright
failure mode is obvious in game whereas a wrong MIS weight is silent.

**CPU feasibility check (before any shader work).** A closed-form model of the
thin-emitter indicator estimator at N=128, emission 8.0, ambient 0.05
(`/home/user/sim/p61_nee.py`). `P(cross)` is the cosine-weighted solid angle of
the emitter's cell at horizontal distance r:

| r | P(cross) | BSDF-only mean | sigma/m1 | relSE | verdict | NEE relSE | verdict | naive (pre-MIS) error |
|---|---:|---:|---:|---:|---|---:|---:|---:|
| 1 | 0.1125 | 0.945 | 2.66 | 0.235 | RED | 0.000 | BLUE | +95 % |
| 2 | 0.0285 | 0.276 | 4.78 | 0.423 | RED | 0.000 | BLUE | +82 % |
| 3 | 0.0101 | 0.130 | 6.10 | 0.539 | RED | 0.000 | BLUE | +62 % |
| 5 | 0.0024 | 0.069 | 5.63 | 0.498 | RED | 0.000 | BLUE | +28 % |
| 8 | 0.0006 | 0.055 | 3.57 | 0.316 | RED | 0.000 | BLUE | +9 % |
| 12 | 0.0002 | 0.051 | 2.09 | 0.184 | RED | 0.000 | BLUE | +3 % |

Three things follow. The BSDF-only column reproduces the report: a torch-lit
room is red at *every* distance, and worst at 2-3 blocks, which is where a
torch actually sits in a room. NEE takes relative SE to zero at every distance.
And the naive pre-MIS variant is over-bright by 62-95 % within 3 blocks, which
is what makes A2 safe to land before A3: the error is large and obvious right
next to the torch, whereas a wrong MIS weight would be silent.

Caveat stated up front: the model has static visibility, so it shows the
variance NEE *removes*, not the variance it leaves behind. The residual is the
visibility term (binary, and it is what makes a moving occluder flicker) plus
the ambient's own noise. The conclusion that carries is the size of the
collapse, not the exact value zero.

**Blocking decision:** (A) needs the last image slot, which P5's specular
history was reserved for, and which `GI_DEBUG_HIT`/`GI_DEBUG_REJECT` borrow.
Either P6.1 goes first and P5 must free a channel later, or the debug views
become incompatible with P6.1.

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