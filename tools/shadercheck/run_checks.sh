#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export NO_INJECT="${NO_INJECT:-shadowtex0}"

echo "== voxel packing test =="
python3 tools/shadercheck/voxel_packing_test.py

echo "== properties lint =="
python3 tools/shadercheck/properties_lint.py

echo "== compute/fragment static matrix =="
python3 tools/shadercheck/matrix_compute.py

echo "== wrapper/option static matrix =="
python3 tools/shadercheck/matrix.py

# Requires a glslang binary. Skipped (not silently passed) when absent, so a
# missing tool never reads as a green run.
if [ -n "${GLSLANG:-}" ] && [ -x "${GLSLANG:-}" ]; then
  echo "== ao estimator dispatch =="
  python3 tools/shadercheck/ao_dispatch_test.py
else
  echo "== ao estimator dispatch: SKIPPED (set GLSLANG to enable) =="
fi
