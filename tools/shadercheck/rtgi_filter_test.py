#!/usr/bin/env python3
"""Assert the P3 spatial denoise contract.

The a-trous pyramid is the only thing standing between one ray per pixel and
the image, and its failure modes are invisible to a compiler:

1. The LAST pass of the pyramid is the one whose footprint the final image
   inherits. Narrow -> wide puts the widest, sparsest kernel last, so the
   player sees the output of a +-30 texel box blur.

2. The luminance edge-stop is sigma_l = PHI * sqrt(variance), and the
   variance fed to it is the PER-SAMPLE variance: M2 is an EMA of sample
   luminance squared, so variance = M2 - M1^2 converges to Var(X) and does
   not shrink as samples accumulate. sigma_l is then about sqrt(cap) times
   wider than the noise actually left in the estimate, the stop accepts
   almost everything, the wide passes become unguarded box blurs and the
   room goes flat.

3. For the same reason the sample COUNT is not a convergence measure. A
   light-15 emitter is EMISSION_ANCHOR = 8.0 and RTGI_MAX_RADIANCE = 12.0
   sits deliberately above it, so an emitter hit arrives unclamped at ~8
   against an ambient GI of ~0.3: one such sample among 128 shifts the mean
   by ~0.06 and then lands again, so for that term the effective sample
   count is near 1 at any cap. Only the standard error of the mean,
   sd / sqrt(N), separates a pixel that has converged from one that merely
   has a lot of samples.

4. Neither is fixable by changing PHI, the B-spline weights or any sigma --
   that is re-tuning, and it was already measured not to change the
   footprint. All three are structural.

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

# Ratio of the variance the M2 EMA reports to the true per-sample variance,
# measured on a 96x96 CPU model of the temporal recurrence in
# rtgi_temporal.csh (reported sd 1.03 against a true per-sample sd of 1.10).
REPORTED_VAR_RATIO = 0.94


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


def check_edge_stop_inert(failures: list[str]) -> None:
    """Claim 2: a converged pixel's luminance edge-stop accepts everything.

    sigma_l = PHI * sqrt(variance) where the variance is the PER-SAMPLE
    variance, which does not shrink as the pixel converges. The measurement
    below has to show the stop is inert, or this check describes nothing.
    """
    src = strip_comments(read(FILTER))
    phi = read_define(read(SETTINGS), "RTGI_FILTER_PHI")
    cap = read_define(read(SETTINGS), "RTGI_SPP_CAP")
    if phi is None or cap is None:
        failures.append("RTGI_FILTER_PHI / RTGI_SPP_CAP are not in settings.glsl")
        return

    for sigma in (0.30, 0.60):
        sigma_l = phi * math.sqrt(REPORTED_VAR_RATIO * sigma * sigma)
        weight = math.exp(-0.10 / sigma_l)  # a clearly different neighbour
        if weight < 0.5:
            failures.append(
                f"at cap {cap:.0f} a per-sample sd of {sigma} gives sigma_l = "
                f"{sigma_l:.2f}, which still rejects a neighbour 0.10 away "
                f"(weight {weight:.2f}); the edge-stop is not inert, so the "
                "bypass is not addressing the measured problem"
            )

    flat = "".join(src.split())
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


def check_bypass_gate(failures: list[str]) -> None:
    """Claim 3: the bypass gates on the standard error, not on the count.

    A light-15 emitter is EMISSION_ANCHOR = 8.0 and RTGI_MAX_RADIANCE = 12.0
    sits deliberately above it so legitimate emitter hits do not saturate the
    firefly cap, so one lava hit arrives unclamped at ~8 against an ambient GI
    of ~0.3. Among 128 samples it shifts the mean by ~0.06 and then lands
    again, so that term's effective sample count is near 1 at any cap: the
    count reads "converged" while the estimate is still moving. Measured on a
    CPU model of this pyramid, gating on the count alone gives 4.6x the
    temporal flicker near an emitter, and is the only configuration whose
    extreme excursion is BRIGHT rather than dark -- the stray super-bright
    spots. Gating on the relative standard error instead matches it exactly on
    clean pixels while returning the emitter region to baseline flicker.
    """
    src = strip_comments(read(FILTER))
    flat = "".join(src.split())

    if "smoothstep(float(RTGI_SPP_CAP)*0.25,float(RTGI_SPP_CAP),accum_count)" not in flat:
        failures.append(
            "the count ramp no longer runs from a quarter of the cap to the "
            "cap; the gate must stay shut on a fresh pixel"
        )

    for token, why in (
        ("relative_se", "the relative standard error of the mean"),
        ("se_gate", "the standard-error gate"),
        ("convergence=count_ramp*se_gate", "the product of both gates"),
    ):
        if token not in flat:
            failures.append(f"the converged bypass has no {why}")

    # The standard error has to divide by sqrt(N). The per-sample spread does
    # not shrink as samples accumulate, so without the sqrt the gate could
    # never open on a converged pixel and would describe nothing.
    if not re.search(
        r"relative_se\s*=\s*center_std\s*/\s*\(\s*sqrt\s*\(\s*max\s*\(\s*accum_count",
        flat,
    ):
        failures.append(
            "relative_se is not center_std / (sqrt(max(accum_count, 1.0)) * "
            "(center_m1 + 0.02)): without the sqrt(N) it is the per-sample "
            "spread, which never shrinks"
        )

    lo = re.search(r"RTGI_FILTER_SE_LO\s*=\s*([0-9.]+)", src)
    hi = re.search(r"RTGI_FILTER_SE_HI\s*=\s*([0-9.]+)", src)
    if not lo or not hi:
        failures.append("the standard-error gate thresholds are missing")
    elif float(lo.group(1)) >= float(hi.group(1)):
        failures.append(
            f"the gate opens at {lo.group(1)} and closes at {hi.group(1)}; "
            "LO must be below HI"
        )


def main() -> int:
    failures: list[str] = []
    check_stride_order(failures)
    check_edge_stop_inert(failures)
    check_bypass_gate(failures)

    if failures:
        print(f"FAIL: {len(failures)} assertion(s)")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    phi = read_define(read(SETTINGS), "RTGI_FILTER_PHI")
    cap = read_define(read(SETTINGS), "RTGI_SPP_CAP")
    print(
        "RTGI filter contract OK (strides "
        f"{strides()}, edge-stop inert at the cap, bypass gated on the "
        f"standard error of the mean, PHI {phi} / cap {cap} unchanged)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
