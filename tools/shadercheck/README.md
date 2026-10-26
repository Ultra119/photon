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

Run every static check with:

```sh
./tools/shadercheck/run_checks.sh
```

`matrix_compute.py` is the compute/fragment-focused matrix; `matrix.py` is the
wider wrapper/option matrix. Both are invoked by `run_checks.sh`.
