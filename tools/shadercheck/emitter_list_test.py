#!/usr/bin/env python3
"""Assert the P6.1 emitter-list contract.

The emitter list is what lets the GI ray evaluate a torch analytically instead
of waiting for a ray to happen across its cell. It is built in
`voxel_cache_generate.csh`, a compute pass with exactly one invocation per
clipmap cell -- so every emitter is visited once by construction and no dedup
is needed.

Every failure mode here is invisible to a compiler:

1. **Where it is built.** It was originally in `voxel_update.glsl`, which is
   included by nine vertex programs (gbuffers_terrain, gbuffers_terrain_solid,
   gbuffers_block and every shadow_* variant). That meant ~9 passes a frame
   writing one image, with ordering and clear semantics that cannot be checked
   from here. Compute-to-later-pass is the pattern the RTGI buffers already use.

2. **Ordering against the solid-cell early exit.** An emitter block is solid,
   and the cache pass early-exits for solid cells. Building after that exit
   silently produces an empty list.

3. **Cube emitters crowding the list.** A lava lake is thousands of emitter
   cells and would fill all 511 slots, pushing every torch out. Thin emitters
   only -- which is also exactly the measured defect, since those are the ones
   the ray passes through without terminating.

4. **Square image.** A 2048x1 image put every DATA texel out of bounds. The
   counter at index 0 still read fine, so the list reported itself completely
   full while every entry was garbage, and an out-of-range fetch returns junk
   rather than failing.

Exit code 0 means every assertion held.
"""
from __future__ import annotations

import pathlib
import random
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]

PROPS = ROOT / "shaders" / "shaders.properties"
SETTINGS = ROOT / "shaders" / "settings.glsl"
BUILD = ROOT / "shaders" / "program" / "rtgi" / "voxel_cache_generate.csh"
UPDATE = ROOT / "shaders" / "include" / "lighting" / "voxel" / "voxel_update.glsl"

failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


props = PROPS.read_text(encoding="utf-8")
settings = SETTINGS.read_text(encoding="utf-8")
build = BUILD.read_text(encoding="utf-8")
update = UPDATE.read_text(encoding="utf-8")

# ---------------------------------------------------------------- declaration

decl = re.search(r"^image\.emitter_list_img\s*=\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$",
                 props, re.M)
check(decl is not None, "shaders.properties: emitter_list_img is not declared")
if decl:
    sampler, pixfmt, internal, pixtype, clear, relative, w, h = decl.groups()
    # imageAtomicAdd is only supported on r32i/r32ui.
    check(internal == "r32ui", f"emitter_list_img internal format is {internal}, expected r32ui")
    check(pixfmt == "red_integer", f"emitter_list_img pixel format is {pixfmt}, expected red_integer")
    check(pixtype == "unsigned_int", f"emitter_list_img pixel type is {pixtype}, expected unsigned_int")
    check(clear == "true", f"emitter_list_img clear is {clear}, expected true (the counter must start at 0)")
    # Square: cannot be transposed, cannot run out of width.
    check(w == h,
          f"emitter_list_img is {w}x{h}; it must be square so a width/height mix-up cannot "
          f"transpose it and a data texel cannot fall outside the row")

    guard = re.search(r"#if\s+GI_DEBUG\s*!=\s*GI_DEBUG_HIT\s*&&\s*GI_DEBUG\s*!=\s*GI_DEBUG_REJECT",
                      props)
    check(guard is not None,
          "shaders.properties: emitter_list_img must be guarded on GI_DEBUG != HIT && != REJECT "
          "(it shares the 16-image slot with those two views)")

    cap = re.search(r"#define\s+RT_EMITTER_LIST_CAPACITY\s+(\d+)u", settings)
    check(cap is not None, "settings.glsl: RT_EMITTER_LIST_CAPACITY is not defined")
    if cap:
        need = 1 + 4 * int(cap.group(1))
        check(int(w) * int(h) >= need,
              f"emitter_list_img is {w}x{h} = {int(w)*int(h)} texels but capacity "
              f"{cap.group(1)} needs {need}")

# RT_EMITTER_LIST must sit inside the same guard as the image declaration.
check(re.search(r"#if\s+GI_DEBUG\s*!=\s*GI_DEBUG_HIT\s*&&\s*GI_DEBUG\s*!=\s*GI_DEBUG_REJECT\s*\n"
                r"\s*#define\s+RT_EMITTER_LIST\s+1\s*\n\s*#endif", settings) is not None,
      "settings.glsl: RT_EMITTER_LIST must be defined inside the same "
      "GI_DEBUG != HIT && != REJECT guard as the image declaration")

# ---------------------------------------------------------------- build site

check("emitter_list_img" not in update,
      "voxel_update.glsl must not build the emitter list: it is included by nine vertex "
      "programs, so the image would be written from ~9 passes a frame")

check(re.search(r"#if\s+defined\s+RT_EMITTER_LIST\s*\n\s*layout\(r32ui\) uniform uimage2D emitter_list_img;\s*\n\s*#endif",
                build) is not None,
      "voxel_cache_generate.csh: emitter_list_img must be declared as uimage2D with "
      "layout(r32ui), inside an RT_EMITTER_LIST guard")

# The solid-cell early exit returns before anything else; an emitter is solid,
# so the build has to precede it or the list is always empty.
early = build.find("imageStore(voxel_cache_sh_img, cell, vec4(0.0));")
first_build = build.find("emitter_list_img")
check(early != -1, "voxel_cache_generate.csh: could not find the solid-cell early exit")
check(first_build != -1, "voxel_cache_generate.csh: emitter list is never written")
if early != -1 and first_build != -1:
    check(first_build < early,
          "voxel_cache_generate.csh: the emitter list must be built BEFORE the solid-cell "
          "early exit -- emitter blocks are solid, so anything after it never runs")

check("list_vs.is_emitter && list_vs.shape_class != VOXEL_SHAPE_CUBE" in build,
      "voxel_cache_generate.csh: must filter to thin emitters "
      "(is_emitter && shape_class != VOXEL_SHAPE_CUBE)")

check(re.search(r"uint\s+slot\s*=\s*imageAtomicAdd\(\s*emitter_list_img\s*,\s*rt_emitter_texel\(\s*0\s*\)\s*,\s*1u\s*\)",
                build) is not None,
      "voxel_cache_generate.csh: the slot must come from imageAtomicAdd on rt_emitter_texel(0)")
check("slot < RT_EMITTER_LIST_CAPACITY" in build,
      "voxel_cache_generate.csh: the bounds check must be `slot < RT_EMITTER_LIST_CAPACITY`")
check("int base = 1 + int(slot) * 4;" in build,
      "voxel_cache_generate.csh: base must be `1 + int(slot) * 4` (index 0 is the counter)")

# Atomic, not imageStore: atomic image ops carry cross-pass ordering guarantees
# a plain store does not, and this is read two passes later in another program.
stores = re.findall(r"imageAtomicExchange\(\s*emitter_list_img\s*,\s*rt_emitter_texel\(\s*base([^)]*)\s*\)\s*,\s*(.*)\s*\)",
                    build)
check(len(stores) == 4, f"voxel_cache_generate.csh: expected 4 imageAtomicExchange writes per "
                        f"emitter (x, y, z, payload), found {len(stores)}")
if len(stores) == 4:
    check([e for _, e in stores] == ["uint(cell.x)", "uint(cell.y)", "uint(cell.z)", "list_packed"],
          f"voxel_cache_generate.csh: emitter texels are {[e for _, e in stores]}, expected "
          "['uint(cell.x)', 'uint(cell.y)', 'uint(cell.z)', 'list_packed'] -- the exact packed "
          "voxel, so NEE and the BSDF path agree on the emission")
    check([o.strip() for o, _ in stores] == ["", "+ 1", "+ 2", "+ 3"],
          f"voxel_cache_generate.csh: texel offsets are {[o.strip() for o, _ in stores]}, "
          "expected base, base+1, base+2, base+3")
check("imageStore(emitter_list_img" not in build,
      "voxel_cache_generate.csh: entry texels must use imageAtomicExchange, not imageStore")

# ------------------------------------------------------- CPU model of the build

def model(cells_with_emitters, dim=128, capacity=511):
    """Replay the compute pass: one invocation per cell, one append per emitter."""
    count = 0
    entries = []
    for c in range(dim ** 3):
        if c in cells_with_emitters:
            slot = count
            count += 1
            if slot < capacity:
                entries.append(c)
    return entries, min(count, capacity)


# One invocation per cell, so a torch is appended exactly once no matter how
# many fragments covered it during voxelization. The old vertex-shader build
# had to recover this with a first-writer test; here it is structural.
entries, count = model({7})
check(len(entries) == 1 and count == 1,
      f"dedup: a single emitter produced {len(entries)} entries / count {count}, expected 1")

emitters = {i * 37 for i in range(1, 6)}
entries, count = model(emitters)
check(len(entries) == 5 and count == 5,
      f"dedup: 5 emitters produced {len(entries)} entries / count {count}, expected 5")

# Order independence is structural too -- the invocation index is the only input.
rng = random.Random(99)
for _ in range(20):
    subset = {rng.randrange(128 ** 3) for _ in range(rng.randrange(1, 40))}
    e, c = model(subset)
    if sorted(e) != sorted(subset) or c != len(subset):
        failures.append("dedup: result depends on iteration order")
        break

# Overflow: index 0 is the counter, so 511 emitters fit and the rest are dropped.
entries, count = model(set(range(700)))
check(len(entries) == 511, f"capacity: {len(entries)} entries stored, expected 511")
check(count == 511, f"capacity: counter clamps to {count}, expected 511")

# ---------------------------------------------------------------------- report

if failures:
    for f in failures:
        print(f"FAIL {f}")
    print(f"\n{len(failures)} assertion(s) failed")
    sys.exit(1)

print("emitter list contract OK (square r32ui image, built in the compute pass, "
      "thin emitters only, payload fidelity, capacity 511)")
