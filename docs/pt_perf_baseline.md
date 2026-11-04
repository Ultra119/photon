# First in-game GPU profile — 2026-11-04 (P0 build)

**Build:** `arena/d99fd523-photon` @ `e45b545` (P0: PT-only contract)
**Tool:** Viewfinder, 10 frames, 44 passes, GPU timings
**Scene / resolution / TAAU scale / GPU / driver:** *not recorded* — see the gaps below

Sum of all 44 timed passes: **5.38 ms GPU per frame** (≈186 FPS if the frame were
purely GPU-bound and nothing else cost anything). Nothing here is directly
comparable to the earlier 100–120 FPS user report yet: no FPS, resolution or
scene was captured alongside it.

---

## 1. Pass map

Mapped from `shaders/world0/*` (the `deferred<N>_x.csh` files are the compute
programs):

| Profiler entry | Fragment program | Compute programs dispatched in the *same* pass | Time | Share |
|---|---|---|---:|---:|
| `deferred/deferred` | `d0_sky_map` | `deferred_a` voxel_cache_reproject · `deferred_b` voxel_cache_generate · `deferred_c` voxel_cache_flip · `deferred_d` voxel_cache_filter | 1.240 ms | 23.1 % |
| `deferred/deferred1` | `d1_clouds` | `deferred1_a` rtgi_trace | 1.430 ms | 26.6 % |
| `deferred/deferred2` | `d2_clouds_upscaling` | `deferred2_a` rtgi_temporal | 0.115 ms | 2.1 % |
| `deferred/deferred3` | `d3_ao` (RT contact AO) | `deferred3_a…d` rtgi_filter ×4 | 0.683 ms | 12.7 % |
| `deferred/deferred4` | `d4_deferred_shading` | — | 0.761 ms | 14.2 % |
| `composite/composite` | `c0_vl` | — | 0.056 ms | 1.0 % |
| `composite/composite1` | `c1_blend_layers` | — | 0.065 ms | 1.2 % |
| `composite/composite4` | `c4_taa_exposure` | — | 0.179 ms | 3.3 % |
| `composite/composite5…18` | bloom chain | — | ~0.13 ms | 2.4 % |
| `composite/composite19` | `c19_color_grading` | — | 0.057 ms | 1.1 % |
| `composite/composite21` | FXAA | — | 0.049 ms | 0.9 % |
| `prepare/prepare` | `p0_clouds_prep` | — | 0.112 ms | 2.1 % |
| `final` | final (TAAU resolve, debug views) | — | 0.055 ms | 1.0 % |
| MC passes | terrain, shadow, entities, hand, rain, sky, block entities | — | ~0.53 ms | 9.9 % |

## 2. The important structural finding: the PT cost is hidden

**No `deferred_a` / `deferred1_a` / `deferred3_a…d` entry appears in the log, and
that is expected, not a bug.** Verified in the Iris source at the version this
pack targets (`common/src/main/java/net/irisshaders/iris/pipeline/CompositeRenderer.java`):

- Each pass index gets **one** debug group named after either the fragment
  program (`pass.name = source.getName()`, e.g. `deferred1`) or, when there is
  no fragment program, the first compute program (`ComputeOnlyPass`).
- All compute programs belonging to that index (`pass.computes`) are dispatched
  **inside that same group**, before the fullscreen quad:
  `GLDebug.pushGroup(…, compositePass.name)` → `computeProgram.dispatch(…)` →
  `memoryBarrier(…)` → `drawElements(6)`.

So the entire PT chain is billed to four entries it shares with unrelated work:

| PT stage | Billed to | Mixed with |
|---|---|---|
| irradiance cache reproject / generate / flip / filter (4 dispatches over `RT_CLIPMAP_SIZE³`) | `deferred` | sky map |
| `rtgi_trace` (raw estimator) | `deferred1` | clouds |
| `rtgi_temporal` | `deferred2` | clouds upscaling |
| `rtgi_filter` ×4 (à-trous 1/2/4/8) | `deferred3` | RT contact AO |

Consequence for the plan: **we cannot currently tell what the PT path costs.**
P2 (temporal rewrite) and P3 (denoise redesign) both change the cost of exactly
the stages hidden inside `deferred1`/`deferred2`/`deferred3`, and P1 adds
channels and passes to them. Budgeting them against this profile is guesswork.

## 3. How to isolate the PT cost (differential measurement, no code changes)

Because the four chains scale differently, two extra 10-frame profiles at the
same camera position split them apart:

| Run | Settings | What the delta tells you |
|---|---|---|
| A | `RTGI_RESOLUTION=0`, `RT_CLIPMAP_SIZE=64` | cheapest PT configuration |
| B | `RTGI_RESOLUTION=1` (default), `RT_CLIPMAP_SIZE=64` | B − A = screen-area-bound cost: `rtgi_trace` + `rtgi_temporal` + `rtgi_filter` at quarter → half res |
| C | `RTGI_RESOLUTION=1`, `RT_CLIPMAP_SIZE=128` | C − B = volume-bound cost: the four irradiance-cache passes (64³ → 128³ is 8× the cells) |

`deferred/deferred` between A and C gives the cache cost directly;
`deferred/deferred1|2|3` between A and B gives the trace/temporal/filter cost.
A fourth run at `RTGI_RESOLUTION=2` (full res) prices the Extreme tier.

Also worth capturing next time, because none of it is in this log:

- **FPS and frame time** (F3) at the same moment, so GPU ms can be reconciled
  with the frame budget — 5.38 ms of GPU work against a 100–120 FPS report
  means the frame is limited by something the profiler does not see (CPU,
  vsync, or a pass Viewfinder does not time).
- Resolution and `TAAU_RENDER_SCALE` (internal render resolution drives every
  relative image).
- The scene: the canonical set in `docs/testing/reference_scenes.md`, or at
  least "same spot, same time of day, same weather" across runs.
- Whether `GI_DEBUG` was off and which profile/tier was selected.

## 4. What the numbers suggest anyway

- **Clouds and the sky map dominate the top two entries** (`deferred1` 1.43 ms,
  `deferred` 1.24 ms) — but both also hide PT compute, so "clouds are the
  bottleneck" is not yet a safe conclusion. Run A vs C settles it.
- `deferred3` (683 µs) covers contact AO *and* all four à-trous filter passes.
  P3 wants more, wider passes (32→16→8→4→2). If the four current passes are
  already a large share of 683 µs, the redesign needs a cheaper early-out —
  which is exactly what the "converged-pixel bypass" in P3 is for.
- `deferred4` (761 µs) is composition only; it will grow when P4 evaluates SH
  against the normal-mapped normal and when P5 adds a specular upscale.
- Nothing here is close to the 16.6 ms budget of 60 FPS. There is headroom for
  reconstruction work — the open question is how much of that headroom the PT
  chain is already consuming.

## 5. Gaps to close on the next test run

1. FPS / frame time alongside the profile (section 3).
2. Differential runs A/B/C.
3. Matched screenshots: same scene/time/settings for Photon PT tier vs Kappa
   v18.8 — still the outstanding P0 gate item.
4. A first-frame convergence capture: screenshot at frames 1, 2, 5, 10, 30, 120
   from a standstill, then again after a 90° camera pan. That is the visual gate
   for P2 and it needs a P0 "before" set to compare against.
