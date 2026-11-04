#!/usr/bin/env python3
"""Assert the P1 reconstruction state contract holds end to end.

The PT chain stores its reconstruction state across four images and two
packing schemes. None of the failure modes below are visible to a compiler:

1. The packed aux channel must round-trip exactly. It is stored in an rgba16f
   image, so a layout whose maximum value exceeds 2048 silently corrupts the
   sample count and the sky fraction on every pixel.

2. The temporal blend must be driven by accumulated SAMPLES, not frames. The
   old code did `alpha = 1.0 / n_frames`, which is only correct when a frame
   contributes exactly one ray; at eight rays per pixel per frame it threw
   away seven eighths of the evidence.

3. Every exit path of the temporal pass must write the state image. A texel
   nobody writes keeps last frame's reset reason forever, and the reset view
   then lies about the one pixel you are looking at.

Exit code 0 means every assertion held.
"""
from __future__ import annotations

import math
import pathlib
import random
import re
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHADERS = ROOT / "shaders"

STATE = SHADERS / "include/lighting/rt/pt_state.glsl"
TEMPORAL = SHADERS / "program/rtgi/rtgi_temporal.csh"
TRACE = SHADERS / "program/rtgi/rtgi_trace.csh"

# fp16 stores every integer up to 2048 exactly.
FP16_EXACT_MAX = 2048


def f32(x: float) -> float:
    """Round to float32, the precision shaders use for these uniforms."""
    return struct.unpack("f", struct.pack("f", x))[0]


def glsl_round(x: float) -> float:
    """GLSL round(): halfway cases away from zero. Python's round() is not."""
    return math.floor(x + 0.5) if x >= 0.0 else math.ceil(x - 0.5)


def clamp(x: float, lo: float, hi: float) -> float:
    return min(max(x, lo), hi)


def read(path: pathlib.Path) -> str:
    return path.read_text()


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def check_packing(failures: list[str]) -> None:
    """Claim 1: the aux layout round-trips and fits in fp16."""
    if not STATE.is_file():
        failures.append(f"missing {STATE}")
        return

    src = strip_comments(read(STATE))

    # Pull the constants out of the shader instead of hardcoding them, so a
    # layout change that breaks the budget fails here rather than in game.
    m = re.search(
        r"float pack_sky_count\(float sky, float count\)\s*\{(.*?)\n\}",
        src,
        re.S,
    )
    if not m:
        failures.append("pack_sky_count() not found in pt_state.glsl")
        return
    body = m.group(1)
    sky_levels = re.search(r"clamp01\(sky\)\s*\*\s*([0-9.]+)", body)
    count_max = re.search(r"clamp\(round\(count\),\s*0\.0,\s*([0-9.]+)\)", body)
    count_scale = re.search(r"return sky_i \+ count_i \* ([0-9.]+);", body)
    if not (sky_levels and count_max and count_scale):
        failures.append("could not parse the pack_sky_count() constants")
        return

    sky_max_i = int(float(sky_levels.group(1)))
    count_max_i = int(float(count_max.group(1)))
    scale = int(float(count_scale.group(1)))
    if scale <= sky_max_i:
        failures.append(
            f"pack scale {scale} does not separate the sky field (max {sky_max_i})"
        )
        return

    worst = sky_max_i + count_max_i * scale
    if worst > FP16_EXACT_MAX:
        failures.append(
            f"packed value reaches {worst}, above the fp16 exact-integer limit "
            f"{FP16_EXACT_MAX}; the aux channel would corrupt"
        )

    # Unpacker must mirror the packer's constants.
    u = re.search(
        r"vec2 unpack_sky_count\(float packed\)\s*\{(.*?)\n\}", src, re.S
    )
    if not u:
        failures.append("unpack_sky_count() not found in pt_state.glsl")
        return
    ubody = u.group(1)
    if f"1.0 / {float(scale)}" not in ubody and f"/ {float(scale)}" not in ubody:
        failures.append("unpack_sky_count() does not divide by the pack scale")
    if f"1.0 / {float(sky_max_i)}" not in ubody:
        failures.append("unpack_sky_count() does not divide by the sky level count")

    # Exhaustive round trip over every representable (sky, count) pair.
    bad = 0
    for count_i in range(count_max_i + 1):
        for sky_i in range(sky_max_i + 1):
            sky = sky_i / float(sky_max_i)
            packed = float(sky_i) + count_i * scale
            got_count = math.floor(packed / scale)
            got_sky = (packed - got_count * scale) / float(sky_max_i)
            if got_count != count_i or abs(got_sky - sky) > 1e-12:
                bad += 1
    if bad:
        failures.append(f"{bad} pack_sky_count() round trips failed")
    if count_max_i < 63:
        failures.append(
            f"sample count caps at {count_max_i}; P2 needs at least 63 to be "
            "able to raise the accumulation cap"
        )


def simulate(
    spp: float,
    cap: float,
    frames: int,
    moving: bool,
    initial_count: float = 0.0,
) -> list[tuple[float, float]]:
    """Replay the temporal pass's count/alpha recurrence. Returns (count, alpha).

    count == 0 models "no history at all" (first frame, or a resize that
    recreated the images): that frame's samples are the whole estimate.
    """
    out: list[tuple[float, float]] = []
    count = initial_count
    for _ in range(frames):
        if count <= 0.0:
            # Fresh start: this frame's rays are all there is.
            count = spp
        elif moving:
            # Camera moved: reprojected history is not new evidence.
            count = max(count, spp)
        else:
            count = min(count + spp, cap)
        alpha = spp / max(count, spp)
        out.append((count, alpha))
    return out


def check_spp_math(failures: list[str]) -> None:
    """Claim 2: alpha is driven by samples, and behaves at the cap."""
    src = strip_comments(read(TEMPORAL))

    for stale in ("RTGI_HISTORY_FRAMES", "pack_sky_age", "unpack_sky_age", "n_samples"):
        if stale in src:
            failures.append(f"rtgi_temporal.csh still references the pre-P1 {stale}")

    if not re.search(r"float current_spp = float\(RTGI_RAY_COUNT\);", src):
        failures.append(
            "the temporal pass does not derive its per-frame sample count from "
            "RTGI_RAY_COUNT"
        )
    if not re.search(
        r"min\(prev_count \+ current_spp, float\(RTGI_SPP_CAP\)\)", src
    ):
        failures.append(
            "the temporal pass does not add this frame's samples to the "
            "accumulated count under RTGI_SPP_CAP"
        )
    if not re.search(
        r"current_spp / max\(sample_count, current_spp\)", src
    ):
        failures.append(
            "the temporal blend is not spp / max(count, spp); a bare 1/n "
            "ignores the rays per pixel the tier actually traces"
        )

    # Invariants of the recurrence the shader above implements.
    cap = 32.0
    for spp in (1.0, 2.0, 4.0, 8.0):
        history = simulate(spp, cap, 200, moving=False)
        for i, (count, alpha) in enumerate(history):
            frames = i + 1
            if count > cap + 1e-9:
                failures.append(f"spp={spp}: count {count} exceeded cap {cap}")
                break
            if alpha > 1.0 + 1e-9:
                failures.append(f"spp={spp}: alpha {alpha} above 1 at frame {frames}")
                break
            if abs(alpha * count - spp) > 1e-6:
                failures.append(
                    f"spp={spp}: alpha*count = {alpha * count} != spp at frame {frames}"
                )
                break
            if i and alpha > history[i - 1][1] + 1e-9:
                failures.append(f"spp={spp}: alpha grew at frame {frames}")
                break
        # At one ray per pixel the new recurrence must reproduce the old 1/n.
        if spp == 1.0:
            for frames in (1, 2, 8, 32, 64):
                expected = 1.0 / min(frames, int(cap))
                got = simulate(1.0, cap, frames, moving=False)[-1][1]
                if abs(got - expected) > 1e-9:
                    failures.append(
                        f"spp=1 frame {frames}: alpha {got} != legacy 1/n {expected}"
                    )
        # The cap must mean the same amount of evidence at every ray count.
        final_count = simulate(spp, cap, 200, moving=False)[-1][0]
        if abs(final_count - cap) > 1e-9:
            failures.append(f"spp={spp}: settled at {final_count} samples, not {cap}")
        # ...and must be reached proportionally faster with more rays.
        frames_to_cap = next(
            i + 1 for i, (c, _) in enumerate(simulate(spp, cap, 200, False)) if c >= cap
        )
        if abs(frames_to_cap * spp - cap) > 1e-6:
            failures.append(
                f"spp={spp}: reached the cap in {frames_to_cap} frames, "
                f"expected {cap / spp}"
            )

    # A moving camera must hold the count, never grow it and never reset it.
    moving = simulate(1.0, cap, 40, moving=True)
    if any(c != moving[0][0] for c, _ in moving):
        failures.append("a moving camera changed the accumulated sample count")
    if abs(moving[0][1] - 1.0) > 1e-9:
        failures.append(
            "the first moving frame should not blend with history it has none of"
        )

    # A pan that starts from a converged field must not dump it: the count is
    # held, so alpha stays where the standstill left it.
    settled = simulate(1.0, cap, 60, moving=False)[-1]
    panning = simulate(1.0, cap, 60, moving=True, initial_count=settled[0])
    if any(abs(a - settled[1]) > 1e-9 for _, a in panning):
        failures.append("a pan starting from a converged field changed the blend rate")


def check_state_written(failures: list[str]) -> None:
    """Claim 3: no temporal exit path leaves the state image stale."""
    src = strip_comments(read(TEMPORAL))
    main = src[src.find("void main()"):]
    if not main:
        failures.append("rtgi_temporal.csh has no main()")
        return

    # Split on the return statements of main() and require that each segment
    # leading to one stores the state image (directly or via a helper that
    # does).
    segments = main.split("return;")
    for index, segment in enumerate(segments[:-1]):
        # The workgroup bounds guard is the one exit that legitimately writes
        # nothing: those invocations own no texel.
        if "target_res.x" in segment or "target_res.y" in segment:
            continue
        writes_state = (
            "imageStore(rtgi_state_img" in segment.replace(" ", "")
            or "write_state(" in segment
            or "write_zero(" in segment
        )
        if not writes_state:
            snippet = segment.strip().splitlines()[-6:]
            failures.append(
                f"temporal exit path {index} returns without writing "
                f"rtgi_state_img:\n    " + "\n    ".join(s.strip() for s in snippet)
            )

    # The helpers must actually store the image.
    for helper in ("write_state", "write_zero"):
        body = re.search(rf"void {helper}\(.*?\n\}}\n", src, re.S)
        if not body:
            failures.append(f"void {helper}() not found")
            continue
        text = body.group(0)
        if "rtgi_state_img" not in text.replace(" ", "") and "write_state(" not in text:
            failures.append(f"void {helper}() does not store rtgi_state_img")

    # The trace pass owns the valid-path fraction; the temporal pass must not
    # invent its own.
    trace = strip_comments(read(TRACE))
    if "valid_path_fraction" not in trace.replace(" ", ""):
        failures.append("rtgi_trace.csh does not compute a valid-path fraction")
    if "imageStore(rtgi_state_img" not in trace.replace(" ", ""):
        failures.append("rtgi_trace.csh does not write its valid-path fraction")


def check_static_state(failures: list[str]) -> None:
    """Claim 4: the static-state detector's thresholds are above float32 noise.

    The first version compared `1 - dot(normalize(v), normalize(v))` against
    1e-7. That expression does not return 0 for a camera at rest -- it returns
    a float32 rounding error -- so at some camera orientations a perfectly
    still camera was reported as moving and the sample count froze forever.
    The thresholds therefore have to be justified by measurement, and this
    check repeats the measurement instead of trusting a comment.
    """
    src = strip_comments(read(STATE))

    eps: dict[str, float] = {}
    for name in ("TRANSLATION", "ROTATION", "PROJECTION"):
        m = re.search(
            rf"#define PT_STATIC_{name}_EPS\s+([0-9.eE+-]+)", src
        )
        if m:
            eps[name] = float(m.group(1))
        else:
            failures.append(f"PT_STATIC_{name}_EPS not defined in pt_state.glsl")
    if len(eps) != 3:
        return

    if "pt_mat4_equal(model_view, previous_model_view)" not in src:
        failures.append(
            "the detector has no bit-exact matrix path; a tolerance alone is "
            "always one rounding error away from freezing the accumulator"
        )
    if "all(equal(camera_position, previous_camera_position))" not in src:
        failures.append("the detector has no bit-exact camera-position path")
    if re.search(r"rotation_delta < 1e-7", src):
        failures.append("the rotation threshold is still inside the float32 noise")

    # --- the measurement ------------------------------------------------
    # float32 self-dot of a normalised vector, over the whole orientation
    # space the camera can occupy.
    rng = random.Random(11)
    samples = 40000
    worst_positive = 0.0
    positive = 0
    for _ in range(samples):
        yaw = rng.uniform(-math.pi, math.pi)
        pitch = rng.uniform(-1.5, 1.5)
        v = (
            f32(f32(-math.sin(yaw)) * f32(math.cos(pitch))),
            f32(-math.sin(pitch)),
            f32(f32(-math.cos(yaw)) * f32(math.cos(pitch))),
        )
        length = f32(
            math.sqrt(
                f32(f32(v[0] * v[0]) + f32(f32(v[1] * v[1]) + f32(v[2] * v[2])))
            )
        )
        n = tuple(f32(c / length) for c in v)
        d = f32(f32(f32(n[0] * n[0]) + f32(n[1] * n[1])) + f32(n[2] * n[2]))
        err = f32(1.0 - d)
        if err > 0.0:
            positive += 1
            worst_positive = max(worst_positive, err)

    if worst_positive >= eps["ROTATION"]:
        failures.append(
            f"rotation eps {eps['ROTATION']:.3e} is inside the float32 self-dot "
            f"noise (worst measured {worst_positive:.3e}); the accumulator "
            f"freezes at some camera orientations"
        )
    margin = eps["ROTATION"] / worst_positive if worst_positive else math.inf
    if margin < 4.0:
        failures.append(
            f"rotation eps is only {margin:.1f}x the measured noise; want >= 4x"
        )

    # What the tolerance means on screen: a "static" frame may still pan this
    # far, so it has to stay well under a texel-ish distance.
    angle = math.sqrt(2.0 * eps["ROTATION"])            # radians per frame
    pixels = angle * (1920.0 / math.radians(90.0))      # at 1080p, 90 deg FOV
    if pixels > 3.0:
        failures.append(
            f"rotation eps allows {pixels:.1f} px/frame of pan to count as "
            "static; want < 3 px"
        )

    # The translation tolerance has to clear the float32 spacing of
    # cameraPosition, or a still camera far from the origin reads as moving.
    for distance in (1024.0, 4096.0, 8192.0):
        spacing = math.ulp(f32(distance))
        if eps["TRANSLATION"] <= spacing:
            failures.append(
                f"translation eps {eps['TRANSLATION']:.1e} is below the float32 "
                f"spacing of cameraPosition at {distance:.0f} blocks "
                f"({spacing:.1e})"
            )


def main() -> int:
    failures: list[str] = []
    check_packing(failures)
    check_spp_math(failures)
    check_state_written(failures)
    check_static_state(failures)

    if failures:
        print(f"FAIL: {len(failures)} assertion(s)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(
        "P1 state contract OK (packing, sample accounting, state writes, "
        "static-state thresholds)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
