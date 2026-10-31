#!/usr/bin/env python3
"""Compute/fragment-focused static shader matrix."""
import itertools
import os
import subprocess
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
CHECK = str(HERE / "check.py")

FILES = [
    ("/world0/deferred1_a.csh", "comp"),
    ("/world0/deferred2_a.csh", "comp"),
    ("/world0/deferred3_a.csh", "comp"),
    ("/world0/deferred3_b.csh", "comp"),
    ("/world0/deferred3.fsh", "frag"),
    ("/world0/deferred4.fsh", "frag"),
    ("/world0/composite1.fsh", "frag"),
    ("/world0/final.fsh", "frag"),
    ("/world0/gbuffers_water.fsh", "frag"),
    ("/world0/gbuffers_terrain_solid.fsh", "frag"),
    ("/world0/shadow.fsh", "frag"),
    ("/world0/shadow.vsh", "vert"),
    ("/world-1/deferred4.fsh", "frag"),
    ("/world1/deferred4.fsh", "frag"),
    ("/world0/gbuffers_textured.fsh", "frag"),
]

VARIANTS = {
    "default": [],
    "reflections_off": ["RT_REFLECTION_RAYS=0"],
    "reflections_2ray": ["RT_REFLECTION_RAYS=2"],
    "reflections_off_phys_off": ["RT_REFLECTION_RAYS=0", "!PHYSICAL_BSDF_ENERGY_COMP"],
    "normal_map": ["NORMAL_MAPPING"],
    "taau": ["TAAU", "TAAU_RENDER_SCALE=0.75"],
    "taau_50": ["TAAU", "TAAU_RENDER_SCALE=0.50"],
    "normal_taau": ["NORMAL_MAPPING", "TAAU", "TAAU_RENDER_SCALE=0.75"],
    "res0_8rays": ["RTGI_RESOLUTION=0", "RTGI_RAY_COUNT=8", "RT_CLIPMAP_SIZE=128", "RT_COVERAGE_LEVELS=3"],
    "res2_8rays": ["RTGI_RESOLUTION=2", "RTGI_RAY_COUNT=8", "RT_CLIPMAP_SIZE=128", "RT_COVERAGE_LEVELS=3"],
    "no_vl": ["!VL"],
    "no_shadow": ["!SHADOW", "!SHADOW_SSRT"],
    "colorwheel": ["+COLORWHEEL"],
    "dh": ["+DISTANT_HORIZONS"],
    "voxy": ["+VOXY"],
    "vulkan_intel": ["+IRIS_VULKAN", "+MC_GL_VENDOR_INTEL"],
    "clipmap_64": ["RT_CLIPMAP_SIZE=64"],
    "clipmap_96_levels2": ["RT_CLIPMAP_SIZE=96", "RT_COVERAGE_LEVELS=2"],
    "clipmap_levels1": ["RT_COVERAGE_LEVELS=1"],
    "rt_ao_off": ["RT_AO_STRENGTH=0.00"],
    "rt_ao_8rays": ["RT_AO_RAYS=8", "RT_AO_RADIUS=2.00"],
}

def main():
    env = os.environ.copy()
    env.setdefault("NO_INJECT", "shadowtex0")
    failures = []
    total = 0
    for (f, st), (name, defs) in itertools.product(FILES, VARIANTS.items()):
        total += 1
        p = subprocess.run(
            [sys.executable, CHECK, f, st] + defs,
            capture_output=True, text=True, env=env,
        )
        out = p.stdout + p.stderr
        if p.returncode != 0 or "ERROR" in out or "Traceback" in out:
            failures.append((f, st, name, defs, out.strip()[:600]))
    print(f"total {total} fail {len(failures)}")
    for f, st, name, defs, out in failures:
        print(f"\n--- {f} {st} {name} {defs} ---\n{out}")
    return 1 if failures else 0

if __name__ == "__main__":
    raise SystemExit(main())
