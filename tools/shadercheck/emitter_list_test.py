#!/usr/bin/env python3
"""Assert the P6.1 emitter-list contract.

The emitter list is what lets the GI ray evaluate a torch analytically instead
of waiting for a ray to happen across its cell. Every failure mode here is
invisible to a compiler, and two of them are silent bias:

1. **Duplicate entries.** The clipmap is written per-fragment by
   `imageAtomicMax`, so a torch covered by 24 fragments would be appended 24
   times and its emission counted 24 times. The dedup hinges on
   `imageAtomicMax` returning the value it replaced and the grid being cleared
   at frame start -- so `prev == 0` means "first writer to this cell this
   frame". If that predicate is dropped, NEE over-brightens by the fragment
   count and the error varies with distance and view angle.

2. **Payload divergence.** MIS weights are only valid if the NEE term and the
   BSDF path agree on the emission. Storing anything other than the exact
   packed voxel the DDA reads (e.g. re-deriving emission from the block id)
   silently breaks that.

3. **Cube emitters crowding the list.** A lava lake is thousands of emitter
   cells and would fill a 511-slot list, pushing every torch out. The list is
   thin emitters only, which is also exactly the measured defect: those are
   the ones the ray passes through without terminating.

4. **Off-by-one on the counter.** Texel 0 is the atomic counter and data
   starts at texel 1, so the bounds check has to reserve the header slot.

Exit code 0 means every assertion held.
"""
from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]

PROPS = ROOT / "shaders" / "shaders.properties"
SETTINGS = ROOT / "shaders" / "settings.glsl"
UPDATE = ROOT / "shaders" / "include" / "lighting" / "voxel" / "voxel_update.glsl"

failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


props = PROPS.read_text(encoding="utf-8")
settings = SETTINGS.read_text(encoding="utf-8")
update = UPDATE.read_text(encoding="utf-8")

# ---------------------------------------------------------------- declaration

decl = re.search(r"^image\.emitter_list_img\s*=\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$",
                 props, re.M)
check(decl is not None, "shaders.properties: emitter_list_img is not declared")
if decl:
    sampler, pixfmt, internal, pixtype, clear, relative, w, h = decl.groups()
    # imageAtomicAdd is only supported on r32i/r32ui -- rgba32ui compiles but
    # fails at runtime, and glslang rejects it outright.
    check(internal == "r32ui", f"emitter_list_img internal format is {internal}, expected r32ui (imageAtomicAdd only supports r32i/r32ui)")
    check(pixfmt == "red_integer", f"emitter_list_img pixel format is {pixfmt}, expected red_integer")
    check(pixtype == "unsigned_int", f"emitter_list_img pixel type is {pixtype}, expected unsigned_int")
    # Cleared at frame start: the counter and the dedup's prev==0 test both
    # depend on it. A stale counter would append past the end forever.
    check(clear == "true", f"emitter_list_img clear is {clear}, expected true (atomic counter + prev==0 dedup)")
    
    # The guard must match the shader macro exactly or the image disappears
    # while the build site still references it.
    guard = re.search(r"#if\s+GI_DEBUG\s*!=\s*GI_DEBUG_HIT\s*&&\s*GI_DEBUG\s*!=\s*GI_DEBUG_REJECT",
                      props)
    check(guard is not None,
          "shaders.properties: emitter_list_img is not guarded on GI_DEBUG != HIT && != REJECT "
          "(it shares the 16-image slot with those two views)")

    cap = re.search(r"#define\s+RT_EMITTER_LIST_CAPACITY\s+(\d+)u", settings)
    check(cap is not None, "settings.glsl: RT_EMITTER_LIST_CAPACITY is not defined")
    if cap:
        # 4 texels per emitter (x, y, z, payload) plus the counter texel.
        need = 1 + 4 * int(cap.group(1))
        check(int(w) >= need,
              f"emitter_list_img width {w} is too small for capacity {cap.group(1)}: needs 1 + 4*{cap.group(1)} = {need} texels")
        check(int(h) == 1, f"emitter_list_img height is {h}, expected 1 (1-D list)")

check("#define RT_EMITTER_LIST 1" in settings,
      "settings.glsl: RT_EMITTER_LIST is not defined (build site would be compiled out)")

# RT_EMITTER_LIST must appear inside the same guard as the image declaration,
# otherwise the shader references an image Iris never allocated.
m = re.search(r"#if\s+GI_DEBUG\s*!=\s*GI_DEBUG_HIT\s*&&\s*GI_DEBUG\s*!=\s*GI_DEBUG_REJECT\s*\n"
              r"\s*#define\s+RT_EMITTER_LIST\s+1\s*\n\s*#endif", settings)
check(m is not None,
      "settings.glsl: RT_EMITTER_LIST must be defined inside the same "
      "GI_DEBUG != HIT && != REJECT guard as the image declaration")

# ---------------------------------------------------------------- build site

mm = re.search(r"#if\s+defined\s+RT_EMITTER_LIST\s*\n\s*layout\(r32ui\) uniform uimage2D emitter_list_img;\s*\n\s*#endif",
               update)
check(mm is not None,
      "voxel_update.glsl: emitter_list_img must be declared as uimage2D, inside an RT_EMITTER_LIST guard, with layout(r32ui)")

# 1. Dedup: imageAtomicMax's return value must be captured and tested.
check(re.search(r"uint\s+prev\s*=\s*imageAtomicMax\(\s*voxel_img\s*,\s*coord\s*,\s*payload\s*\)", update) is not None,
      "voxel_update.glsl: level-0 write must capture imageAtomicMax's return value into `prev`")
check("prev == 0u" in update,
      "voxel_update.glsl: the append must be gated on prev == 0u, otherwise every "
      "fragment covering an emitter appends a duplicate")

# 2. Thin emitters only.
check("shape_class != VOXEL_SHAPE_CUBE" in update,
      "voxel_update.glsl: the append must exclude cube emitters (shape_class != VOXEL_SHAPE_CUBE); "
      "a lava lake would otherwise fill the list and crowd out every torch")

# 3. Payload fidelity: store the same `payload` the DDA reads.
for ch, expr in (("x", "uint(coord.x)"), ("y", "uint(coord.y)"), ("z", "uint(coord.z)"),
                 ("payload", "payload")):
    pass
# Atomic, not imageStore: the clipmap sharing this pass is written with
# imageAtomicMax, and atomic image ops carry cross-pass ordering guarantees a
# plain store does not. The list is read two passes later in another program,
# and a plain store from a vertex shader is not guaranteed to be visible there.
stores = re.findall(r"imageAtomicExchange\(\s*emitter_list_img\s*,\s*ivec2\(\s*base([^,]*),\s*0\s*\)\s*,\s*(.*)\s*\)",
                    update)
check(len(stores) == 4, f"voxel_update.glsl: expected 4 imageStore calls per emitter (x, y, z, payload), found {len(stores)}")
if len(stores) == 4:
    check([e for _, e in stores] == ["uint(coord.x)", "uint(coord.y)", "uint(coord.z)", "payload"],
          f"voxel_update.glsl: emitter texels are {[e for _, e in stores]}, expected "
          "['uint(coord.x)', 'uint(coord.y)', 'uint(coord.z)', 'payload'] -- the exact packed "
          "voxel, so NEE and the BSDF path agree on the emission")
    check([o.strip() for o, _ in stores] == ["", "+ 1", "+ 2", "+ 3"],
          f"voxel_update.glsl: texel offsets are {[o.strip() for o, _ in stores]}, expected base, base+1, base+2, base+3")
check("imageStore(emitter_list_img" not in update,
      "voxel_update.glsl: entry texels must use imageAtomicExchange, not imageStore "
      "-- a plain store from a vertex shader is not guaranteed visible to the pass that reads the list")
check("int base = 1 + int(slot) * 4;" in update,
      "voxel_update.glsl: base must be `1 + int(slot) * 4` (texel 0 is the counter, 4 texels per emitter)")

# 4. Counter / off-by-one.
check(re.search(r"uint\s+slot\s*=\s*imageAtomicAdd\(\s*emitter_list_img\s*,\s*ivec2\(\s*0\s*,\s*0\s*\)\s*,\s*1u\s*\)",
                update) is not None,
      "voxel_update.glsl: the slot must come from imageAtomicAdd on texel (0,0)")
check("slot < RT_EMITTER_LIST_CAPACITY" in update,
      "voxel_update.glsl: the bounds check must be `slot < RT_EMITTER_LIST_CAPACITY`")

# The append must be inside the level-0 branch: coarse cells are conservative
# occupancy cubes representing up to 16 blocks, so a level-1 coord is not a
# block-accurate emitter position.
lvl0 = re.search(r"if\s*\(\s*level\s*==\s*0\s*\)\s*\{(.*?)\n\s*\}\s*else\s+if\s*\(\s*level\s*==\s*1\s*\)",
                 update, re.S)
check(lvl0 is not None, "voxel_update.glsl: could not locate the level-0 branch")
if lvl0:
    check("emitter_list_img" in lvl0.group(1),
          "voxel_update.glsl: the append must be inside the level-0 branch only "
          "(level 0 is 1 block per cell; coarser levels are not block-accurate)")

# ------------------------------------------------------- CPU model of the dedup

def model(fragments, capacity=512):
    """Replay the GPU logic over (cell, is_emitter) fragment writes.

    `fragments` is a list of (cell, is_emitter) in arbitrary order. Returns
    (entries, count) as the shader would leave them.
    """
    grid: dict[tuple[int, int, int], int] = {}   # cleared at frame start
    count = 0
    entries: list[tuple] = []
    for cell, is_emitter in fragments:
        prev = grid.get(cell, 0)
        grid[cell] = 1
        if prev == 0 and is_emitter:
            slot = count
            count += 1
            if slot + 1 < capacity:
                entries.append(cell)
    return entries, min(count, capacity - 1)


# One torch covered by many fragments (6 faces x 4 fragments) must append once.
torch = (7, 9, 11)
frags = [(torch, True)] * 24
entries, count = model(frags)
check(len(entries) == 1, f"dedup: a torch covered by 24 fragments produced {len(entries)} entries, expected 1")
check(count == 1, f"dedup: counter reached {count}, expected 1")

# Several distinct thin emitters, each covered many times.
emitters = [(i, i * 2, i * 3) for i in range(1, 6)]
frags = []
for c in emitters:
    frags += [(c, True)] * 13
frags += [((99, 99, 99), False)] * 40          # non-emitter geometry
entries, count = model(frags)
check(len(entries) == 5, f"dedup: 5 emitters produced {len(entries)} entries, expected 5")
check(count == 5, f"dedup: counter reached {count}, expected 5")

# Order independence: the atomic makes the final state independent of the order
# fragments are written in, which is what makes this stable across frames.
import random
rng = random.Random(1234)
shuffled = frags[:]
rng.shuffle(shuffled)
e2, c2 = model(shuffled)
check(sorted(e2) == sorted(entries) and c2 == count,
      "dedup: result depends on fragment write order")

# Overflow: capacity is 512, texel 0 is the counter, so 511 emitters fit and
# the 512th is dropped -- and the counter is clamped on read, not wrapped.
many = [((i, 0, 0), True) for i in range(700)]
entries, count = model(many)
check(len(entries) == 511, f"capacity: {len(entries)} entries stored, expected 511")
check(count == 511, f"capacity: counter clamps to {count}, expected 511")

# The image is sized from the capacity; an off-by-one here corrupts the last
# emitter silently rather than failing.
cap = re.search(r"#define\s+RT_EMITTER_LIST_CAPACITY\s+(\d+)u", settings)
wid = re.search(r"^image\.emitter_list_img\s*=\s*\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s*$", props, re.M)
if cap and wid:
    last_texel = 1 + 4 * int(cap.group(1)) - 1
    check(last_texel <= int(wid.group(1)) - 1,
          f"capacity {cap.group(1)} writes up to texel {last_texel} but the image is only "
          f"{wid.group(1)} texels wide")

# ---------------------------------------------------------------------- report

if failures:
    for f in failures:
        print(f"FAIL {f}")
    print(f"\n{len(failures)} assertion(s) failed")
    sys.exit(1)

print("emitter list contract OK (declaration, first-writer dedup, thin emitters only, "
      "payload fidelity, capacity 511)")
