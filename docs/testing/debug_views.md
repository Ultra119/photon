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
| Verified in game | `VOXEL_ID` renders the voxel volume correctly — stone terrain appears as palette index 4 (0.25, 0.45, 0.95), air is black. First screenshot pass |
| **Not verified** | that the remaining views read correctly. Screenshots are still needed for Raw/History/Filtered/Hit/Reject/Convergence and for `VOXEL_LIGHT` / `VOXEL_ALBEDO` |

### First field run: the pack failed to load

The first attempt to load this in game did not reach the shaders at all. The
`image.rtgi_hit_img` / `image.rtgi_reject_img` declarations were missing their
pixel-type field, so Iris read the following fields one position to the left,
tried to parse `1.0` as an integer width, and aborted the whole pack:

```
Failed to find pixel type FALSE
java.lang.NumberFormatException: For input string: "1.0"
```

### Second field run: the voxel views flickered

`VOXEL_ID`, `VOXEL_LIGHT` and `VOXEL_ALBEDO` flickered and were hard to tell
apart. Two separate causes:

**1. The flicker was a real bug, and it was mine.** These views reconstruct the
surface position from depth and look up the voxel cell containing it. That
reconstruction passed `handle_jitter = true`, but `final.fsh` runs *after* TAA
has resolved, so its pixel centres are no longer jittered — passing `true`
subtracted the current frame's jitter offset, moving the reconstructed point by
a fraction of a pixel every frame. Harmless for a smooth quantity; fatal for
`floor()`-quantised cell coordinates, where the sample flips between two cells
on alternate frames. All three views shared that path, which is why all three
failed identically. Fixed: `handle_jitter = false`, and the depth fetch and
projection now go through `taau_framebuffer_uv` / `taau_projection_uv` so the
views also stay correct under TAAU.

**2. "Similar across modes" had a mundane explanation.** `VOXEL_ID` paints stone
as palette index 4, which is `(0.25, 0.45, 0.95)` — and the voxelizer remaps
unassigned terrain to stone, so most of a landscape is that one blue. The black
regions are air. `VOXEL_LIGHT` writes `(block_light, sky_light, 0)` and can
therefore **never contain blue**; if you see blue in what should be the light
view, the option has not switched. To make that unambiguous, each view now
stamps a solid 24×24 swatch in the bottom-left corner in a colour unique to that
view, so a screenshot identifies itself:

| View | Swatch |
|---|---|
| Raw | orange |
| History | cyan-blue |
| Filtered | green |
| Hit Source | magenta |
| History Rejected | white |
| Voxel ID | cyan |
| Voxel Light | yellow |
| Voxel Albedo | grey |
| Convergence | red-orange |

`gi_debug_test.py` now also asserts these nine colours are all distinct, since
adding a view by copying an existing branch would otherwise silently give two
views the same identity.

### Third field run: walls still flicker — undiagnosed

Reported after the `handle_jitter` change: flicker *changed* but did not stop;
walls flicker, the carpet floor reads black.

What was checked and ruled out:

| Hypothesis | Verdict |
|---|---|
| `final.vsh` jitters `uv` | **No** — `uv = gl_MultiTexCoord0.xy`, unjittered |
| Something clears the voxel image each frame | **Yes**, but by design: `image.voxel_img` has `clear = true` (field 5), so the volume is rebuilt every frame from the shadow pass |
| My lookup coordinate is the only problem | **No** — both `handle_jitter` values flicker |

The `handle_jitter = false` change has been **reverted**. It was made on
reasoning I had not verified, it contradicted every other depth reconstruction
in the pack (`rtgi_trace`, `rtgi_temporal`, `d3_ao`, and the `DISTANCE_VIEW`
block in `final.fsh` itself all pass `true`), and it did not fix anything.

The remaining likely cause is structural rather than a bug in these views: the
voxel image is cleared every frame and repopulated only by whatever geometry the
shadow pass draws that frame. A view that samples it directly is therefore
showing unfiltered per-frame data, and any frame-to-frame variation in
shadow-pass coverage appears as flicker with nothing to smooth it. That is plan
item B3 (voxel coverage = shadow-pass draws only) and B10 (vertex-stage
voxelization race), both scheduled for Stage 4. **This is a hypothesis, not a
diagnosis** — it has not been confirmed.

Cheap test that would distinguish the two candidates, if you have a moment:

1. Stand perfectly still, don't touch the mouse, and watch one wall for ~10s.
   *Stable* ⇒ the content is fine and something view-dependent is at play
   (B3). *Still flickering* ⇒ content varies per frame with no camera motion
   (B10, the unsynchronised occlusion test in `voxel_update.glsl`).
2. Then rotate the camera slowly. New flicker/streaming ⇒ B3 confirmed.

**Also fixed:** the Hit and Reject views were unreadable binary noise at
`RTGI_RAY_COUNT=2` (each texel is 0/0.5/1 per channel). They are now box-filtered
3×3 for display only. The buffer itself is untouched — this is a viewing aid,
not a change to the data.

Fixed. `properties_lint.py` now validates every `image.*` directive against
Iris's real grammar, so this class of error fails the checks instead of failing
at load.

A second, quieter bug was found in the same review and fixed before re-testing:
the debug images were declared at full resolution while the trace pass only
writes the lower `RTGI_RESOLUTION` fraction of them (`workGroupsRender` is
0.25 / 0.5 / 1.0). Nothing would have failed to load -- the unwritten region
would simply have displayed uninitialised memory. The declarations now sit
inside each `RTGI_RESOLUTION` branch, and the lint re-preprocesses the property
file once per `GI_DEBUG` value specifically so that a size declared only in a
non-default branch is still checked. Worth stating plainly because of how it was missed: **1,287 compiling
cases said nothing about it** — none of them look at `shaders.properties`.

If you hit a load error again, run `python3 tools/shadercheck/properties_lint.py`
first; it reports the offending line number and which field is wrong.

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
