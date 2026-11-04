# P0 baseline record

**Branch:** `arena/d99fd523-photon` · **Baseline commit:** `f1df4b7` · **Date:** 2026-11-04
**Active roadmap:** [`docs/PT_ONLY_PLAN.md`](PT_ONLY_PLAN.md) · **Image budget:** [`docs/pt_image_budget.md`](pt_image_budget.md)

Record every branch and commit in later gates against this file. P0 is the
point the PT-only contract starts from; P1–P7 are measured against it.

---

## 1. Branch and branch-decision

| Item | Value |
|---|---|
| Active branch | `arena/d99fd523-photon` (Arena session branch) |
| Baseline commit | `f1df4b7` ("Remove uneeded docs") |
| Remote | `https://github.com/Ultra119/photon.git` |
| Working tree at P0 start | clean |

**Force-pushed performance commit `4dd4391` ("Reduce stock probe-update and
ray-tracing workload", on remote `arena/ce39d2b2-photon`): not ported, not
cherry-picked, not merged.** The user instructed this session to skip the
decision item, so the plan's option 3 applies: `4dd4391` stays an *external
performance reference only*. It was never fetched into this session's branch.

Consequences to keep in mind:

- `RTGI_RAY_COUNT` is `1` in this tree's `settings.glsl` (the reduced value is
  already in the default), while `RTGI_PROBE_*` no longer exist at all — the
  DDGI probe cache was replaced by the voxel irradiance volume, so the parts of
  `4dd4391` that touched probe rays and hysteresis do not apply to this tree
  verbatim.
- If a later gate wants the commit, it has to be re-based against this tree by
  hand and re-measured. Do not assume the two trees are identical.

## 2. Static baseline — green

Reproduce with a `glslang` binary on `PATH` (see
[`tools/shadercheck/README.md`](../tools/shadercheck/README.md)):

```sh
export GLSLANG=/path/to/glslang
export NO_INJECT=shadowtex0
./tools/shadercheck/run_checks.sh
```

Result at the P0 baseline (`EXIT=0`, every stage green):

| Check | Result |
|---|---|
| `voxel_packing_test.py` | 1000 randomized pack/unpack round trips OK; atomic priority OK |
| `properties_lint.py` | OK — 327 keys, 3 known duplicate(s), 15 RTGI menu options checked |
| `image_budget.py` (new) | OK — 14 images per tier, 15 with a debug view, limit 16 |
| `matrix_compute.py` | 357 cases, 0 failures |
| `matrix.py` | 1053 cases, 0 failures |
| `dda_test.py` | 16/16 Stage 5–8 unit tests PASSED |
| `clipmap_test.py` | OK — toroidal coords, nested seams, single-hit energy, image budget |
| `rt_boundary_test.py` | OK — contact AO, traced indirect, direct light, environment, emission |
| `ao_dispatch_test.py` | OK — 12 cases, one voxel estimator per world |
| `gi_debug_test.py` | OK — 38 cases, one source per view, no allocation and no writes when OFF |

Three pre-existing failures were fixed to reach green; they were *not* caused
by P0, they were hidden behind the properties-lint failure that aborted the
script before them:

1. **Properties lint, 21 errors.** The lint still required the removed DDGI
   probe options (`RTGI_PROBE_RAYS`, `RTGI_PROBE_HYSTERESIS`,
   `RTGI_PROBE_SPACING`) and the removed `ddgi_*` images, and it rejected the
   macro-valued absolute image dimension `RT_CLIPMAP_SIZE` that Iris expands
   before parsing. Fixed in `properties_lint.py`: the required menu list and the
   expected image list now match the voxel irradiance volume, and
   `resolve_dimension()` follows the same macro expansion Iris does.
2. **RT boundary test, 2 errors.** It looked for `sample_ddgi_irradiance`,
   which no longer exists (renamed to `sample_voxel_cache_irradiance`), and it
   split the source on the exact comment string `// Indirect lighting: RT
   only.`, which P0 reworded. Fixed: the anchor is now the stable prefix
   `// Indirect lighting:` and the check names the current cache sampler.
3. **Dead language strings.** 20 dead options (`RAYTRACED_GI`, `RTGI_TRACER`,
   `RTGI_SSGI_LOCAL_LIGHT_SCALE`, `SSR_*`, `SHADER_AO`-era leftovers, …) were
   still translated in seven of the nine `shaders/lang/*.lang` files. Removed,
   and the dead-option check now scans every shipped translation, not just
   `en_US`.

## 3. Frame-rate baseline — user-measured, not reproduced

**First in-game GPU profile exists:** 2026-11-04, Viewfinder, 10 frames,
5.38 ms GPU across 44 passes, on this P0 build — see
[`docs/pt_perf_baseline.md`](pt_perf_baseline.md). It is GPU time only: no FPS,
resolution, scene or CPU frame time was captured with it, so it does not
replace the table below and cannot yet be reconciled with it. The structural
finding from that profile is that Iris bills every PT compute dispatch to the
fragment pass of the same index, so the PT chain's cost is currently invisible
in any per-pass profile; the differential measurement to expose it is written
up in that document.

No GPU or Minecraft instance exists in this sandbox, so the numbers below are
the user's own measurements and **not** matched, reproduced or verified here.
Record GPU, driver, scene, resolution scale and settings next to them before
using any of them as a hard gate.

| Build | Resolution scale | Reported FPS | Source |
|---|---|---:|---|
| Photon stock settings, before the workload reduction | 1.0 | 60 | User report, 2026-11-03 |
| KappaPT v18.8 | matching test scene | 90 | User report, 2026-11-03 |
| Photon after the force-pushed workload reduction | 1.0 | 100–120 | User report, 2026-11-03 |

The product conclusion does not depend on the exact figures: Photon now runs at
or above Kappa's reported frame rate, so a second, cheaper lighting mode buys
nothing worth maintaining. The remaining problem is reconstruction quality, not
throughput.

**Captures:** none. Matched screenshot pairs (Photon PT tier vs Kappa, same
scene/time/settings) are still outstanding and are the first thing P1 should
produce — every later visual gate in `PT_ONLY_PLAN.md` compares against them.

## 4. State of the shipped PT path at this baseline

| Area | State |
|---|---|
| Lighting modes | one: PT. No RT mode, no OFF/HYBRID, no GI-off placeholder profile |
| Profiles | five PT quality tiers: `low`, `medium`, `high`, `ultra`, `extreme` |
| Indirect estimator | `rtgi_trace.csh`, cosine-hemisphere voxel trace behind the temporary `PT_RAW_ESTIMATOR` contract macro — to be replaced in P6 |
| Second bounce | world-space voxel irradiance volume (`VOXEL_CACHE_*`), L1 SH, filtered and reprojected |
| Contact AO | `d3_ao.fsh`, quarter-res voxel any-hit, direct light only |
| Reflections | one world-space voxel bounce, no dedicated history or denoiser |
| Temporal | `rtgi_temporal.csh`, `RTGI_SPP_CAP=128` samples (max 255; was `RTGI_HISTORY_FRAMES=32` frames), `alpha = max(spp/count, 0.01*RTGI_MIN_ACCUM, adaptive_rejection)`, z-score adaptive rejection from M2 (`smoothstep(2,6)` sigma), count kept consistent with 1/alpha, soft disocclusion, no variance clip, 10 `PT_RESET_*` reason codes + `rtgi_state_img` |
| Spatial | `rtgi_filter.csh`, four à-trous passes, strides 1/2/4/8, variance-guided luma weight with `RTGI_FILTER_PHI=10` |
| Known visual defect | user-reported square bloom around bright regions, tracking the à-trous footprint at ±16 buffer texels; three weight-tuning attempts were reverted. **P3 must redesign the kernel/stride, not re-tune φ** |

## 5. Kappa reference

`KappaPT_v18.8.zip` (renamed from the uploaded `.txt`) is in the repository
root, ignored by `*.zip` in `.gitignore`, and extracted to
`~/reference/KappaPT_v18.8/` outside the repository for reading. Kappa
`LICENSE` §4 requires the author's permission to use parts of its source in
another project, and that permission has not been granted: **no Kappa code,
shader or asset may be copied into this fork.** Study the design, reimplement
independently, and never commit the ZIP.
