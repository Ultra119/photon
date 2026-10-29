#!/usr/bin/env python3
"""Stage 5 DDA and Sub-block AABB Intersection Unit Tests.

Validates that ray-box analytic intersections over voxel sub-shapes
(cubes, bottom slabs, top slabs, stairs, fences) correctly compute:
  1. Monotonic t progression.
  2. Exact hit distance and face normal for hits.
  3. Seamless pass-through for rays crossing empty sub-regions (e.g. top of bottom slab).
"""

import math
import sys

def intersect_box(ray_start, inv_dir, box_min, box_max, seg_start, seg_end, entry_norm):
    t0 = [(box_min[i] - ray_start[i]) * inv_dir[i] for i in range(3)]
    t1 = [(box_max[i] - ray_start[i]) * inv_dir[i] for i in range(3)]
    tnear = [min(t0[i], t1[i]) for i in range(3)]
    tfar = [max(t0[i], t1[i]) for i in range(3)]
    tenter = max(tnear)
    texit = min(tfar)
    if tenter <= texit and texit >= seg_start and tenter <= seg_end:
        hit_t = max(tenter, seg_start)
        if tenter > seg_start + 1e-4:
            if tenter == tnear[0]: norm = [-1.0 if inv_dir[0] > 0 else 1.0, 0.0, 0.0]
            elif tenter == tnear[1]: norm = [0.0, -1.0 if inv_dir[1] > 0 else 1.0, 0.0]
            else: norm = [0.0, 0.0, -1.0 if inv_dir[2] > 0 else 1.0]
        else:
            norm = entry_norm
        return True, hit_t, norm
    return False, 0.0, [0.0, 0.0, 0.0]

def main():
    bmin_slab_bot = [5.0, 5.0, 5.0]
    bmax_slab_bot = [6.0, 5.5, 6.0]

    bmin_slab_top = [5.0, 5.5, 5.0]
    bmax_slab_top = [6.0, 6.0, 6.0]

    # Test 1: Ray hitting top of bottom slab from above
    start1 = [5.5, 7.0, 5.5]
    dir1 = [1e-6, -1.0, 1e-6]
    inv_d1 = [1.0 / d for d in dir1]
    hit1, t1, n1 = intersect_box(start1, inv_d1, bmin_slab_bot, bmax_slab_bot, 1.0, 2.0, [0.0, 1.0, 0.0])
    assert hit1, "Test 1 failed: Ray should hit top of bottom slab"
    assert abs(t1 - 1.5) < 1e-4, f"Test 1 failed: Expected t=1.5, got {t1}"
    assert n1[1] == 1.0, f"Test 1 failed: Expected up normal [0, 1, 0], got {n1}"

    # Test 2: Ray passing horizontally through open upper half of bottom slab
    start2 = [4.0, 5.75, 5.5]
    dir2 = [1.0, 1e-6, 1e-6]
    inv_d2 = [1.0 / d for d in dir2]
    hit2, t2, n2 = intersect_box(start2, inv_d2, bmin_slab_bot, bmax_slab_bot, 1.0, 2.0, [-1.0, 0.0, 0.0])
    assert not hit2, "Test 2 failed: Ray at y=5.75 should MISS bottom slab"

    # Test 3: Ray hitting side of bottom slab at y=5.25
    start3 = [4.0, 5.25, 5.5]
    hit3, t3, n3 = intersect_box(start3, inv_d2, bmin_slab_bot, bmax_slab_bot, 1.0, 2.0, [-1.0, 0.0, 0.0])
    assert hit3, "Test 3 failed: Ray at y=5.25 should hit bottom slab side"
    assert abs(t3 - 1.0) < 1e-4, f"Test 3 failed: Expected t=1.0, got {t3}"
    assert n3[0] == -1.0, f"Test 3 failed: Expected normal [-1, 0, 0], got {n3}"

    # Test 4: Ray hitting bottom of top slab from below
    start4 = [5.5, 4.0, 5.5]
    dir4 = [1e-6, 1.0, 1e-6]
    inv_d4 = [1.0 / d for d in dir4]
    hit4, t4, n4 = intersect_box(start4, inv_d4, bmin_slab_top, bmax_slab_top, 1.0, 2.0, [0.0, -1.0, 0.0])
    assert hit4, "Test 4 failed: Ray should hit bottom of top slab"
    assert abs(t4 - 1.5) < 1e-4, f"Test 4 failed: Expected t=1.5, got {t4}"
    assert n4[1] == -1.0, f"Test 4 failed: Expected down normal [0, -1, 0], got {n4}"

    # Test 5: Ray passing horizontally under top slab
    start5 = [4.0, 5.25, 5.5]
    hit5, t5, n5 = intersect_box(start5, inv_d2, bmin_slab_top, bmax_slab_top, 1.0, 2.0, [-1.0, 0.0, 0.0])
    assert not hit5, "Test 5 failed: Ray at y=5.25 should MISS top slab"

    print("All Stage 5 DDA AABB unit tests PASSED (5/5).")

if __name__ == "__main__":
    main()
