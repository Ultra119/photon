#!/usr/bin/env python3
"""Compute/fragment-focused static shader matrix (294 cases by default)."""
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
    "rtgi_off": ["!RAYTRACED_GI"],
    "rtgi_refl_off": ["!RAYTRACED_GI", "!RT_REFLECTIONS"],
    "all_rt_off_phys_off": ["!RAYTRACED_GI", "!RT_REFLECTIONS", "!PHYSICAL_BSDF_ENERGY_COMP"],
    "normal_map": ["NORMAL_MAPPING"],
    "taau": ["TAAU", "TAAU_RENDER_SCALE=0.75"],
    "taau_50": ["TAAU", "TAAU_RENDER_SCALE=0.50"],
    "normal_taau": ["NORMAL_MAPPING", "TAAU", "TAAU_RENDER_SCALE=0.75"],
    "res0_8rays": ["RTGI_RESOLUTION=0", "RTGI_RAY_COUNT=8", "VOXEL_VOLUME_SIZE=512"],
    "res2_8rays": ["RTGI_RESOLUTION=2", "RTGI_RAY_COUNT=8", "VOXEL_VOLUME_SIZE=512"],
    "no_sh_skylight": ["!SH_SKYLIGHT"],
    "no_vl": ["!VL"],
    "no_shadow": ["!SHADOW", "!SHADOW_SSRT"],
    "colorwheel": ["+COLORWHEEL"],
    "dh": ["+DISTANT_HORIZONS"],
    "voxy": ["+VOXY"],
    "vulkan_intel": ["+IRIS_VULKAN", "+MC_GL_VENDOR_INTEL"],
    "voxel_64": ["VOXEL_VOLUME_SIZE=64"],
    "voxel_256": ["VOXEL_VOLUME_SIZE=256"],
    "voxel_512": ["VOXEL_VOLUME_SIZE=512"],
    "voxel_ahead": ["VOXEL_VOLUME_CENTER=VOXEL_VOLUME_CENTER_AHEAD"],
    "contact_ao_off": ["RTGI_CONTACT_AO_STRENGTH=0.00"],
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
