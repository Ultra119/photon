#!/usr/bin/env python3
"""Assert the P3 joint bilateral RTGI upsample.

The GI buffer is RTGI_RESOLUTION-scaled, so deferred4 has to upsample it. The
fetch that used to be here was a bare bilinear textureLod, and bilinear cannot
tell a foreground surface from the wall behind it: at every depth silhouette it
blended the two, bleeding indirect light around object edges and adding 2x2
blockiness on top of the filter's square support.

This check carries a compact CPU model of that, because the interesting claim is
not "the code looks bilateral" but "the silhouette error really drops". A model
that only greps the source would pass on an upsample that is bilateral and
useless.

Exit code 0 means every assertion held.
"""
from __future__ import annotations

import pathlib
import re
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHADERS = ROOT / "shaders"
DIFFUSE = SHADERS / "include/lighting/diffuse_lighting.glsl"

LEAK = 0.15          # cross-surface contamination baked into each GI texel
NORMAL_EXP = 32.0    # must match the exponent in the shader
SIGMA_Z_REL = 0.05   # must match the relative depth tolerance in the shader


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


# --------------------------------------------------------------------------
# CPU model: full-res scene, half-res GI buffer, both upsamplers.
# --------------------------------------------------------------------------

def build(n: int = 96):
    yy, xx = np.mgrid[0:n, 0:n]
    detail = (0.05*np.sin(xx*2*np.pi/13.0)
              + 0.035*np.sin(yy*2*np.pi/9.0 + 1.0)
              + 0.030*np.sin((xx+yy)*2*np.pi/6.0))

    depth = np.full((n, n), 20.0)
    normal = np.tile(np.array([0.0, 0.0, 1.0]), (n, n, 1))
    gi = 0.80 + detail

    def place(mask, d, nvec, g):
        for c in range(3):
            normal[..., c] = np.where(mask, nvec[c], normal[..., c])
        depth[mask] = d
        gi[mask] = g + detail[mask]

    # box only 2 units in front of the wall: the depth term has to do the work
    box = (np.abs(xx - n*0.27) < n*0.12) & (np.abs(yy - n*0.72) < n*0.12)
    place(box, 18.0, np.array([-0.62, 0.30, 0.72]), 0.35)
    # object far in front: large depth gap
    far = (np.abs(xx - n*0.69) < n*0.15) & (np.abs(yy - n*0.31) < n*0.15)
    place(far, 6.0, np.array([0.45, 0.0, 0.89]), 0.20)

    # half-resolution GI buffer; each texel straddles the silhouette
    h = n // 2
    g_depth = np.zeros((h, h)); g_gi = np.zeros((h, h))
    g_norm = np.zeros((h, h, 3))
    for j in range(h):
        for i in range(h):
            blk_d = depth[2*j:2*j+2, 2*i:2*i+2].ravel()
            maj = np.bincount(np.round(blk_d).astype(int)).argmax()
            w = np.where(np.round(blk_d) == maj, 1.0 - LEAK, LEAK)
            w = w / w.sum()
            g_gi[j, i] = float((w*gi[2*j:2*j+2, 2*i:2*i+2].ravel()).sum())
            g_depth[j, i] = float((w*blk_d).sum())
            for c in range(3):
                g_norm[j, i, c] = float(
                    (w*normal[2*j:2*j+2, 2*i:2*i+2, c].ravel()).sum())

    def band(mask, k=3):
        o = mask.copy()
        for _ in range(k):
            o = (o | np.roll(o, 1, 0) | np.roll(o, -1, 0)
                 | np.roll(o, 1, 1) | np.roll(o, -1, 1))
        return o
    edge = band(box ^ np.roll(box, 1, 0)) | band(box ^ np.roll(box, 1, 1)) \
        | band(far ^ np.roll(far, 1, 0)) | band(far ^ np.roll(far, 1, 1))
    inside = np.zeros((n, n), bool); inside[6:-6, 6:-6] = True
    return gi, depth, normal, g_gi, g_depth, g_norm, edge & inside


def measure():
    gi, depth, normal, g_gi, g_depth, g_norm, edge = build()
    n = gi.shape[0]
    h = n // 2
    yy, xx = np.mgrid[0:n, 0:n]
    coord = np.stack([(xx + 0.5) * 0.5, (yy + 0.5) * 0.5], axis=-1)

    fx = np.clip(coord[..., 0] - 0.5, 0, h - 1)
    fy = np.clip(coord[..., 1] - 0.5, 0, h - 1)
    x0 = np.floor(fx).astype(int); y0 = np.floor(fy).astype(int)
    x1 = np.minimum(x0 + 1, h - 1); y1 = np.minimum(y0 + 1, h - 1)
    tx = fx - x0; ty = fy - y0

    b_num = np.zeros((n, n))
    j_num = np.zeros((n, n)); j_den = np.zeros((n, n))
    for xs, ys, wb in ((x0, y0, (1-tx)*(1-ty)), (x1, y0, tx*(1-ty)),
                       (x0, y1, (1-tx)*ty), (x1, y1, tx*ty)):
        b_num += wb*g_gi[ys, xs]
        wd = np.exp(-np.abs(g_depth[ys, xs] - depth)/(SIGMA_Z_REL*depth))
        nd = np.sum(g_norm[ys, xs]*normal, axis=-1)
        j_num += wb*wd*np.power(np.maximum(nd, 0.0), NORMAL_EXP)*g_gi[ys, xs]
        j_den += wb*wd*np.power(np.maximum(nd, 0.0), NORMAL_EXP)
    joint = j_num/np.maximum(j_den, 1e-6)

    out = {}
    for name, est in (("bilinear", b_num), ("joint", joint)):
        d = est - gi
        out[name] = (float(np.sqrt(np.mean(d**2))),
                     float(np.sqrt(np.mean(d[edge]**2))))
    return out


def check_model(failures: list[str]) -> dict[str, tuple[float, float]]:
    """The upsample has to actually beat bilinear where it matters."""
    res = measure()
    b_all, b_edge = res["bilinear"]
    j_all, j_edge = res["joint"]
    if j_edge >= b_edge / 3.5:
        failures.append(
            f"joint bilateral silhouette rmse {j_edge:.4f} is not at least 3.5x "
            f"better than bilinear {b_edge:.4f}; the upsample is not earning "
            "its taps"
        )
    if j_all >= b_all / 1.8:
        failures.append(
            f"joint bilateral rmse {j_all:.4f} is not at least 1.8x better than "
            f"bilinear {b_all:.4f} overall"
        )
    return res


def check_wiring(failures: list[str]) -> None:
    """The shader has to do what the model assumed."""
    if not DIFFUSE.is_file():
        failures.append(f"missing {DIFFUSE}")
        return
    src = strip_comments(read(DIFFUSE))
    flat = "".join(src.split())

    # Not the bare bilinear any more.
    if "vec4sample_rtgi_smooth(sampler2Drtgi_sampler,vec2coord){returntextureLod" in flat:
        failures.append(
            "sample_rtgi_smooth is still a single bilinear textureLod; it "
            "cannot tell a foreground surface from the wall behind it"
        )

    for token, why in (
        ("center_linear_depth", "the full-res pixel's linear depth"),
        ("center_world_normal", "the full-res pixel's world normal"),
        ("weight_depth", "a depth-similarity weight per tap"),
        ("weight_normal", "a normal-similarity weight per tap"),
        ("decode_unit_vector(t_aux.ba)",
         "the GI-resolution normal from the P1 aux channel"),
        ("linearize_depth", "linearised depth, so the tolerance is in distance"),
        ("(frameCounter&1)==0", "the ping-pong half written this frame"),
    ):
        if token not in flat:
            failures.append(f"the upsample does not use {why}")

    # Every tap can be rejected at a silhouette, so there must be a fallback.
    if "sum_weight>1e-4" not in flat:
        failures.append(
            "the upsample has no fallback when every tap is rejected; a "
            "silhouette pixel whose surface is absent from the GI buffer "
            "would divide by zero"
        )

    # The tolerances the model was measured with.
    if not re.search(r"sigma_z\s*=\s*max\s*\(\s*0\.05\s*\*\s*center_linear_depth", flat):
        failures.append(
            "sigma_z is not 0.05 * center_linear_depth; the CPU model in this "
            "test was measured with that relative tolerance"
        )
    if "32.0" not in flat:
        failures.append("the normal exponent is not the 32.0 this test models")


def main() -> int:
    failures: list[str] = []
    check_wiring(failures)
    res = check_model(failures)

    if failures:
        print(f"FAIL: {len(failures)} assertion(s)")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    b_all, b_edge = res["bilinear"]
    j_all, j_edge = res["joint"]
    print(
        "RTGI upsample contract OK (joint bilateral: rmse "
        f"{b_all:.4f} -> {j_all:.4f} overall, {b_edge:.4f} -> {j_edge:.4f} on "
        "the silhouette band)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
