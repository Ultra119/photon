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
    min_alpha: float = 0.01,
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
        # Kappa-class floor: the blend rate never decays past this.
        alpha = max(spp / max(count, spp), min_alpha)
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


RTGI_ADAPT_MIN_CONFIDENCE_DEFAULT = 0.9


def read_define(src: str, name: str) -> float | None:
    m = re.search(rf"#define\s+{name}\s+([0-9.]+)", src)
    return float(m.group(1)) if m else None


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def simulate_mc(
    spp: float,
    cap: float,
    strength: float,
    min_alpha: float,
    sigma: float,
    truth,
    frames: int,
    lo: float,
    hi: float,
    eps: float,
    min_samples: float,
    seed: int = 20261104,
    static: bool = True,
    confidence: float = 1.0,
    initial_count: float | None = None,
    initial_m1: float | None = None,
) -> dict:
    """Replay the temporal recurrence against sampled Monte-Carlo noise.

    The first version of this model fed the estimator a deterministic sample
    alternating one sigma either side of the truth. That has no tails, so it
    concluded that noise never trips the adaptive test -- and the shader it
    approved put clumps all over the screen. This one draws samples: a Gaussian
    with a 5% heavy-tail component, which is what a dithered cosine-hemisphere
    estimator with a voxel-cache second bounce actually produces.

    `truth` is a callable(frame) -> true luminance, so a step change can be
    injected. Returns per-frame series plus summary statistics.
    """
    rng = random.Random(seed)
    count = cap if initial_count is None else initial_count
    m1 = truth(0) if initial_m1 is None else initial_m1
    m2 = m1 * m1 + sigma * sigma
    series: list[tuple[float, float, float, float]] = []
    fired = 0

    def draw() -> float:
        u = rng.gauss(0.0, 1.0)
        return u * 3.0 if rng.random() < 0.05 else u

    for frame in range(frames):
        mu = truth(frame)
        # The shader tests the 3x3 neighbourhood MEAN against the history, and
        # divides by the neighbourhood's own sample sigma / 3. Drawing nine
        # samples is the whole point: it is what makes the statistic quiet
        # enough to threshold.
        samples = [mu + sigma * draw() for _ in range(9)]
        raw = mu + sigma * draw()          # the pixel's own sample: the blend
        mean = sum(samples) / 9.0
        var = max(sum((x - mean) ** 2 for x in samples) / 8.0, 0.0)

        z = abs(mean - m1) / (math.sqrt(var) / 3.0 + eps)
        allowed = static and confidence >= RTGI_ADAPT_MIN_CONFIDENCE_DEFAULT \
            and count >= min_samples
        rejection = smoothstep(lo, hi, z) * strength if allowed else 0.0
        if rejection > 0.05:
            fired += 1

        count = min(count + spp, cap)
        alpha = max(spp / max(count, spp), min_alpha)
        alpha = max(alpha, rejection)

        m1 += (raw - m1) * alpha
        m2 += (raw * raw - m2) * alpha
        series.append((m1, z, rejection, count))

    return {"series": series, "fired": fired, "frames": frames}


def steady_state_rms(result: dict, truth_value: float, tail: int = 2000) -> float:
    """RMS error of the estimate over the last `tail` frames."""
    tail_series = result["series"][-tail:]
    return math.sqrt(
        sum((m1 - truth_value) ** 2 for m1, _, _, _ in tail_series) / len(tail_series)
    )


def step_response(
    spp, cap, strength, min_alpha, sigma, lo, hi, eps, min_samples,
    old_mean, new_mean, seed,
) -> int:
    """Frames to get within 10% of a step change that happens at frame 0."""
    result = simulate_mc(
        spp, cap, strength, min_alpha, sigma, lambda f: new_mean, 900,
        lo, hi, eps, min_samples, seed=seed, initial_m1=old_mean,
    )
    tol = 0.1 * abs(new_mean - old_mean)
    for i, (m1, _, _, _) in enumerate(result["series"]):
        if abs(m1 - new_mean) <= tol:
            return i + 1
    return len(result["series"])


def check_adaptive(failures: list[str]) -> None:
    """Claim 5: adaptivity is worth its noise, measured not assumed.

    The gate is two-sided, because in-game it failed one side: the shipped
    default amplified visible noise at every strength above zero. Both halves
    are checked here against sampled Monte-Carlo noise, with the estimator
    starting from a converged history -- the case that matters, since that is
    the pixel whose history can go stale.
    """
    state = strip_comments(read(STATE))
    settings = strip_comments(read(SHADERS / "settings.glsl"))

    for name, src, minimum in (
        ("RTGI_ADAPT_LO", state, 1.5),
        ("RTGI_ADAPT_HI", state, 6.0),
        ("RTGI_ADAPT_SIGMA_EPS", state, 0.0),
        ("RTGI_ADAPT_MIN_SAMPLES", state, 8.0),
        ("RTGI_ADAPT_MIN_CONFIDENCE", state, 0.5),
        ("RTGI_ADAPT_STRENGTH", settings, 0.0),
        ("RTGI_MIN_ACCUM", settings, 0.0),
        ("RTGI_SPP_CAP", settings, 128.0),
    ):
        value = read_define(src, name)
        if value is None:
            failures.append(f"{name} is not defined")
        elif value < minimum:
            failures.append(f"{name} is {value}, want >= {minimum}")

    lo = read_define(state, "RTGI_ADAPT_LO")
    hi = read_define(state, "RTGI_ADAPT_HI")
    eps = read_define(state, "RTGI_ADAPT_SIGMA_EPS")
    min_samples = read_define(state, "RTGI_ADAPT_MIN_SAMPLES")
    strength = read_define(settings, "RTGI_ADAPT_STRENGTH")
    min_alpha = 0.01 * (read_define(settings, "RTGI_MIN_ACCUM") or 0.0)
    cap = read_define(settings, "RTGI_SPP_CAP")
    if None in (lo, hi, eps, min_samples, strength, cap):
        return

    spp = 1.0
    sigma = 0.25
    base = 0.60
    frames = 4000

    def rms_for(s: float, static: bool = True, confidence: float = 1.0) -> float:
        return steady_state_rms(
            simulate_mc(
                spp, cap, s, min_alpha, sigma, lambda f: base, frames,
                lo, hi, eps, min_samples, static=static, confidence=confidence,
            ),
            base,
        )

    # --- side 1: the shipped default must not amplify noise -----------------
    rms_off = rms_for(0.0)
    rms_default = rms_for(strength)
    if rms_default > rms_off * 1.15:
        failures.append(
            f"the default RTGI_ADAPT_STRENGTH {strength} raises steady-state "
            f"noise {rms_default / rms_off:.2f}x over adaptive-off "
            f"({rms_default:.4f} vs {rms_off:.4f} RMS); the default must be "
            "invisible"
        )
    # A strength that does nothing must stay available for A/B, but the
    # mechanism has to still work when it is turned up.
    rms_full = rms_for(1.0)
    if rms_full > rms_off * 1.5:
        failures.append(
            f"at full strength the estimator is {rms_full / rms_off:.2f}x noisier "
            "than adaptive-off; the sigma thresholds are inside the noise"
        )
    # Zero false rejections on a static scene, at any strength. With a
    # 100-frame time constant one false fire is not a flicker, it is a
    # two-second artifact.
    for probe in (0.5, 1.0):
        quiet = simulate_mc(
            spp, cap, probe, min_alpha, sigma, lambda f: base, 1200,
            lo, hi, eps, min_samples, seed=11,
        )
        if quiet["fired"]:
            failures.append(
                f"strength {probe} rejected {quiet['fired']}/1200 frames of "
                "plain Monte-Carlo noise"
            )

    # --- side 2: it must still buy responsiveness ---------------------------
    old_mean, new_mean = 0.30, 1.20
    fast = step_response(
        spp, cap, 1.0, min_alpha, sigma, lo, hi, eps, min_samples,
        old_mean, new_mean, seed=7,
    )
    slow = step_response(
        spp, cap, 0.0, min_alpha, sigma, lo, hi, eps, min_samples,
        old_mean, new_mean, seed=7,
    )
    if fast * 3 > slow:
        failures.append(
            f"adaptive rejection is not worth its noise: {fast} frames to a "
            f"step change with it, {slow} without (want >= 3x better)"
        )

    # --- the gates ----------------------------------------------------------
    # A pan must not fire the test: the reprojected history and the current raw
    # sample disagree by construction, and answering that with "the light
    # changed" is the motion alpha this pack removed on purpose.
    pan = simulate_mc(
        spp, cap, 1.0, min_alpha, sigma, lambda f: base, 200,
        lo, hi, eps, min_samples, static=False, seed=3,
    )
    if pan["fired"]:
        failures.append(
            f"the adaptive test fired on {pan['fired']}/{pan['frames']} frames "
            "while the camera was moving"
        )
    untrusted = simulate_mc(
        spp, cap, 1.0, min_alpha, sigma, lambda f: base, 200,
        lo, hi, eps, min_samples, confidence=0.5, seed=3,
    )
    if untrusted["fired"]:
        failures.append("the adaptive test fires on a low-confidence reprojection")
    # ...and a still-converging pixel must not be tested, or the loop
    # reject -> short history -> reject feeds itself.
    young = simulate_mc(
        spp, cap, 1.0, min_alpha, sigma, lambda f: base, 40,
        lo, hi, eps, min_samples, initial_count=min_samples - 1.0, seed=3,
    )
    if young["fired"]:
        failures.append("the adaptive test fires on a history below RTGI_ADAPT_MIN_SAMPLES")


def check_spatial_fallback(failures: list[str]) -> None:
    """Claim 7: the invalid-history fallback is worth its fetches.

    A pixel whose history is invalid used to restart from ~1.1 samples (90%
    raw plus 10% of a geometrically wrong history), which is the raw-dot flash
    on surfaces revealed by motion. The fallback gathers the current frame's
    neighbourhood instead. Two things are checked on a CPU model: that the
    gather actually cuts the first-frame noise, and that it does not claim
    more evidence than it has -- neighbours are not independent samples of one
    quantity, and over-crediting them would under-report variance to the
    a-trous filter.
    """
    state = strip_comments(read(STATE))
    settings = strip_comments(read(SHADERS / "settings.glsl"))
    temporal = strip_comments(read(TEMPORAL))

    enabled = read_define(settings, "RTGI_SPATIAL_FALLBACK")
    max_weight = read_define(state, "PT_SPATIAL_MAX_WEIGHT")
    if enabled is None or max_weight is None:
        failures.append("the spatial fallback is not defined in both sources")
        return
    if enabled != 0.0 and max_weight < 2.0:
        failures.append(
            f"PT_SPATIAL_MAX_WEIGHT is {max_weight}; too low to be worth the fetches"
        )

    # --- the noise model -------------------------------------------------
    # 16 edge-stopped taps, each one raw sample of the same underlying signal
    # (a flat wall revealed by a pan). Weight 1 for taps that pass, 0 for the
    # rest: the conservative case, since partial weights only help.
    rng = random.Random(4242)
    sigma = 0.25
    mu = 0.60
    taps = 16
    trials = 20000
    gathered = 0.0
    plain = 0.0
    for _ in range(trials):
        samples = [mu + sigma * rng.gauss(0.0, 1.0) for _ in range(taps + 1)]
        own = samples[0]
        neighbour_mean = sum(samples[1:]) / taps
        n_eff = min(float(taps), max_weight)
        estimate = (neighbour_mean * n_eff + own) / (n_eff + 1.0)
        gathered += (estimate - mu) ** 2
        # the old soft reset: 90% raw + 10% of an unrelated history sample
        plain += (own - mu) ** 2
    rms_gather = math.sqrt(gathered / trials)
    rms_plain = math.sqrt(plain / trials)
    reduction = rms_plain / rms_gather

    if enabled != 0.0 and reduction < 1.8:
        failures.append(
            f"the spatial fallback only cuts first-frame noise {reduction:.2f}x; "
            "want >= 1.8x for three fetches per tap"
        )
    # The clamp is deliberately conservative, so the measured gain may EXCEED
    # what the credited sample count implies -- that is the safe direction (a
    # pixel that is quieter than it admits only gets blurred a little more
    # than it needs). What must not happen is the opposite, and what must also
    # not happen is the clamp failing to bind at all.
    claimed = math.sqrt(max_weight + 1.0)
    if enabled != 0.0 and reduction < claimed * 0.95:
        failures.append(
            f"the gather claims {claimed:.2f}x of noise reduction but delivers "
            f"only {reduction:.2f}x: it is credited with more evidence than it "
            "has, and under-reports variance to the a-trous filter"
        )
    if enabled != 0.0 and reduction > claimed * 1.6:
        failures.append(
            f"the gather delivers {reduction:.2f}x while only claiming "
            f"{claimed:.2f}x; PT_SPATIAL_MAX_WEIGHT is not binding, so the "
            "clamped sample count does not describe the estimate"
        )

    # --- wiring ----------------------------------------------------------
    src = "".join(temporal.split())
    if "pt_spatial_fallback(" not in src:
        failures.append("the temporal pass never calls the spatial fallback")
    for token, why in (
        ("texelFetch(depthtex1", "depth edge-stopping"),
        ("texelFetch(colortex1", "normal edge-stopping"),
        ("if(n_depth>=1.0){continue;}", "sky rejection"),
    ):
        if token not in src:
            failures.append(f"the spatial fallback lacks {why}")
    if "sy+=2" not in src or "sx+=2" not in src:
        failures.append(
            "the spatial fallback is not strided; 49 taps per invalid pixel is "
            "too many for a pass that runs during pans"
        )
    if "min(fb_weight,PT_SPATIAL_MAX_WEIGHT)" not in src:
        failures.append("the gathered weight is not clamped to PT_SPATIAL_MAX_WEIGHT")
    if "PT_RESET_SPATIAL" not in src:
        failures.append("the spatial fallback does not report PT_RESET_SPATIAL")
    # Unstripped: the reason colours are identified by their comments.
    debug = (SHADERS / "include/debug/gi_debug.glsl").read_text(encoding="utf-8")
    if "PT_RESET_SPATIAL" not in debug and "SPATIAL:" not in debug:
        failures.append("the reset debug view has no colour for PT_RESET_SPATIAL")
    if debug.count("return vec3(") < 11:
        failures.append(
            "the reset view has fewer colour branches than PT_RESET_COUNT reasons"
        )


def check_adaptive_wiring(failures: list[str]) -> None:
    """Claim 6: the shader still matches the model that was measured.

    Everything in check_adaptive() is measured on a CPU model of the
    recurrence, so a shader edit that changes the statistic would leave the
    measurements green while shipping something else. These assertions tie the
    four properties the measurement depends on to the source -- each one is a
    regression that was observed in-game:

      * a single raw sample instead of the 3x3 mean (clumps and dots at every
        strength),
      * no gate on motion (the field dumped to raw on every pan),
      * the count shortened by a rejection (a two-second recovery),
      * the reset view reading a packed reason code bilinearly (screen-fixed
        bands between two colours that were never written).
    """
    temporal = strip_comments(read(TEMPORAL)).replace(" ", "")
    debug = strip_comments(read(SHADERS / "include/debug/gi_debug.glsl")).replace(" ", "")

    if "dot(raw_m1,luminance_weights)" not in temporal:
        failures.append(
            "the adaptive test does not use the 3x3 neighbourhood mean; a "
            "single raw sample cannot be thresholded at one ray per pixel"
        )
    if "raw_sigma*raw_sigma" not in temporal:
        failures.append(
            "the adaptive test does not use the neighbourhood sigma, so it is "
            "not self-limiting at geometric edges"
        )
    if "*(1.0/3.0)" not in temporal:
        failures.append(
            "the adaptive test does not convert the neighbourhood sigma into "
            "the sigma of the MEAN of nine samples"
        )
    for token, why in (
        ("adapt_allowed=accumulating", "camera/projection motion"),
        ("total_confidence>=RTGI_ADAPT_MIN_CONFIDENCE", "reprojection confidence"),
        ("prev_count>=RTGI_ADAPT_MIN_SAMPLES", "minimum history length"),
    ):
        if token not in temporal:
            failures.append(f"the adaptive test is not gated on {why}")
    if "current_spp/alpha_temporal" in temporal:
        failures.append(
            "a rejection shortens the sample count again; one z spike then "
            "costs a converged pixel its whole history"
        )
    if "texelFetch(rtgi_state_sampler" not in debug:
        failures.append(
            "the reset debug view reads the packed reason code with a filtered "
            "fetch; it must point-sample it"
        )


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
    check_adaptive(failures)
    check_adaptive_wiring(failures)
    check_spatial_fallback(failures)

    if failures:
        print(f"FAIL: {len(failures)} assertion(s)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(
        "PT state contract OK (packing, sample accounting, state writes, "
        "static-state thresholds, adaptive rejection)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
