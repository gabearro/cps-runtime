#!/usr/bin/env bash
# Build BoringSSL from source and install to deps/boringssl/
#
# Prerequisites: git, cmake, go, ninja (or make), C/C++ compiler
#
# Usage:
#   ./scripts/build_boringssl.sh
#
# After building, compile Nim code with:
#   nim c -d:useBoringSSL ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/deps/boringssl-src"
INSTALL_DIR="$PROJECT_DIR/deps/boringssl"

# Pin to a specific commit for reproducibility
BORINGSSL_REPO="https://boringssl.googlesource.com/boringssl"
BORINGSSL_COMMIT="a98a2925e4be6690370d05b7443da121888051f7"  # 2026-02-17

echo "=== Building BoringSSL ==="
echo "  Source:  $BUILD_DIR"
echo "  Install: $INSTALL_DIR"

# Clone or update
if [ ! -d "$BUILD_DIR" ]; then
  echo "Cloning BoringSSL..."
  git clone "$BORINGSSL_REPO" "$BUILD_DIR"
fi

cd "$BUILD_DIR"
git fetch origin
git checkout "$BORINGSSL_COMMIT"

# Build
mkdir -p build
cd build

cmake -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  ..

ninja ssl crypto

# Install
echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/include"

# Copy static libraries
cp ssl/libssl.a "$INSTALL_DIR/lib/"
cp crypto/libcrypto.a "$INSTALL_DIR/lib/"

# Copy headers
cp -r "$BUILD_DIR/include/openssl" "$INSTALL_DIR/include/"

echo "=== BoringSSL build complete ==="
echo ""
echo "To use with Nim:"
echo "  nim c -d:useBoringSSL your_program.nim"
