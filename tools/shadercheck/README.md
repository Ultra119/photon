# Static GLSL validation harness

This is a lightweight stand-in for an Iris compile. It resolves the shaderpack's
`#include` graph, injects the custom uniforms that Iris supplies, and runs
`glslang` over representative world/option variants. It does **not** validate
uniform binding, image hazards, or driver-specific behavior; use it as a fast
regression check, then verify in-game with Iris.

## Build a validator

The harness accepts any `glslang` or `glslangValidator` binary. If you do not
have one installed:

```sh
git clone --depth 1 https://github.com/KhronosGroup/glslang.git
python3 -m pip install --user cmake
cmake -S glslang -B glslang/build -DCMAKE_BUILD_TYPE=Release -DENABLE_OPT=OFF
cmake --build glslang/build --target glslang-standalone -j4
export GLSLANG="$PWD/glslang/build/StandAlone/glslang"
```

## Run

From the repository root:

```sh
python3 tools/shadercheck/check.py /world0/deferred1_a.csh comp
python3 tools/shadercheck/check.py /world0/deferred4.fsh frag
python3 tools/shadercheck/check.py /world-1/deferred4.fsh frag
python3 tools/shadercheck/matrix.py
```

`check.py` arguments are:

1. a shader path relative to `shaders/` (leading `/` is also accepted),
2. the GLSL stage (`comp`, `frag`, or `vert`),
3. optional defines. `NAME=value` overrides a settings macro, `!NAME`
   undefines it, and `+NAME=value` defines it before `settings.glsl` is read
   (use this for environment macros such as `DISTANT_HORIZONS`).

Environment variables:

- `SHADER_ROOT` — override the shader directory (defaults to `<repo>/shaders`).
- `GLSLANG` — path to the validator binary.
- `NO_INJECT` — comma-separated uniform names the harness must not inject;
   useful for reproducing errors caused by a missing program declaration.

The harness writes preprocessed sources to `/tmp/check_*.{comp,frag,vert}`.

It also supplies minimal stubs for code that Iris, Voxy, or COLORWHEEL injects at
runtime (`VoxyFragmentParameters`, `clrwl_computeFragment`). These stubs are only
for static parsing; they are not part of the shaderpack.

`voxel_packing_test.py` is a small pure-Python regression test for the 32-bit
voxel payload used by `voxel_storage.glsl`:

```sh
python3 tools/shadercheck/voxel_packing_test.py
```

`properties_lint.py` preprocesses `shaders.properties`, checks for new duplicate
property keys, and verifies the RTGI menu/language/options wiring. It allows the
three duplicate keys that already exist upstream.

It also runs an **orphan-option** check: every identifier appearing in a
`screen.*` group or in `sliders` must be defined in `settings.glsl` and must be
read by at least one shader. A menu entry that changes nothing is worse than a
missing feature, because it looks supported and silently is not. Options that
were already dead upstream are reported as warnings so inherited debt does not
mask new breakage; `KNOWN_DEAD_OPTIONS` and `KNOWN_MISSING_OPTIONS` at the top of
the file list them and should shrink over time.

`ao_dispatch_test.py` asserts that the AO setting selects exactly one estimator:

```sh
GLSLANG=/path/to/glslang python3 tools/shadercheck/ao_dispatch_test.py
```

A successful compile only proves every branch *parses*. This test runs the real
preprocessor (`glslang -E`) over the assembled source and counts
`compute_ssao` / `compute_gtao` / `compute_contact_ao` symbols, so a dispatch
that compiles but emits the wrong estimator — or two of them — is caught. It
covers all four modes in all three dimensions, with RTGI on and off. It is
skipped, loudly, when `GLSLANG` is unset rather than being reported as passing.

Run every static check with:

```sh
./tools/shadercheck/run_checks.sh
```

`matrix_compute.py` is the compute/fragment-focused matrix; `matrix.py` is the
wider wrapper/option matrix. Both are invoked by `run_checks.sh`.

Note that `world*/deferred3.fsh` is the translation unit that contains the AO
pass — it does `#include "/program/d3_ao.fsh"`. There is no `world*/d3_ao.fsh`,
so target `deferred3` when testing AO, not `d3_ao`.
