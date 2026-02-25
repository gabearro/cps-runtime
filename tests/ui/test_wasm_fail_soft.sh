#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
FAIL_SOFT_WASM="$OUT_DIR/fail_soft_app.wasm"
UNHANDLED_RAISE_WASM="$OUT_DIR/raise_unhandled_exception_app.wasm"

mkdir -p "$OUT_DIR"

cd "$PROJECT_DIR"
bash scripts/check_wasm_toolchain.sh
bash scripts/build_ui_wasm.sh examples/ui/fail_soft_app.nim "$FAIL_SOFT_WASM"
bash scripts/build_ui_wasm.sh examples/ui/raise_unhandled_exception_app.nim "$UNHANDLED_RAISE_WASM"

if command -v wasm-validate >/dev/null 2>&1; then
  wasm-validate "$FAIL_SOFT_WASM"
  wasm-validate "$UNHANDLED_RAISE_WASM"
fi

node tests/ui/js/dom_shim_runner.mjs "$FAIL_SOFT_WASM" failsoft
node tests/ui/js/dom_shim_runner.mjs "$UNHANDLED_RAISE_WASM" failsoft

echo "PASS: UI wasm fail-soft integration test"
