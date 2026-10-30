#!/usr/bin/env python3
"""Compile/preprocess the single RT contact-AO estimator in every world.

RT Mode has no SSAO/GTAO selector. This checks that each world dispatches the
same voxel-ray estimator, that the configured ray budget reaches the shader,
and that strength zero keeps the neutral early-out. Requires GLSLANG.
"""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE / "check.py"
GLSLANG = os.environ.get("GLSLANG", "")

TARGETS = [
    ("/world0/deferred3.fsh", "frag"),
    ("/world-1/deferred3.fsh", "frag"),
    ("/world1/deferred3.fsh", "frag"),
]
VARIANTS = {
    "default": ([], 4, "0.50"),
    "off": (["RT_AO_STRENGTH=0.00"], 4, "0.00"),
    "low": (["RT_AO_RAYS=2", "RT_AO_STRENGTH=0.25"], 2, "0.25"),
    "high": (["RT_AO_RAYS=8", "RT_AO_STRENGTH=1.00", "RT_AO_RADIUS=2.00"], 8, "1.00"),
}
FORBIDDEN = ("compute_ssao", "compute_gtao", "compute_contact_ao", "SHADER_AO", "VANILLA_AO")


def temp_path(frag: str, defs: list[str]) -> pathlib.Path:
    tag = pathlib.Path(frag).stem + "_" + (
        "_".join(d.replace("=", "-").replace("!", "no") for d in defs) or "default"
    )
    return pathlib.Path("/tmp") / f"check_{tag}.frag"


def main() -> int:
    if not GLSLANG or not pathlib.Path(GLSLANG).is_file():
        print(f"error: executable glslang not found at {GLSLANG!r}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env.setdefault("NO_INJECT", "shadowtex0")
    failures: list[str] = []
    total = 0

    for frag, stage in TARGETS:
        for name, (defs, rays, strength) in VARIANTS.items():
            total += 1
            built = subprocess.run(
                [sys.executable, str(CHECK), frag, stage, *defs],
                capture_output=True, text=True, env=env,
            )
            out = built.stdout + built.stderr
            if built.returncode != 0 or "ERROR:" in out:
                failures.append(f"{frag} {name}: compile failed\n{out.strip()[:500]}")
                continue

            src = temp_path(frag, defs)
            if not src.is_file():
                failures.append(f"{frag} {name}: assembled source missing ({src})")
                continue
            pp = subprocess.run([GLSLANG, "-E", str(src)], capture_output=True, text=True)
            text = pp.stdout
            if pp.returncode != 0 or not text.strip():
                failures.append(f"{frag} {name}: preprocess failed\n{pp.stderr.strip()[:500]}")
                continue

            calls = len(re.findall(r"\bcompute_rt_ao\s*\(", text))
            if calls != 2:  # one definition + one dispatch call
                failures.append(f"{frag} {name}: expected one RT AO definition/call pair, found {calls}")
            if "trace_any_hit" not in text or "voxel_sampler" not in text:
                failures.append(f"{frag} {name}: voxel visibility backend missing")
            if f"i < {rays}" not in text:
                failures.append(f"{frag} {name}: ray budget {rays} did not reach estimator")
            if f"if ({strength} <= 0.0)" not in text:
                failures.append(f"{frag} {name}: strength {strength} did not reach neutral guard")
            for token in FORBIDDEN:
                if re.search(r"\b" + token + r"\b", text):
                    failures.append(f"{frag} {name}: forbidden legacy AO token {token}")

    for line in failures:
        print("FAIL", line)
    if failures:
        print(f"RT AO dispatch: total {total} fail {len(failures)}")
        return 1
    print(f"RT AO dispatch test OK: {total} cases, one voxel estimator per world")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
