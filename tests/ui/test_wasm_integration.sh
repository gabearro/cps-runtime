#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
COUNTER_WASM="$OUT_DIR/counter_app.wasm"
TODO_WASM="$OUT_DIR/todo_keyed_app.wasm"
ROUTER_WASM="$OUT_DIR/router_app.wasm"
CONTROLLED_WASM="$OUT_DIR/controlled_input_app.wasm"
NET_WASM="$OUT_DIR/net_app.wasm"

mkdir -p "$OUT_DIR"

cd "$PROJECT_DIR"
bash scripts/check_wasm_toolchain.sh
bash scripts/build_ui_wasm.sh examples/ui/counter_app.nim "$COUNTER_WASM"
bash scripts/build_ui_wasm.sh examples/ui/todo_keyed_app.nim "$TODO_WASM"
bash scripts/build_ui_wasm.sh examples/ui/router_app.nim "$ROUTER_WASM"
bash scripts/build_ui_wasm.sh examples/ui/controlled_input_app.nim "$CONTROLLED_WASM"
bash scripts/build_ui_wasm.sh examples/ui/net_app.nim "$NET_WASM"

if command -v wasm-validate >/dev/null 2>&1; then
  wasm-validate "$COUNTER_WASM"
  wasm-validate "$TODO_WASM"
  wasm-validate "$ROUTER_WASM"
  wasm-validate "$CONTROLLED_WASM"
  wasm-validate "$NET_WASM"
fi

node tests/ui/js/dom_shim_runner.mjs "$COUNTER_WASM" counter
node tests/ui/js/dom_shim_runner.mjs "$TODO_WASM" todo
node tests/ui/js/dom_shim_runner.mjs "$ROUTER_WASM" router
node tests/ui/js/dom_shim_runner.mjs "$CONTROLLED_WASM" controlled
node tests/ui/js/dom_shim_runner.mjs "$NET_WASM" net

echo "PASS: UI wasm integration test"
