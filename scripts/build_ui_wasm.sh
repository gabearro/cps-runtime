#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENTRY="${1:-$PROJECT_DIR/examples/ui/counter_app.nim}"
OUT="${2:-$PROJECT_DIR/examples/ui/counter_app.wasm}"

if [[ ! -f "$ENTRY" ]]; then
  echo "entry file not found: $ENTRY" >&2
  exit 1
fi

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

SYSROOT="$(resolve_wasi_sysroot || true)"
if [[ -z "$SYSROOT" ]]; then
  cat >&2 <<'EOF'
Unable to find a WASI sysroot.
Set WASI_SYSROOT or install wasi-libc.
Expected paths:
  - $(brew --prefix wasi-libc)/share/wasi-sysroot
  - /usr/share/wasi-sysroot
EOF
  exit 1
fi

WASM_CLANG="$(resolve_wasm_clang || true)"
if [[ -z "$WASM_CLANG" ]]; then
  cat >&2 <<'EOF'
Unable to find a wasm-capable clang compiler.
Install Homebrew llvm and ensure it is visible:
  brew install llvm lld
or set WASM_CLANG to an absolute clang path with wasm32 support.
EOF
  exit 1
fi
WASM_CLANG_DIR="$(cd "$(dirname "$WASM_CLANG")" && pwd)"
export PATH="$WASM_CLANG_DIR:$PATH"

if ! command -v wasm-ld >/dev/null 2>&1; then
  echo "wasm-ld not found on PATH (install Homebrew package: lld)" >&2
  exit 1
fi

ENTRY_DIR="$(cd "$(dirname "$ENTRY")" && pwd)"
if [[ ! -f "$ENTRY_DIR/panicoverride.nim" ]]; then
  cat >&2 <<EOF
missing panicoverride.nim next to entry file:
  $ENTRY_DIR/panicoverride.nim
standalone wasm Nim builds require this file.
EOF
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "Building UI wasm (clang/lld):"
echo "  entry:   $ENTRY"
echo "  out:     $OUT"
echo "  sysroot: $SYSROOT"
echo "  clang:   $WASM_CLANG"

cd "$PROJECT_DIR"
WASI_SYSROOT="$SYSROOT" nim c -d:release -d:uiWasm --out:"$OUT" "$ENTRY"

if command -v wasm-opt >/dev/null 2>&1; then
  wasm-opt --enable-bulk-memory --enable-bulk-memory-opt -O3 --vacuum "$OUT" -o "$OUT"
  echo "Applied wasm-opt optimization."
fi

if command -v wasm-validate >/dev/null 2>&1; then
  wasm-validate "$OUT"
fi

bash "$PROJECT_DIR/scripts/check_wasm_imports.sh" "$OUT"

echo "Done."
