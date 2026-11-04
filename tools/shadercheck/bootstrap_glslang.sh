#!/usr/bin/env bash
# Build the glslang validator the shader checks compile with.
#
# The static matrices and the gi-debug/pt-state tests shell out to a real
# compiler: "it preprocesses" proves nothing about whether it compiles, and a
# pack that does not compile does not load. glslang is not vendored (it is a
# ~40 MB C++ tree), so this script fetches and builds it instead.
#
# Usage:
#   bash tools/shadercheck/bootstrap_glslang.sh
#   GLSLANG_PREFIX=/somewhere bash tools/shadercheck/bootstrap_glslang.sh
#   GLSLANG_JOBS=8 bash tools/shadercheck/bootstrap_glslang.sh
#
# It prints the binary path when it succeeds. Requires: git, cmake >= 3.22,
# a C++17 compiler, python3. Network access to github.com is needed for the
# clone; everything after that is local.
set -euo pipefail

# The default matches GLSLANG's default in gi_debug_test.py and check.py.
PREFIX="${GLSLANG_PREFIX:-/tmp/glslang-build}"
VERSION="${GLSLANG_VERSION:-15.0.0}"
JOBS="${GLSLANG_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
BINARY="$PREFIX/glslang-$VERSION/build/StandAlone/glslang"

if [ -x "$BINARY" ]; then
  echo "glslang $VERSION already built: $BINARY"
  exit 0
fi

command -v git >/dev/null || { echo "error: git not found" >&2; exit 2; }
command -v cmake >/dev/null || {
  echo "error: cmake not found (pip install cmake, or your package manager)" >&2
  exit 2
}

mkdir -p "$PREFIX"
cd "$PREFIX"

if [ ! -d "glslang-$VERSION" ]; then
  echo "== cloning KhronosGroup/glslang $VERSION =="
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/KhronosGroup/glslang.git "glslang-$VERSION"
fi

cd "glslang-$VERSION"
echo "== configuring =="
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_OPT=OFF \
  -DGLSLANG_TESTS=OFF \
  -DENABLE_GLSLANG_BINARIES=ON

echo "== building (this takes several minutes) =="
cmake --build build --target glslang-standalone --parallel "$JOBS"

test -x "$BINARY" || { echo "error: build finished but $BINARY is missing" >&2; exit 1; }
echo
echo "glslang ready:"
echo "  export GLSLANG=$BINARY"
