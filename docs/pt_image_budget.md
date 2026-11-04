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

P1 adds `rtgi_state_img` (rgba16f at the RTGI scale, single buffered: reset
reason / reactive mask / valid-path fraction / converged flag), which takes the
tier from 14 to 15 images and the worst case — a tier with a debug view
selected — to exactly 16. That is the ceiling: P5's specular reflection
history has to free a channel (the stored octahedral normal in the aux image,
or the separately stored M2 moment) before it can allocate another image.

---

# Custom-image budget per PT quality tier (reference render resolution 1920x1080)

Nominal bytes per texel, no mipmaps, relative images evaluated at the reference resolution above. Iris allows at most 16 custom images.

| PT quality tier | RTGI scale | Clipmap | Images | Voxel scene + cache | RTGI chain | Total |
|---|---|---|---:|---:|---:|---:|
| low | 0 | 64³ | 15 | 11.00 MiB | 7.91 MiB | 18.91 MiB |
| medium | 1 | 96³ | 15 | 37.12 MiB | 31.64 MiB | 68.77 MiB |
| high | 1 | 128³ | 15 | 88.00 MiB | 31.64 MiB | 119.64 MiB |
| ultra | 1 | 128³ | 15 | 88.00 MiB | 31.64 MiB | 119.64 MiB |
| extreme | 2 | 128³ | 15 | 88.00 MiB | 126.56 MiB | 214.56 MiB |

## Debug views

The GI debug views allocate one extra `rgba8` image at the RTGI scale, so they are the worst case for the image count:

| Tier | Extra debug image | Count with debug |
|---|---|---:|
| low | 0.49 MiB (rgba8 at RTGI scale) | 16 |
| medium | 1.98 MiB (rgba8 at RTGI scale) | 16 |
| high | 1.98 MiB (rgba8 at RTGI scale) | 16 |
| ultra | 1.98 MiB (rgba8 at RTGI scale) | 16 |
| extreme | 7.91 MiB (rgba8 at RTGI scale) | 16 |

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
| `rtgi_state_img` | 15.82 MiB |
| `voxel_img` | 8.00 MiB |
| `voxel_mid_img` | 8.00 MiB |
| `voxel_coarse_img` | 8.00 MiB |
| **Total** | **214.56 MiB** |
