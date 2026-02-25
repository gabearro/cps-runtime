#!/usr/bin/env bash
set -euo pipefail

resolve_wasi_sysroot() {
  if [[ -n "${WASI_SYSROOT:-}" && -d "${WASI_SYSROOT}" ]]; then
    echo "${WASI_SYSROOT}"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local prefix
    prefix="$(brew --prefix wasi-libc 2>/dev/null || true)"
    if [[ -n "$prefix" && -d "$prefix/share/wasi-sysroot" ]]; then
      echo "$prefix/share/wasi-sysroot"
      return 0
    fi
  fi

  if [[ -d "/usr/share/wasi-sysroot" ]]; then
    echo "/usr/share/wasi-sysroot"
    return 0
  fi

  return 1
}

supports_wasm_target() {
  local clang_bin="$1"
  "$clang_bin" --print-targets 2>/dev/null | grep -Eq '\bwasm(32|64)\b'
}

resolve_wasm_clang() {
  if [[ -n "${WASM_CLANG:-}" ]]; then
    if [[ -x "${WASM_CLANG}" ]] && supports_wasm_target "${WASM_CLANG}"; then
      echo "${WASM_CLANG}"
      return 0
    fi
    echo "WASM_CLANG is set but does not support wasm targets: ${WASM_CLANG}" >&2
    return 1
  fi

  local candidates=()
  if command -v clang >/dev/null 2>&1; then
    candidates+=("$(command -v clang)")
  fi
  if command -v brew >/dev/null 2>&1; then
    local llvm_prefix
    llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    if [[ -n "${llvm_prefix}" && -x "${llvm_prefix}/bin/clang" ]]; then
      candidates+=("${llvm_prefix}/bin/clang")
    fi
  fi
  if [[ -x "/opt/homebrew/opt/llvm/bin/clang" ]]; then
    candidates+=("/opt/homebrew/opt/llvm/bin/clang")
  fi
  if [[ -x "/usr/local/opt/llvm/bin/clang" ]]; then
    candidates+=("/usr/local/opt/llvm/bin/clang")
  fi

  local seen=""
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ " ${seen} " == *" ${candidate} "* ]]; then
      continue
    fi
    seen+=" ${candidate}"
    if supports_wasm_target "${candidate}"; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

SYSROOT="$(resolve_wasi_sysroot || true)"
if [[ -z "$SYSROOT" ]]; then
  echo "WASI sysroot not found. Set WASI_SYSROOT or install wasi-libc." >&2
  exit 1
fi
WASI_INCLUDE="$SYSROOT/include/wasm32-wasi"
if [[ ! -d "$WASI_INCLUDE" ]]; then
  echo "WASI include path not found: $WASI_INCLUDE" >&2
  exit 1
fi

WASM_CLANG="$(resolve_wasm_clang || true)"
if [[ -z "$WASM_CLANG" ]]; then
  echo "wasm-capable clang not found. Install llvm (brew install llvm lld) or set WASM_CLANG." >&2
  exit 1
fi
WASM_CLANG_DIR="$(cd "$(dirname "$WASM_CLANG")" && pwd)"
export PATH="$WASM_CLANG_DIR:$PATH"

if ! command -v wasm-ld >/dev/null 2>&1; then
  echo "wasm-ld not found on PATH (install package: lld)" >&2
  exit 1
fi

echo "Checking clang wasm targets..."
"$WASM_CLANG" --print-targets | grep -E 'wasm32|wasm64' >/dev/null

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/probe.c" <<'EOF'
#include <string.h>
int add(int a, int b) {
  char buf[4];
  memset(buf, 0, sizeof(buf));
  return a + b + buf[0];
}
EOF

echo "Compiling wasm object with sysroot..."
"$WASM_CLANG" --target=wasm32-unknown-unknown-wasm \
  -isystem "$WASI_INCLUDE" \
  -isystem "$SYSROOT/include" \
  -c "$tmpdir/probe.c" -o "$tmpdir/probe.o"

echo "Linking wasm module..."
"$WASM_CLANG" --target=wasm32-unknown-unknown-wasm -nostdlib \
  -Wl,--no-entry -Wl,--export=add \
  "$tmpdir/probe.o" -o "$tmpdir/probe.wasm"

if command -v wasm-validate >/dev/null 2>&1; then
  echo "Validating wasm..."
  wasm-validate "$tmpdir/probe.wasm"
else
  echo "wasm-validate not found; skipping validation step."
fi

echo "WASM toolchain check passed."
