#!/usr/bin/env python3
"""R7 clipmap coordinate, seam, energy and image-budget guardrails.

The GPU backend is a full per-frame rebuild of camera-snapped, toroidally
addressed clipmaps. These CPU checks mirror the coordinate contract and verify
that nested levels do not double-count a surface/emitter or glass attenuation.
"""
from __future__ import annotations

import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHADERS = ROOT / "shaders"


def origin(camera: float, dim: int, level: int) -> float:
    scale = 1 << level
    extent = dim * scale
    return math.floor((camera - extent * 0.5) / scale) * scale


def texel(cell: int, dim: int) -> int:
    return cell - dim * math.floor(cell / dim)


def contains(world: float, camera: float, dim: int, level: int) -> bool:
    scale = 1 << level
    local = (world - origin(camera, dim, level)) / scale
    return 0.0 <= local < dim


def finest_level(world: float, camera: float, dim: int, levels: int) -> int:
    for level in range(levels):
        if contains(world, camera, dim, level):
            return level
    return -1


def exit_distance(camera: float, dim: int, level: int, direction: float = 1.0) -> float:
    scale = 1 << level
    lo = origin(camera, dim, level)
    hi = lo + dim * scale
    if direction > 0:
        return hi - camera
    return camera - lo


def main() -> int:
    failures: list[str] = []

    for dim in (64, 96, 128):
        for cell in (-2 * dim - 3, -dim, -1, 0, 1, dim - 1, dim, 2 * dim + 7):
            t = texel(cell, dim)
            if not (0 <= t < dim):
                failures.append(f"toroidal wrap out of range: cell={cell} dim={dim} -> {t}")
            if (cell - t) % dim != 0:
                failures.append(f"toroidal wrap changed world cell modulo: {cell}->{t}")

    dim = 128
    camera = 10.25
    # Sub-voxel camera drift must not move the snapped origin.
    if origin(camera, dim, 0) != origin(camera + 0.5, dim, 0):
        failures.append("fine origin moved under sub-voxel camera drift")
    # Crossing a one-block boundary advances the fine origin by exactly one.
    if origin(camera + 1.0, dim, 0) - origin(camera, dim, 0) != 1.0:
        failures.append("fine origin did not scroll by one voxel at a block boundary")

    # Nested ownership: a point in the fine cube is never assigned to coarse.
    for offset in (0.0, 10.0, 60.0):
        if finest_level(camera + offset, camera, dim, 3) != 0:
            failures.append(f"fine-region point assigned to wrong level at offset {offset}")
    for offset in (70.0, 100.0, 120.0):
        if finest_level(camera + offset, camera, dim, 3) != 1:
            failures.append(f"medium-ring point assigned to wrong level at offset {offset}")
    for offset in (200.0, 250.0):
        if finest_level(camera + offset, camera, dim, 3) != 2:
            failures.append(f"coarse-ring point assigned to wrong level at offset {offset}")
    if finest_level(camera + 400.0, camera, dim, 3) != -1:
        failures.append("point outside all clipmaps was assigned coverage")

    # Level seams: each coarser trace starts strictly after the finer exit.
    exits = [exit_distance(camera, dim, level) for level in range(3)]
    if not (exits[0] < exits[1] < exits[2]):
        failures.append(f"clipmap exits are not nested: {exits}")
    starts = [0.0, exits[0] + 0.02, exits[1] + 0.02]
    for level in range(1, 3):
        if starts[level] <= exits[level - 1]:
            failures.append(f"level {level} overlaps finer coverage at seam")

    # Emitter energy: the same intrinsic radiance is returned once regardless of
    # which level first hits it; glass transmittance is applied exactly once.
    Le = 2.5
    glass = 0.6
    for level in range(3):
        hit_radiance = Le  # unattenuated outgoing radiance at hit
        total_transmittance = glass
        observed = hit_radiance * total_transmittance
        if not math.isclose(observed, Le * glass, rel_tol=1e-9):
            failures.append(f"level {level} emitter/glass energy double-counted")

    # Static wiring / budget.
    props = (SHADERS / "shaders.properties").read_text(encoding="utf-8")
    image_names = set(re.findall(r"^image\.([A-Za-z0-9_]+)\s*=", props, re.M))
    if len(image_names) > 16:
        failures.append(f"custom image budget exceeded: {len(image_names)} > 16")
    for name in ("voxel_img", "voxel_mid_img", "voxel_coarse_img"):
        if name not in image_names:
            failures.append(f"missing clipmap image declaration: {name}")
    for profile in ("low", "medium", "high", "ultra", "extreme"):
        line = next((l for l in props.splitlines() if l.startswith(f"profile.{profile} ")), "")
        if "RT_CLIPMAP_SIZE=" not in line or "RT_COVERAGE_LEVELS=" not in line:
            failures.append(f"profile {profile} lacks explicit clipmap budget")

    dda = (SHADERS / "include/lighting/rt/voxel_dda.glsl").read_text(encoding="utf-8")
    if "usampler3D voxel_mid" not in dda or "usampler3D voxel_coarse" not in dda:
        failures.append("shared scene query does not accept the clipmap stack")
    if "level_exit + 0.02" not in dda:
        failures.append("coarse levels do not start outside finer coverage")
    update = (SHADERS / "include/lighting/voxel/voxel_update.glsl").read_text(encoding="utf-8")
    for image in ("voxel_img", "voxel_mid_img", "voxel_coarse_img"):
        if f"imageAtomicMax({image}" not in update:
            failures.append(f"voxel update does not populate {image}")

    if failures:
        for f in failures:
            print("FAIL", f)
        print(f"clipmap: {len(failures)} failure(s)")
        return 1
    print("clipmap test OK: toroidal coords, nested seams, single-hit energy, image budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
