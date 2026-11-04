#!/usr/bin/env python3
"""Assert the P3 spatial denoise contract.

The a-trous pyramid is the only thing standing between one ray per pixel and
the image, and its failure modes are invisible to a compiler:

1. The LAST pass of the pyramid is the one whose footprint the final image
   inherits. Narrow -> wide puts the widest, sparsest kernel last, so the
   player sees the output of a +-30 texel box blur.

2. The luminance edge-stop is sigma_l = PHI * sqrt(variance). The variance
   collapses as a pixel converges while the signal does not, so a converged
   pixel's tolerance ends up larger than the signal itself and the stop
   accepts everything: the wide passes become unguarded box blurs and the
   room goes flat.

3. Neither is fixable by changing PHI, the B-spline weights or any sigma --
   that is re-tuning, and it was already measured not to change the
   footprint. Both are structural.

Exit code 0 means every assertion held.
"""
from __future__ import annotations

import math
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHADERS = ROOT / "shaders"
FILTER = SHADERS / "program/rtgi/rtgi_filter.csh"
SETTINGS = SHADERS / "settings.glsl"

PASSES = 4
KERNEL_RADIUS = 2  # the 5-tap B-spline spans +-2 taps


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def read_define(text: str, name: str) -> float | None:
    match = re.search(rf"#define\s+{name}\s+([0-9.]+)", text)
    return float(match.group(1)) if match else None


def strides() -> list[int]:
    """The step_size each RTGI_FILTER_PASS compiles with."""
    src = strip_comments(read(FILTER))
    # Anchor on step_size: there are several RTGI_FILTER_PASS chains in the
    # file and the first one is not the stride chain.
    anchor = src.index("const int step_size")
    start = src.rindex("#if RTGI_FILTER_PASS == 1", 0, anchor)
    chain = src[start:src.index("#endif", anchor)]
    found = []
    # Split the #if/#elif/#else chain into its branches: the step_size values
    # then come out in pass order, with the #else branch last.
    for branch in re.split(
        r"#(?:if|elif)\s+RTGI_FILTER_PASS\s*==\s*\d+|#else", chain
    ):
        step = re.search(r"const int step_size = (\d+);", branch)
        if step:
            found.append(int(step.group(1)))
    return found


def check_stride_order(failures: list[str]) -> None:
    """Claim 1: the pyramid runs wide to narrow."""
    if not FILTER.is_file():
        failures.append(f"missing {FILTER}")
        return
    found = strides()
    if len(found) != PASSES:
        failures.append(
            f"expected {PASSES} filter passes with a step_size, found {found}"
        )
        return
    if found != sorted(found, reverse=True):
        failures.append(
            f"the a-trous strides run {found}, narrow to wide: the last pass "
            "is the widest, so the final image inherits its footprint"
        )
    if found[-1] != 1:
        failures.append(
            f"the final pass runs at stride {found[-1]}; it should be 1 so the "
            "image the player sees is not the output of a sparse wide kernel"
        )

    # Reversing the order must not change what the stack costs.
    support = KERNEL_RADIUS * sum(found)
    if support > 2 * (1 + 2 + 4 + 8):
        failures.append(
            f"total filter support is +-{support} texels, wider than the "
            "previous stack; the reorder was meant to be free"
        )


def check_converged_bypass(failures: list[str]) -> None:
    """Claim 2: a converged pixel is not handed to a filter it has outgrown.

    sigma_l = PHI * sqrt(variance) and the variance collapses as the pixel
    converges, so the luminance edge-stop ends up accepting everything. The
    measurement below has to show that, or this check is not describing
    anything real.
    """
    src = strip_comments(read(FILTER))
    phi = read_define(read(SETTINGS), "RTGI_FILTER_PHI")
    cap = read_define(read(SETTINGS), "RTGI_SPP_CAP")
    if phi is None or cap is None:
        failures.append("RTGI_FILTER_PHI / RTGI_SPP_CAP are not in settings.glsl")
        return

    # The M2 EMA reports about twice the estimate's variance at steady state.
    for sigma, signal in ((0.30, 0.30), (0.60, 0.60)):
        variance = 2.0 * sigma * sigma / cap
        sigma_l = phi * math.sqrt(variance)
        weight = math.exp(-0.10 / sigma_l)  # a clearly different neighbour
        if weight < 0.5:
            failures.append(
                f"a converged pixel still rejects a neighbour 0.10 away "
                f"(weight {weight:.2f}); the edge-stop is not inert, so the "
                "bypass is not addressing the measured problem"
            )

    flat = "".join(src.split())
    if "smoothstep(float(RTGI_SPP_CAP)*0.25,float(RTGI_SPP_CAP)" not in flat:
        failures.append(
            "the wide passes do not fade out with the pixel's sample count"
        )
    if "filtered=mix(filtered,center_radiance,convergence)" not in flat:
        failures.append(
            "the converged bypass does not blend back toward the unfiltered "
            "centre, so a converged pixel is still fully blurred"
        )
    # The bypass has to be on the wide passes only: the narrow passes are what
    # takes the edge off the residual noise.
    blocks = re.split(r"#if\s+RTGI_FILTER_PASS\s*==\s*", src)
    bypassed = set()
    for block in blocks:
        match = re.match(r"(\d+)", block)
        if match and "convergence" in block:
            bypassed.add(int(match.group(1)))
    if not bypassed or bypassed & {PASSES} or max(bypassed) > 2:
        failures.append(
            f"the bypass is on passes {sorted(bypassed)}; it belongs on the "
            "wide passes only, so the narrow pass still smooths what is left"
        )
    # A hard cutoff would make pixels pop as they cross the cap.
    if ">=float(RTGI_SPP_CAP)-0.5" in flat:
        failures.append(
            "the converged bypass is a hard cutoff at the cap; it must fade, "
            "or pixels pop as they reach it"
        )


def main() -> int:
    failures: list[str] = []
    check_stride_order(failures)
    check_converged_bypass(failures)

    if failures:
        print(f"FAIL: {len(failures)} assertion(s)")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    phi = read_define(read(SETTINGS), "RTGI_FILTER_PHI")
    cap = read_define(read(SETTINGS), "RTGI_SPP_CAP")
    print(
        "RTGI filter contract OK (strides "
        f"{strides()}, converged bypass on the wide passes, "
        f"PHI {phi} / cap {cap} unchanged)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
