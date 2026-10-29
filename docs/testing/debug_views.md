# GI debug views

How to look at what the GI pipeline is actually doing, instead of guessing from
the shaded image.

## Enabling

Two settings, both under **Settings → Developer** (also listed in `sliders`, so
they can be driven from Iris's slider list):

| Setting | Value |
|---|---|
| `DEBUG_VIEW` | `GI Buffers` |
| `GI_DEBUG` | the view you want |

`DEBUG_VIEW` already existed and selects between the generic sampler view, the
histogram, the weather debug overlay and this one. `GI_DEBUG` is new and picks
which GI buffer is displayed.

The views require **Ray Traced GI** to be enabled. With it off the screen turns
flat magenta — that is a deliberate signal, not a rendering bug: the buffers do
not exist, so there is nothing to display.

## Status

| | |
|---|---|
| Implemented | all 10 values of `GI_DEBUG` |
| Statically verified | `tools/shadercheck/gi_debug_test.py` — 34 assertions: each view reads exactly its documented buffers, `GI_DEBUG_OFF` reads none, each debug image is written only by its owning pass, and neither image is allocated when off |
| **Not verified** | **that the images look right on a GPU.** No screenshots exist for these views. They must be captured in-game (see "Capturing reference images" below) before the stage can be called visually complete. |

This matters: a view that compiles, reads the correct buffer, and still renders
something unreadable would pass every automated check in this repository.

## The views

### Raw · `GI_DEBUG_RAW`

This frame's traced radiance, before temporal accumulation. Tone-mapped
(Reinhard in linear space, then sRGB).

**Healthy:** visibly noisy at low ray counts. That noise is the input the
temporal and spatial filters exist to remove; a smooth "raw" view means
something upstream is already filtering and the filter chain is doing less work
than you think.

### History · `GI_DEBUG_HISTORY`

The temporally accumulated radiance — whatever the temporal pass wrote this
frame. The pass ping-pongs between two images, so this view reads `rtgi_accum`
on even frames and `rtgi_history` on odd ones, which is exactly what the next
frame will read back.

**Healthy:** markedly smoother than `Raw` while the camera is still. If it looks
identical to `Raw`, accumulation is not happening (check `history_available` in
the History Rejected view).

### Filtered · `GI_DEBUG_FILTERED`

The buffer `deferred4` actually lights surfaces with. This is the view to
compare against `History`: the difference between them is everything the
à-trous filter is doing.

### Hit Source · `GI_DEBUG_HIT`

Per-ray estimator provenance, written by `rtgi_trace.csh` as the fraction of
rays resolved by each path:

- **Red** — screen space (SSGI)
- **Green** — voxel DDA
- **Blue** — escaped to sky

Proportions, not raw counts, so `RTGI_RAY_COUNT` does not change the colours.

**Healthy:** red dominates on nearby, on-screen geometry and falls off with
distance as the screen-space ray runs out of screen; green takes over past that
point. Green everywhere, including up close, means SSGI is failing; red
everywhere at long range would mean rays are being wrongly resolved in screen
space. This is the first objective measure of the hybrid split.

### History Rejected · `GI_DEBUG_REJECT`

The temporal pass's actual decision, recorded where the decision is made rather
than re-derived:

- **Red** — history discarded (disocclusion or depth mismatch)
- **Yellow** — history accepted
- **Black** — no history to compare against (reprojected off-screen)

**Healthy:** solid yellow on a still camera. Panning the camera should show a
red band on newly exposed surfaces, tracking the disocclusion. Persistent red on
static geometry means the depth tolerance is too tight and the image will
never converge.

### Voxel ID · `GI_DEBUG_VOXEL_ID`

The voxel at the surface the camera sees, coloured from a 16-entry palette keyed
by block ID, with a fixed palette rather than a hash so that adjacent IDs are
always distinguishable.

- **Black** — air (the volume has no geometry there)
- **Dim white** — a light-only voxel (`block_id == 0`, `block_light > 0`)
- **Magenta** — outside the voxel volume

**Healthy:** solid surfaces are solid colour; there are no black holes inside a
wall. Holes reveal exclusions in `should_voxelize` directly (for example water,
which is deliberately not voxelized).

Note that this is what makes "GI occluders are missing here" diagnosable: if a
wall shows black in this view, rays pass through it in every other view too.

### Voxel Light · `GI_DEBUG_VOXEL_LIGHT`

- **Red** — block light (0–15 quantised to 0–1)
- **Green** — sky light (0–15 quantised to 0–1)

**Healthy:** a smooth gradient away from lamps (red) and a sky-light gradient
away from openings (green). A hard step in the middle of open air means the
light field was never propagated there.

### Voxel Albedo · `GI_DEBUG_VOXEL_ALBEDO`

The colour the voxel stores, decoded from RGB555 and gamma-encoded.

**Healthy:** red wool reads red, grass reads green, stone reads grey. Everything
grey, or colours that are systematically wrong, means the palette fallback is
being hit and `block.properties` / `light_colors.glsl` is not matching the
blocks in the scene. Quantisation to 5 bits per channel is expected and shows
as slight banding in smooth gradients — that is the storage format, not a bug.

### Convergence · `GI_DEBUG_VARIANCE`

Diverging colour map of the disagreement between this frame's raw estimate and
the accumulated history:

- **Grey** — they agree
- **Red** — the new estimate is brighter
- **Blue** — darker

**This is not a variance.** This pack has no variance estimate (plan item B9);
there is no per-pixel second moment stored anywhere, so a variance view would
have to invent one. What is shown is *temporal spread*, which answers the
practical question behind the convergence criterion ("is the estimator settling,
or does it depend on where the camera is?") for a static camera.

**Healthy:** settles toward grey within a few seconds of a still camera. Colour
that persists no matter how long you wait means the estimator is view-dependent
and will never converge — which is precisely the feedback-loop symptom (B1) that
Stage 3 exists to remove. For population statistics use `DEBUG_VIEW_HISTOGRAM`,
which samples the actual image.

## What is not implemented

- **Per-pass GPU timings.** GL timer queries are not exposed to shader packs, so
  a pack cannot measure its own pass cost. Use Iris's built-in profiler (the
  Spark/Iris debug screen) instead. Adding a fake in-shader timer that reads
  `frameTimeCounter` would measure frame rate, not pass cost, and would be
  mistaken for the latter.
- **Variance.** See above.
- **Screenshots.** See below.

## Capturing reference images

Once per release, with the canonical scenes from `RTGI_IMPLEMENTATION_PLAN.md`
§8.3:

1. Load the scene, stand still, and let the pack settle for ~120 frames.
2. Set `DEBUG_VIEW = GI Buffers`, then step through every `GI_DEBUG` value.
3. Save each as `docs/testing/img/gi_debug_<view>.png`.
4. Repeat the Convergence and History Rejected views while panning, since those
   two are only meaningful in motion.

The white-room scene is the reference for `Hit Source` and `Voxel Albedo`; a
sealed cave is the reference for `Voxel Light` (it should read zero green).
