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
