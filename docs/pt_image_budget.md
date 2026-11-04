# PT image budget (P0)

**Branch:** `arena/d99fd523-photon` · **Baseline commit:** `f1df4b7` · **Date:** 2026-11-04

The PT-only fork ships one lighting path, so the old "per lighting mode"
allocation table collapses into a table per **PT quality tier**: every tier
allocates the *same* images, only their dimensions change.

Regenerate with:

```sh
python3 tools/shadercheck/image_budget.py
# or, for a different reference resolution:
IMAGE_BUDGET_WIDTH=2560 IMAGE_BUDGET_HEIGHT=1440 python3 tools/shadercheck/image_budget.py
```

`run_checks.sh` runs it on every invocation; it fails if any tier exceeds
Iris's 16-image limit.

---

# Custom-image budget per PT quality tier (reference render resolution 1920x1080)

Nominal bytes per texel, no mipmaps, relative images evaluated at the reference resolution above. Iris allows at most 16 custom images.

| PT quality tier | RTGI scale | Clipmap | Images | Voxel scene + cache | RTGI chain | Total |
|---|---|---|---:|---:|---:|---:|
| low | 0 | 64³ | 14 | 11.00 MiB | 6.92 MiB | 17.92 MiB |
| medium | 1 | 96³ | 14 | 37.12 MiB | 27.69 MiB | 64.81 MiB |
| high | 1 | 128³ | 14 | 88.00 MiB | 27.69 MiB | 115.69 MiB |
| ultra | 1 | 128³ | 14 | 88.00 MiB | 27.69 MiB | 115.69 MiB |
| extreme | 2 | 128³ | 14 | 88.00 MiB | 110.74 MiB | 198.74 MiB |

## Debug views

The GI debug views allocate one extra `rgba8` image at the RTGI scale, so they are the worst case for the image count:

| Tier | Extra debug image | Count with debug |
|---|---|---:|
| low | 0.49 MiB (rgba8 at RTGI scale) | 15 |
| medium | 1.98 MiB (rgba8 at RTGI scale) | 15 |
| high | 1.98 MiB (rgba8 at RTGI scale) | 15 |
| ultra | 1.98 MiB (rgba8 at RTGI scale) | 15 |
| extreme | 7.91 MiB (rgba8 at RTGI scale) | 15 |

## Per-image detail (highest tier)

| Image | Tier `extreme` |
|---|---:|
| `voxel_cache_sh_img` | 16.00 MiB |
| `voxel_cache_aux_img` | 16.00 MiB |
| `voxel_cache_flip_sh_img` | 16.00 MiB |
| `voxel_cache_flip_aux_img` | 16.00 MiB |
| `rtgi_raw_img` | 15.82 MiB |
| `rtgi_history_img` | 15.82 MiB |
| `rtgi_accum_img` | 15.82 MiB |
| `rtgi_sky_accum_img` | 15.82 MiB |
| `rtgi_sky_history_img` | 15.82 MiB |
| `rtgi_filtered_img` | 15.82 MiB |
| `rtgi_filter_inter_img` | 15.82 MiB |
| `voxel_img` | 8.00 MiB |
| `voxel_mid_img` | 8.00 MiB |
| `voxel_coarse_img` | 8.00 MiB |
| **Total** | **198.74 MiB** |


---

## What each group is for

| Group | Images | Written by | Read by |
|---|---|---|---|
| `voxel_*_img` | 3 | `shadow.vsh`, `gbuffers_all_*.vsh` (`update_rt_voxel_grid`) | every clipmap tracer: GI, contact AO, reflections, irradiance cache |
| `rtgi_*_img` | 7 | `rtgi_trace.csh` → `rtgi_temporal.csh` → `rtgi_filter.csh` | `d4_deferred_shading.fsh`, `final.fsh` debug views |
| `voxel_cache_*_img` | 4 | `voxel_cache_generate/filter/flip/reproject.csh` | forward and translucent surfaces (`diffuse_lighting.glsl`), one bounce in `rt_gi.glsl` |
| `rtgi_hit_img` / `rtgi_reject_img` | 1 (only for the selected `GI_DEBUG` view) | `rtgi_trace.csh` / `rtgi_temporal.csh` | `final.fsh` |

## Reading the numbers

- The **voxel scene and irradiance cache dominate**: four `RGBA16F` volumes at
  `RT_CLIPMAP_SIZE³` are 64 MiB at the 128³ tier, versus 24 MiB for the three
  `R32UI` clipmaps.
- `RTGI_RESOLUTION=2` (full res) costs 4× the RTGI chain of half res, and it is
  the single largest lever in the table. Extreme is the only tier that pays it.
- All tiers sit at 14 images, 15 with a debug view active — inside Iris's
  16-image ceiling, with one slot of headroom. **P2/P3 (temporal rewrite and the
  multi-scale denoise redesign) and P5 (separate specular history) both want new
  ping-pong images.** One free slot is not enough: P5 in particular must either
  reuse the `rtgi_filter_inter_img` slot or drop a sky-history image, or move a
  channel into an existing image's unused components. Budget that before writing
  the passes, not after.
