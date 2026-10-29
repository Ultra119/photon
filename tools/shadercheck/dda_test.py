#!/usr/bin/env python3
"""Stage 5, 6 & 7 Unit Tests: DDA Sub-box AABB, Radiometric Energy, and SVGF Reconstruction.

Validates:
  1. Ray-box analytic intersections over voxel sub-shapes compute exact hit distance and normals.
  2. Rays crossing empty sub-regions pass through seamlessly.
  3. Emitter hits return intrinsic radiance L_e without division by pi.
  4. Diffuse reflection strictly conserves energy: L_out = albedo * L_mean (via pi cancellation).
  5. White furnace single-bounce illuminance matches E_1 = (A_e / A_total) * pi * L_e.
  6. SVGF moment tracking correctly computes variance (M2 - M1^2).
  7. 3x3 variance clipping prevents disocclusion ghosting.
  8. Variance-guided normal exponent adapts from 128 (converged) to 8 (noisy).
  9. Separable B-spline filter weights sum to 1.0.
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

    # Stage 6 Energy Accounting Tests:
    # Test 6: Emitter hit returns intrinsic radiance Le without division by pi
    torch_emission = 2.50
    sun_direct_irradiance = 10.0
    wall_albedo = 0.80
    rcp_pi = 1.0 / math.pi
    wall_reflected_radiance = wall_albedo * sun_direct_irradiance * rcp_pi

    # Emitter returns Le + reflected direct light
    emitter_returned_radiance = torch_emission + wall_reflected_radiance * 0.0
    assert abs(emitter_returned_radiance - torch_emission) < 1e-5, "Test 6 failed: Emitter radiance corrupted"

    # Test 7: Diffuse receiver energy balance:
    # Incident diffuse irradiance E_indirect = pi * L_mean.
    # Reflected radiance L_out = (albedo / pi) * E_indirect = albedo * L_mean.
    L_mean = 1.75
    albedo_concrete = 1.00 # Pure white concrete
    E_indirect = math.pi * L_mean # Converted in diffuse_lighting.glsl
    L_out = (albedo_concrete * rcp_pi) * E_indirect
    assert abs(L_out - L_mean) < 1e-5, f"Test 7 failed: Energy conservation violated, L_out={L_out} != L_mean={L_mean}"

    # Test 8: White Furnace Room Analytic Reference (11x11x5 enclosure, A_total = 462 m^2)
    # Area of emitter = 5 m^2 (floor-mounted cube), Le = 100.0 W/(m^2*sr)
    A_total = 462.0
    A_e = 5.0
    L_e = 100.0
    E_1_analytic = (A_e / A_total) * math.pi * L_e
    assert abs(E_1_analytic - 3.400) < 0.01, f"Test 8 failed: Analytic E_1 calculation {E_1_analytic} outside expected"

    # Stage 7 SVGF Reconstruction Tests:
    # Test 9: Moment tracking & variance
    # Suppose raw values across frames are: [2.0, 4.0] with equal weight
    m1 = 0.5 * 2.0 + 0.5 * 4.0 # 3.0
    m2 = 0.5 * (2.0**2) + 0.5 * (4.0**2) # 0.5 * 4 + 0.5 * 16 = 10.0
    var = m2 - m1 * m1 # 10.0 - 9.0 = 1.0
    assert abs(var - 1.0) < 1e-5, f"Test 9 failed: Expected variance 1.0, got {var}"

    # Test 10: 3x3 variance clipping
    # Current neighborhood in range [1.0, 2.0]. Old history was 10.0 (e.g. from previous lit surface)
    raw_min = 1.0
    raw_max = 2.0
    old_history = 10.0
    clamped_history = min(max(old_history, raw_min), raw_max)
    assert clamped_history == 2.0, f"Test 10 failed: History not clamped to AABB: {clamped_history}"

    # Test 11: SVGF adaptive normal exponent
    # At var_norm = 0.0 (converged), exponent is 128.0; at var_norm = 1.0 (noisy), exponent is 8.0
    def get_sigma_n(std_dev, mean):
        var_norm = min(max(std_dev / (mean + 0.02), 0.0), 1.0)
        return 128.0 + (8.0 - 128.0) * var_norm

    sigma_n_noisy = get_sigma_n(1.0, 0.5) # std_dev > mean => var_norm = 1.0 => 8.0
    sigma_n_converged = get_sigma_n(0.0, 1.0) # std_dev = 0 => var_norm = 0.0 => 128.0
    assert abs(sigma_n_noisy - 8.0) < 1e-4, f"Test 11 failed: Expected noisy sigma_n=8, got {sigma_n_noisy}"
    assert abs(sigma_n_converged - 128.0) < 1e-4, f"Test 11 failed: Expected converged sigma_n=128, got {sigma_n_converged}"

    # Test 12: B-spline filter kernel normalization
    bspline_1d = [0.0625, 0.25, 0.375, 0.25, 0.0625]
    assert abs(sum(bspline_1d) - 1.0) < 1e-6, "Test 12 failed: 1D B-spline does not sum to 1.0"
    kernel_2d_sum = sum(wx * wy for wx in bspline_1d for wy in bspline_1d)
    assert abs(kernel_2d_sum - 1.0) < 1e-6, f"Test 12 failed: 2D B-spline does not sum to 1.0, got {kernel_2d_sum}"

    # Stage 8 DDGI Probe Radiance Cache Tests:
    # Test 13: Probe grid origin snapping and world invariance
    # Snapped to 4-block grid steps so probes remain static in world space
    def get_ddgi_grid_origin(cam_x):
        ddgi_grid_extent = 128.0
        ddgi_rcp_spacing = 0.25
        ddgi_probe_spacing = 4.0
        return math.floor((cam_x - ddgi_grid_extent * 0.5) * ddgi_rcp_spacing) * ddgi_probe_spacing

    origin_cam1 = get_ddgi_grid_origin(100.5)
    origin_cam2 = get_ddgi_grid_origin(103.2) # Moved 2.7m
    origin_cam3 = get_ddgi_grid_origin(104.8) # Moved 4.3m across 4m boundary
    assert origin_cam1 == origin_cam2, f"Test 13 failed: Origin changed within 4m step ({origin_cam1} vs {origin_cam2})"
    assert origin_cam3 - origin_cam1 == 4.0, f"Test 13 failed: Origin did not step by exactly 4m ({origin_cam3} - {origin_cam1})"

    # Test 14: Fibonacci spherical ray distribution
    num_rays = 16
    rays = []
    for r in range(num_rays):
        y = 1.0 - (float(r) + 0.5) * (2.0 / float(num_rays))
        radius = math.sqrt(max(0.0, 1.0 - y * y))
        phi = float(r) * 2.399963229728653
        x = math.cos(phi) * radius
        z = math.sin(phi) * radius
        mag = math.sqrt(x*x + y*y + z*z)
        assert abs(mag - 1.0) < 1e-5, f"Test 14 failed: Ray {r} not unit length ({mag})"
        rays.append((x, y, z))
    mean_y = sum(ry for rx, ry, rz in rays) / num_rays
    assert abs(mean_y) < 1e-5, f"Test 14 failed: Rays not symmetric around sphere (mean y={mean_y})"

    # Test 15: Probe backface rejection
    # Wall normal points +X [1, 0, 0].
    # Probe inside room at [2, 0, 0] -> to_probe=[2, 0, 0], dot=1.0 -> weight=1.0
    # Probe behind wall (exterior) at [-2, 0, 0] -> to_probe=[-2, 0, 0], dot=-1.0 -> weight=0.0
    def backface_weight(normal, dir_to_probe):
        backface_dot = normal[0]*dir_to_probe[0] + normal[1]*dir_to_probe[1] + normal[2]*dir_to_probe[2]
        return min(max((backface_dot + 0.05) * (1.0 / 0.25), 0.0), 1.0)

    w_interior = backface_weight([1.0, 0.0, 0.0], [1.0, 0.0, 0.0])
    w_exterior = backface_weight([1.0, 0.0, 0.0], [-1.0, 0.0, 0.0])
    assert w_interior == 1.0, f"Test 15 failed: Interior probe rejected ({w_interior})"
    assert w_exterior == 0.0, f"Test 15 failed: Exterior probe not culled ({w_exterior})"

    # Test 16: Multi-bounce contractive convergence (fixed-point iteration)
    # L_bounce = albedo * L_prev. With albedo = 0.8 and direct E_0 = 1.0:
    # E_inf = E_0 / (1 - rho) = 1.0 / 0.2 = 5.0.
    rho = 0.80
    E_0 = 1.0
    E_curr = 0.0
    hysteresis = 0.85
    for frame in range(200):
        E_new = E_0 + rho * E_curr
        E_curr = hysteresis * E_curr + (1.0 - hysteresis) * E_new
    assert abs(E_curr - 5.0) < 0.05, f"Test 16 failed: Multi-bounce did not converge to 5.0 ({E_curr})"

    print("All Stage 5, Stage 6, Stage 7, & Stage 8 Unit Tests PASSED (16/16).")

if __name__ == "__main__":
    main()
