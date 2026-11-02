# Photon RT Re-Audit

**Date:** 2026-11-02 · **Scope:** the RT/RTGI lighting pipeline as it stands after turn 16
(typed slab registry completion, full-cell emitter collection, near-field ramp) plus this
turn's changes (emitter brightness raise, short-range probe-bounce floor, plant
pass-through additions).

**Method:** static review of the shader tree and its check harness only. No shader was
executed on a GPU in this audit. Per project rule, every finding below is treated as
*possible* until reproduced in game; items marked (user-reported) were observed by the
tester in actual runs.

**Files reviewed:** `shaders/include/lighting/rt/` (`voxel_dda.glsl`, `rt_gi.glsl`,
`rt_reflections.glsl`, `ddgi.glsl`, `rt_ao.glsl`, `voxel_samplers.glsl`),
`shaders/include/lighting/voxel/` (`voxel_update.glsl`, `voxel_palette.glsl`,
`voxel_storage.glsl`, `voxel_constants.glsl`, `light_colors.glsl`),
`shaders/program/rtgi/*`, `shaders/include/lighting/diffuse_lighting.glsl`,
`shaders/block.properties`, `shaders/settings.glsl`.

---

## A. Bug classes with user-confirmed evidence

1. **Bloom: square glow around bright regions — OPEN (user-reported, three fix
   attempts reverted).** The artifact is the à-trous reconstruction kernel footprint
   (±16 buffer texels per pass) scaling with `RTGI_RESOLUTION`; it was proven to track
   buffer texel size, not scene geometry. All weight-side tunings (Gaussian, φ, σ cap)
   were judged "changed nothing" and reverted to the original exponential weight
   (`φ = 10`). Root cause remains: only a kernel/stride redesign could change the
   footprint, and that has not been attempted. **Do not re-tune weights.**
2. **Unlisted blocks become opaque full cubes (user-reported twice).** Any block with
   no matching `block.properties` entry gets `mc_Entity = -1` → remapped to generic
   solid 111 → forced CUBE: full-cell occlusion, no emission. This produced the
   "not-full blocks cast shadows" slab reports (turn 15/16: 42 of 103 vanilla slab
   types were missing) and the dark light-blocking plant cells (this turn: nether
   vines, hanging roots, small dripleaf, etc.). The vanilla slab registry is now
   complete (103/103 bottom and top) and several plant families were added, but **the
   class of bug is structural**: every block not named in `block.properties` — modded
   blocks, future vanilla blocks — silently degrades to an opaque cube.
3. **Thin-emitter half-cell light gating (user-reported: torch over-brightness,
   fake shadows next to emitters).** Emitters like torches are stored with a sniffed
   half-cell shape; emission was only collected when a ray crossed that half, cutting
   the glow along hard cell-aligned bands and starving directions behind/underneath.
   Fixed this audit cycle by collecting over the whole emitter cell for pass-through
   emitters. *Residual weakness:* the stored shape itself is still a per-vertex
   geometric guess settled by `imageAtomicMax` (works only because flags/id tie first);
   probe relocation (`voxel_shape_contains`) therefore sees a torch cell as a top or
   bottom half depending on which faces were drawn.
4. **Emitter near-field falloff is heuristic, not physical (user-reported: too bright
   at contact, cliff to the next block, then "dimmer than it used to be").** Current
   state: per-ray ramp `clamp(0.65 + 0.35·d, 0.65, 1)` on emitter hits plus
   `EMISSION_ANCHOR` raised 6 → 8 (block sources only; sun/moon untouched). This is a
   shape-and-level compromise, not Minecraft light-level decay: contact ≈ 0.65–0.8× of
   the one-block level, mid-field now brighter than the historical baseline. If the
   tester reports "still wrong", the two knobs are the ramp floor and the anchor —
   nothing else should move.

## B. Weaknesses and risks in the current pipeline

### Transport / second bounce
5. **`probe_gate` floor (new, watch closely).** `rt_gi.glsl` fades the DDGI second
   bounce in with distance; it previously went to **zero** below 1 block, which
   (user-reported) killed wall-to-ledge bounce exactly at contact range — a lit wall
   would not light the rock beside it. The gate now floors at 0.45. Risk: this floor
   re-admits roughly half of the probe churn that the original fade fixed ("DDGI light
   keeps showing up and fading out" at close range). If flicker returns, raise the
   floor toward 0.6 rather than removing it.
6. **Probe irradiance is isotropic** (`ddgi.glsl` deliberately has no directionality
   fudge after 20× brightness swings were observed with one) — all shape in the GI
   comes from the per-pixel path, which runs at `RTGI_RAY_COUNT = 2` rays/pixel by
   default at `RTGI_RESOLUTION = 1` (half). The denoiser and temporal accumulation
   therefore carry most of the load; probe-only surfaces (anything past the RTGI
   resolution) rely on a 32-ray/hysteresis-0.8 cache that refreshes every 16 frames.
7. **Probe window edge:** 32³ probes at spacing 2 → 64-block world window; probes
   outside or stale after camera moves contribute zero with a `coverage_fade` ramp —
   known to draw soft camera-locked brightness lines; relocation can zero a probe
   that finds no air in 26+12 candidates, leaving a dim hole the trilinear blend
   spreads (partially mitigated by shape-aware relocation).
8. **Full-cell emitter collection over-estimates thin sources:** a ray that clips the
   emitter cell but misses the rod still collects full emission. Glow therefore has a
   slightly boxy, over-wide halo at very close range; acceptable trade against the
   half-cell banding bug, but it is not physically tight.

### Occlusion / geometry
9. **Corner stairs are approximated:** inner/outer corner stairs keep their facing's
   straight box — one arm is open (corners only). Documented as intentional after the
   turn-12 flooding fix, but light can still corner-leak through stair corners.
10. **The 4-bit shape field is full** (0–15: cube, slabs, fence, plant, glass, other,
    cover, 8 stair facings). Any new partial-block geometry requires widening the
    packed layout (`voxel_storage.glsl`, packing test, all readers) — a redesign, not
    an addition. Block ids: 7-bit, currently max 113, next free 114.
11. **`imageAtomicMax` determinism depends on pack ordering:** id (high bits) > flags
    > shape (bits 19–22). Geometric sniffing (fences, beds, emitter models, any
    unlisted half-height block) writes conflicting shapes from different faces; the
    winner is whichever shape value is numerically larger, and faces hidden by
    backface culling never write at all. **Typed ids are the only deterministic
    path** — the reason `block.10112/10113` exist and the reason the id-111
    fall-through sniff was deliberately *not* enabled (it would half-open unlisted
    stairs and reopen the closed-staircase flooding class).
12. **Modded stairs/slabs have no state filters** — they stay full cubes
    (conservative occlusion, over-dark rather than leaky). Fine today; wrong-looking
    if the tester builds a modded staircase.
13. **`trace_any_hit` (probe segments, AO) skips translucent-flagged cells**
    (`is_solid && !is_translucent`) — glass, water, leaves, and the plant pass-through
    ids don't occlude probe visibility or AO. Correct for leaks, but means foliage and
    glass cast no contact shadow of their own.

### Brightness / color
14. **Emitter radiance model:** `get_voxel_light_color` (peak-normalized palette tint)
    × `EMISSION_ANCHOR` × `EMISSION_STRENGTH` × vanilla lightmap response curve
    (`voxel_light_response`). Raising the anchor to 8 pushes light-15 emitters to the
    firefly cap boundary: `RTGI_MAX_RADIANCE` was raised 8 → 12 in step. At
    `EMISSION_STRENGTH > ~1.5` (slider) the product clips at 12 again — silent cap,
    not a visible error. Sun/moon/sky radiance are separate terms and were not
    touched.
15. **Coarse clipmap levels zero emission** (`level > 0 → mat.emission = 0`,
    forced CUBE): distant torches are occupancy-only. No colored far-field glow; a
    brightness pop is possible when a light crosses the fine/coarse boundary.
16. **Sky gate × receiver skylight** (`clamp01(receiver_skylight*10)`): strong
    leak defense for sealed interiors, but interiors with genuinely near-zero vanilla
    skylight never receive sky bounce even when a window physically opens — deep
    rooms can read darker than the traced light through the window suggests.
17. **Sun visibility march:** fixed 48 steps / 48-block budget in voxel space —
    long-range self-shadowing is approximate; raster soft shadows cover the near
    field. Camera-independent (fixed earlier camera-locked artifacts) but penumbra
    growth at distance is inherited from the raster cascade, not traced.

### Denoise / temporal
18. **À-trous luma weight is wide (`φ = 10`, exponential, uncapped)** — by design
    after the bloom revert, but at `RTGI_RAY_COUNT = 2` high noise plus a wide
    filter means color can bleed across high-contrast edges when variance
    underestimates. Variance clipping is deliberately absent (banned after earlier
    trials).
19. **Temporal history = 32 frames with bilinear history resampling and soft
    disocclusion** — camera-motion light trails are accepted behavior (tester
    decision). `RTGI_HISTORY_FRAMES` is the only dial.

### Process
20. **Validation is static.** `tools/shadercheck/run_checks.sh` covers packing math,
    properties lint, compile matrices, DDA/energy reference math, clipmap/boundary/AO/
    debug wiring — no golden-frame or in-game comparison. Every visual fix so far has
    been confirmed only by the tester's screenshots; regression risk concentrates
    exactly where the reports come from (emitter brightness, partial-block occlusion,
    short-range bounce).

## C. Deliberately not done (with reasons)

* **Bloom kernel redesign** — user-gated; needs a new, demonstrably different angle.
* **id-111 geometric slab sniff fall-through** — would half-open unlisted/modded
  stairs (flooding regression class); typed lists cover all vanilla slabs instead.
* **Physically modeled emitter decay (true 1/d² with MC light-level shaping)** — the
  ramp + anchor is intentionally simple and user-tunable; a physical model was judged
  out of scope after three rejected tuning rounds.
* **Chorus plants** — listed; treated as-is. Full moss blocks remain opaque
  (correct: they are full cubes).
* **N4 investigation** — deferred by user; not reopened.
* **Camera-motion light trails** — accepted as normal SEUS-like behavior.
