#!/usr/bin/env python3
"""Assert that the AO setting selects exactly one estimator.

`check.py` assembles a translation unit with its `#if` directives intact, so a
successful compile proves only that *every* branch parses. It does not prove
that the requested branch is the one that survives. This test runs the real
preprocessor over the assembled source and counts estimator symbols, which is
the only way to catch a dispatch that compiles but selects the wrong path (or
silently emits two).

Requires GLSLANG (default /tmp/glslang-build/glslang-15.0.0/build/StandAlone/glslang)
and network-free operation once it is built.

Exit code 0 means every mode emitted exactly its own estimator.
"""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE / "check.py"
GLSLANG = os.environ.get(
    "GLSLANG", "/tmp/glslang-build/glslang-15.0.0/build/StandAlone/glslang"
)

# The pass that owns AO dispatch. world*/deferred3.fsh includes program/d3_ao.fsh.
TARGETS = [
    ("/world0/deferred3.fsh", "frag"),
    ("/world-1/deferred3.fsh", "frag"),
    ("/world1/deferred3.fsh", "frag"),
]

ESTIMATORS = ("compute_ssao", "compute_gtao", "compute_contact_ao")

# mode -> the single estimator that must be present (None => none of them)
EXPECTED = {
    "SHADER_AO_NONE": None,
    "SHADER_AO_SSAO": "compute_ssao",
    "SHADER_AO_GTAO": "compute_gtao",
    "SHADER_AO_CONTACT": "compute_contact_ao",
}

# Combinations that must not change the selection.
EXTRA = {
    "SHADER_AO_GTAO": [[], ["RAYTRACED_GI"], ["!RAYTRACED_GI"]],
    "SHADER_AO_CONTACT": [[], ["RAYTRACED_GI"], ["!RAYTRACED_GI"]],
    "SHADER_AO_SSAO": [[], ["!RAYTRACED_GI"]],
    "SHADER_AO_NONE": [[]],
}


def temp_path(frag: str, defs: list[str]) -> pathlib.Path:
    """Mirror check.py's output naming so we can preprocess the same file."""
    tag = (
        pathlib.Path(frag).stem
        + "_"
        + ("_".join(d.replace("=", "-").replace("!", "no") for d in defs) or "default")
    )
    return pathlib.Path("/tmp") / f"check_{tag}.frag"


def main() -> int:
    if not pathlib.Path(GLSLANG).is_file():
        print(f"error: glslang not found at {GLSLANG}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env.setdefault("NO_INJECT", "shadowtex0")

    failures: list[str] = []
    total = 0

    for frag, stage in TARGETS:
        for mode, extras in EXTRA.items():
            for extra in extras:
                total += 1
                defs = [f"SHADER_AO={mode}", *extra]
                built = subprocess.run(
                    [sys.executable, str(CHECK), frag, stage, *defs],
                    capture_output=True, text=True, env=env,
                )
                if built.returncode != 0 or "ERROR:" in built.stdout + built.stderr:
                    failures.append(
                        f"{frag} {mode} {extra}: compile failed\n"
                        + (built.stdout + built.stderr).strip()[:400]
                    )
                    continue

                src = temp_path(frag, defs)
                if not src.is_file():
                    failures.append(f"{frag} {mode} {extra}: assembled source missing ({src})")
                    continue

                pp = subprocess.run(
                    [GLSLANG, "-E", str(src)], capture_output=True, text=True
                )
                text = pp.stdout
                if not text.strip():
                    failures.append(
                        f"{frag} {mode} {extra}: preprocessor produced no output\n"
                        + pp.stderr.strip()[:400]
                    )
                    continue

                want = EXPECTED[mode]
                found = {}
                for name in ESTIMATORS:
                    n = len(re.findall(r"\b" + name + r"\s*\(", text))
                    if n:
                        found[name] = n

                if want is None:
                    if found:
                        failures.append(
                            f"{frag} {mode} {extra}: expected no estimator, "
                            f"found {found}"
                        )
                    continue

                unexpected = set(found) - {want}
                if unexpected:
                    failures.append(
                        f"{frag} {mode} {extra}: expected only {want}, "
                        f"also emitted {sorted(unexpected)}"
                    )
                elif want not in found:
                    failures.append(
                        f"{frag} {mode} {extra}: expected {want}, emitted none"
                    )

    for line in failures:
        print("FAIL", line)
    if failures:
        print(f"ao dispatch: total {total} fail {len(failures)}")
        return 1

    print(f"ao dispatch test OK: {total} cases, exactly one estimator per mode")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
