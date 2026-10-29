# Photonics integration — state and rationale

These files are Photon's Photonics-mod integration surface. They were deleted
during the RTGI work (they are not RTGI-related) and have been restored so the
pack is byte-comparable with upstream `6e67b36` in this directory.

## The files are stubs on purpose

`photonics.glsl` and `ph_samplers.glsl` are one-line comments:

> Photonics API — content provided by the Photonics mod at runtime.
> This empty file ensures the shader pack loads without the mod installed.

The mod **replaces their contents at load time**. They exist so the pack
compiles when the mod is absent. `shader_interface.glsl` (86 lines),
`write_indirect.glsl` and `modifiers/*.glsl` are real pack-side code that the
mod's injected code calls.

Restoring them cannot break a build, because nothing in this pack includes them.
Verified: no `/photonics/` include exists on any live path in this fork.

## Why the call sites are not restored

Upstream `6e67b36` includes these files from exactly three places:

| Site | Include | Gate |
|---|---|---|
| `include/lighting/diffuse_lighting.glsl:25` | `ph_samplers.glsl` | `PHOTONICS_DIFFUSE` |
| `program/gbuffers_all_solid.fsh:126` | `photonics.glsl` | `PROGRAM_GBUFFERS_VOXELS` |
| `program/shadow_voxels.fsh:26` | `photonics.glsl` | `PROGRAM_GBUFFERS_VOXELS` |

The fork deleted both voxel programs. Its replacement voxelizer runs inside
`program/shadow.vsh` — a program the mod does not inject into. So two of the
three anchors no longer exist.

`PHOTONICS_DIFFUSE` is set from the consumer side, not here:
`program/d4_deferred_shading.fsh:157` does `#ifdef PHOTONICS_IN_USE` →
`#define PHOTONICS_DIFFUSE`, which only threads an extra `is_lod` argument into
`get_diffuse_lighting(...)`. This fork's `diffuse_lighting.glsl` was rewritten
around the `rtgi_*` chain and has no such parameter.

Note that `write_indirect()` (`write_indirect.glsl:3`) has **no caller anywhere
in upstream**. It is an API the mod offers; the pack never invokes it. Nothing
in this fork "stops feeding" the mod, because nothing ever fed it.

## Re-enabling it is a design task, not a restore

Photonics computes its own direct and ReSTIR-GI indirect radiosity. This fork
computes indirect light in `rtgi_*`. Running both as-is means two independent
indirect estimators shading the same surfaces — a double-count, and exactly the
failure mode this fork is trying to remove (see plan item B6).

A supported integration needs three decisions made together:

1. Which system owns *direct* light and which owns *indirect*.
2. Which system owns the light-ID table (`ph_lights.json` vs
   `block.properties` / the clipmap's emitter set).
3. Which program the mod injects into, now that the voxel pass moved to the
   shadow vertex stage.

Until those are settled, running both is **not supported**. That is a documented
limitation, not a silent removal: there is no `PHOTONICS_*` menu entry, no
settings define and no lang string, so the pack never advertises a capability it
does not have. Verified — `grep -c PHOTONICS` returns 0 across `settings.glsl`,
`shaders.properties` and `lang/en_US.lang`.
