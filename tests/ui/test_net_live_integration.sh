#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
NET_WASM="$OUT_DIR/net_app.wasm"
SERVER_BIN="$PROJECT_DIR/examples/ui/net_demo_server"
HOST="${CPS_UI_HOST:-127.0.0.1}"
PORT="${CPS_UI_PORT:-9092}"
BASE_URL="http://${HOST}:${PORT}"

mkdir -p "$OUT_DIR"

cd "$PROJECT_DIR"
bash scripts/check_wasm_toolchain.sh
bash scripts/build_ui_wasm.sh examples/ui/net_app.nim "$NET_WASM"
nim c --mm:arc -d:release -o:examples/ui/net_demo_server examples/ui/net_demo_server.nim

CPS_UI_HOST="$HOST" CPS_UI_PORT="$PORT" "$SERVER_BIN" >"$OUT_DIR/net_demo_server.log" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for _ in $(seq 1 80); do
  if curl -fsS "$BASE_URL/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! curl -fsS "$BASE_URL/api/health" >/dev/null 2>&1; then
  echo "Server failed health check at $BASE_URL/api/health"
  echo "--- server log ---"
  cat "$OUT_DIR/net_demo_server.log"
  exit 1
fi

node tests/ui/js/net_live_runner.mjs "$NET_WASM" "$BASE_URL"
echo "PASS: live frontend/server net integration"
