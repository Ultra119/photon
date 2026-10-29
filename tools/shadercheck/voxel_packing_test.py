#!/usr/bin/env python3
"""Sanity-check the deterministic 32-bit voxel payload used by voxel_storage.glsl."""
import random

MASK = 0xFFFFFFFF

# Layout must match shaders/include/lighting/voxel/voxel_storage.glsl:
#   bits  0..14 : albedo RGB555
#   bits 15..18 : block light
#   bits 19..21 : shape class (3 bits: cube, slab, stairs, fence, pane, plant, glass, other)
#   bits 22..24 : flags
#   bits 25..31 : block ID
#
# imageAtomicMax() compares this unsigned integer, so block ID is the most
# significant field and air (0) always loses to any solid voxel.

def pack(bid, bl, shape, rgb, trans, emit):
    q = [min(31, max(0, int(c * 31 + 0.5))) for c in rgb]
    color = q[0] | (q[1] << 5) | (q[2] << 10)
    b = min(15, max(0, int(bl * 15 + 0.5)))
    s = shape & 7
    flags = (1 if trans else 0) | (2 if emit else 0)
    return (
        color
        | (b << 15)
        | (s << 19)
        | (flags << 22)
        | ((bid & 0x7F) << 25)
    ) & MASK

def unpack(p):
    return {
        "color": [(p & 31) / 31, ((p >> 5) & 31) / 31, ((p >> 10) & 31) / 31],
        "bl": ((p >> 15) & 15) / 15,
        "shape": (p >> 19) & 7,
        "flags": (p >> 22) & 7,
        "id": (p >> 25) & 0x7F,
    }

def main():
    rng = random.Random(129519)
    for _ in range(1000):
        bid = rng.randint(0, 127)
        bl = rng.random()
        shape = rng.randint(0, 7)
        rgb = [rng.random() for _ in range(3)]
        trans, emit = rng.random() < 0.5, rng.random() < 0.5
        u = unpack(pack(bid, bl, shape, rgb, trans, emit))
        assert u["id"] == bid
        assert u["shape"] == shape
        assert abs(u["bl"] - bl) <= 1 / 30 + 1e-9
        assert all(abs(a - b) <= 1 / 62 + 1e-9 for a, b in zip(u["color"], rgb))
        assert bool(u["flags"] & 1) == trans
        assert bool(u["flags"] & 2) == emit

    # Atomic-max priority: solid/high-ID payload beats air and lower IDs even
    # when the lower-ID payload has a brighter color.
    air = 0
    low = pack(4, 1.0, 0, [1.0, 1.0, 1.0], True, True)
    high = pack(96, 0.0, 0, [0.0, 0.0, 0.0], False, False)
    assert max(air, low, high) == high
    assert max(air, low) == low

    print("1000 randomized voxel pack/unpack round trips OK; atomic priority OK")

if __name__ == "__main__":
    main()
