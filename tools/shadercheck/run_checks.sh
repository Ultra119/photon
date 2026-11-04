#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export NO_INJECT="${NO_INJECT:-shadowtex0}"

echo "== voxel packing test =="
python3 tools/shadercheck/voxel_packing_test.py

echo "== properties lint =="
python3 tools/shadercheck/properties_lint.py

echo "== custom image budget (per PT quality tier) =="
# Prints the per-tier allocation table; regenerate docs/pt_image_budget.md from
# it when the profile set or the image declarations change.
python3 tools/shadercheck/image_budget.py > /dev/null
echo "image budget OK (at most 16 custom images per tier)"

echo "== compute/fragment static matrix =="
python3 tools/shadercheck/matrix_compute.py

echo "== wrapper/option static matrix =="
python3 tools/shadercheck/matrix.py

# A missing validator is an error, never a skipped green run.
if [ -z "${GLSLANG:-}" ] || [ ! -x "${GLSLANG:-}" ]; then
  echo "error: set GLSLANG to an executable glslang binary" >&2
  exit 2
fi

echo "== voxel DDA / energy reference =="
python3 tools/shadercheck/dda_test.py

echo "== R7 clipmap coverage =="
python3 tools/shadercheck/clipmap_test.py

echo "== RT lighting boundary =="
python3 tools/shadercheck/rt_boundary_test.py
echo "== RT AO estimator dispatch =="
python3 tools/shadercheck/ao_dispatch_test.py
echo "== gi debug view wiring =="
python3 tools/shadercheck/gi_debug_test.py
