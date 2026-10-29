#!/usr/bin/env python3
"""Assert the GI debug views are wired to exactly one source each.

Three separate claims are checked, and none of them are provable by a compile:

1. Each GI_DEBUG value reads exactly the buffers that view is documented to
   read, and no others. A view that reads the wrong buffer still compiles and
   still shows a plausible picture -- that is the failure mode worth guarding.

2. GI_DEBUG_OFF reads no GI buffer at all. This is the "zero cost when
   disabled" acceptance criterion, expressed as something a machine can check.

3. Each debug image is written by exactly one pass, and only when its own view
   is selected, so an inactive view costs neither a store nor an allocation.

Requires GLSLANG (default /tmp/glslang-build/glslang-15.0.0/build/StandAlone/glslang)
and cpp (for the shaders.properties check, which is skipped if cpp is absent).

Exit code 0 means every assertion held.
"""
from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CHECK = HERE / "check.py"
SHADERS = ROOT / "shaders"
GLSLANG = os.environ.get(
    "GLSLANG", "/tmp/glslang-build/glslang-15.0.0/build/StandAlone/glslang"
)

# View -> (encoder calls expected, GI sampler reads expected).
#
# `palette_color` is excluded because it is called from inside the definition of
# gi_debug_voxel_id(), so it survives preprocessing in every configuration and
# carries no information about which branch was selected.
EXPECTED = {
    "GI_DEBUG_OFF":          (set(), set()),
    "GI_DEBUG_RAW":          ({"tonemap"}, {"rtgi_raw"}),
    "GI_DEBUG_HISTORY":      ({"tonemap"}, {"rtgi_accum", "rtgi_history"}),
    "GI_DEBUG_FILTERED":     ({"tonemap"}, {"rtgi_filtered"}),
    "GI_DEBUG_VARIANCE":     ({"spread"}, {"rtgi_accum", "rtgi_history", "rtgi_raw"}),
    "GI_DEBUG_HIT":          ({"hit_mask"}, {"rtgi_hit"}),
    "GI_DEBUG_REJECT":       ({"reject_mask"}, {"rtgi_reject"}),
    "GI_DEBUG_VOXEL_ID":     ({"voxel_id"}, set()),
    "GI_DEBUG_VOXEL_LIGHT":  ({"voxel_light"}, set()),
    "GI_DEBUG_VOXEL_ALBEDO": ({"voxel_albedo"}, set()),
}

# (world wrapper, stage, image name, the value of GI_DEBUG that writes it)
WRITERS = [
    ("/world0/deferred1_a.csh", "comp", "rtgi_hit_img", "GI_DEBUG_HIT"),
    ("/world0/deferred2_a.csh", "comp", "rtgi_reject_img", "GI_DEBUG_REJECT"),
]


def build(frag: str, stage: str, defs: list[str], env: dict) -> tuple[int, str, pathlib.Path]:
    built = subprocess.run(
        [sys.executable, str(CHECK), frag, stage, *defs],
        capture_output=True, text=True, env=env,
    )
    tag = (
        pathlib.Path(frag).stem
        + "_"
        + ("_".join(d.replace("=", "-").replace("!", "no") for d in defs) or "default")
    )
    return built.returncode, built.stdout + built.stderr, pathlib.Path("/tmp") / f"check_{tag}.{stage}"


def preprocess(src: pathlib.Path) -> str:
    pp = subprocess.run([GLSLANG, "-E", str(src)], capture_output=True, text=True)
    return pp.stdout


def main() -> int:
    if not pathlib.Path(GLSLANG).is_file():
        print(f"error: glslang not found at {GLSLANG}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env.setdefault("NO_INJECT", "shadowtex0")

    failures: list[str] = []
    checked = 0

    # --- 1 & 2: the display side -------------------------------------------
    for view, (want_encoders, want_reads) in EXPECTED.items():
        checked += 1
        rc, log, src = build(
            "/world0/final.fsh", "frag",
            ["DEBUG_VIEW=DEBUG_VIEW_GI", f"GI_DEBUG={view}"], env,
        )
        if rc != 0 or "ERROR:" in log:
            failures.append(f"final.fsh {view}: compile failed\n{log.strip()[:400]}")
            continue
        if not src.is_file():
            failures.append(f"final.fsh {view}: assembled source missing")
            continue

        text = preprocess(src)
        encoders = {
            m for m in re.findall(r"return\s+gi_debug_([a-z_]+)\s*\(", text)
            if m != "palette_color"
        }
        # Any *use* of a GI sampler, not just texture(...) -- the mask views
        # hand theirs to a smoothing helper. A `uniform sampler2D rtgi_x_sampler;`
        # declaration is not a read, so drop those lines first.
        reads = set()
        for line in text.splitlines():
            if re.match(r"\s*uniform\s+\w+\s+rtgi_\w+_sampler\s*;", line):
                continue
            reads.update(re.findall(r"\b(rtgi_[a-z]+)_sampler\b", line))

        if encoders != want_encoders:
            failures.append(
                f"final.fsh {view}: encoders {sorted(encoders)}, "
                f"expected {sorted(want_encoders)}"
            )
        if reads != want_reads:
            failures.append(
                f"final.fsh {view}: buffer reads {sorted(reads)}, "
                f"expected {sorted(want_reads)}"
            )

    # --- 2b: every view's corner swatch must be a different colour ----------
    # The swatch exists so a screenshot identifies itself. Two views sharing a
    # colour would silently defeat that, and it is the kind of thing that
    # happens when a new view is added by copying an existing branch.
    swatches: dict[str, str] = {}
    for view in EXPECTED:
        if view == "GI_DEBUG_OFF":
            continue
        rc, log, src = build(
            "/world0/final.fsh", "frag",
            ["DEBUG_VIEW=DEBUG_VIEW_GI", f"GI_DEBUG={view}"], env,
        )
        if rc != 0 or not src.is_file():
            continue
        text = preprocess(src)
        block = re.search(
            r"vec3 gi_debug_view_swatch\(\) \{(.*?)\n\}", text, re.S
        )
        if not block:
            failures.append(f"{view}: gi_debug_view_swatch() not found")
            continue
        colour = re.search(r"vec3\(\s*[0-9.]+\s*,\s*[0-9.]+\s*,\s*[0-9.]+\s*\)", block.group(1))
        if not colour:
            failures.append(f"{view}: no literal swatch colour")
            continue
        swatches[colour.group(0)] = swatches.get(colour.group(0), "") + f" {view}"

    checked += 1
    dupes = {c: v for c, v in swatches.items() if len(v.split()) > 1}
    if dupes:
        failures.append(f"views share a swatch colour: {dupes}")

    # --- 3: the writer side ------------------------------------------------
    for wrapper, stage, image, owner in WRITERS:
        for view in EXPECTED:
            checked += 1
            rc, log, src = build(wrapper, stage, [f"GI_DEBUG={view}"], env)
            if rc != 0 or "ERROR:" in log:
                failures.append(f"{wrapper} {view}: compile failed\n{log.strip()[:400]}")
                continue
            text = preprocess(src)
            writes = f"imageStore({image}" in text.replace(" ", "")
            should_write = view == owner
            if writes != should_write:
                failures.append(
                    f"{wrapper} {view}: writes {image}={writes}, "
                    f"expected {should_write}"
                )

    # --- 3b: allocation follows the same switch ----------------------------
    cpp = shutil.which("cpp")
    if cpp is None:
        print("warning: cpp not found; skipping the shaders.properties "
              "allocation check", file=sys.stderr)
    else:
        for image, owner in (
            ("rtgi_hit_img", "GI_DEBUG_HIT"),
            ("rtgi_reject_img", "GI_DEBUG_REJECT"),
        ):
            for view in ("GI_DEBUG_OFF", owner):
                checked += 1
                with tempfile.TemporaryDirectory() as tmp:
                    copy = pathlib.Path(tmp) / "shaders"
                    shutil.copytree(SHADERS, copy)
                    settings = copy / "settings.glsl"
                    text = settings.read_text(encoding="utf-8", errors="replace")
                    # Rewrite only the setting under test; every other line,
                    # including the surrounding #if blocks, stays untouched.
                    text = re.sub(
                        r"(?m)^(\s*)#define GI_DEBUG GI_DEBUG_\w+.*$",
                        rf"\1#define GI_DEBUG {view}",
                        text, count=1,
                    )
                    settings.write_text(text, encoding="utf-8")

                    defines = "\n".join(
                        f"#define {m.group(1)} {m.group(2)}"
                        for m in re.finditer(
                            r"(?m)^\s*#define\s+([A-Za-z_]\w*)\s+(\S+)",
                            text,
                        )
                    )
                    props = (copy / "shaders.properties").read_text(
                        encoding="utf-8", errors="replace"
                    )
                    result = subprocess.run(
                        [cpp, "-P", "-traditional-cpp", "-x", "c", "-"],
                        input=defines + "\n" + props,
                        capture_output=True, text=True,
                    )
                    declared = f"image.{image}" in result.stdout
                    should = view == owner
                    if declared != should:
                        failures.append(
                            f"shaders.properties with GI_DEBUG={view}: "
                            f"declares {image}={declared}, expected {should}"
                        )

    for line in failures:
        print("FAIL", line)
    if failures:
        print(f"gi debug: total {checked} fail {len(failures)}")
        return 1

    print(
        f"gi debug test OK: {checked} cases, one source per view, "
        "no allocation and no writes when OFF"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
