#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "SKIP: xcodebuild not available"
  exit 0
fi

OUT_DIR="$ROOT_DIR/tests/gui/out"
rm -rf "$OUT_DIR"

nimble gui -- check examples/gui/app.gui
nimble gui -- generate examples/gui/app.gui --out "$OUT_DIR"
nimble gui -- build examples/gui/app.gui --out "$OUT_DIR" --configuration Debug

test -d "$OUT_DIR/MomentumGui/MomentumGui.xcodeproj"
test -f "$OUT_DIR/MomentumGui/App/Generated/GUI.generated.swift"
test -f "$OUT_DIR/MomentumGui/App/Generated/GUIRuntime.generated.swift"

APP_PATH="$(find "$OUT_DIR/MomentumGui/.derivedData" -name 'MomentumGui.app' -type d | head -n 1 || true)"
if [[ -z "$APP_PATH" ]]; then
  echo "ERROR: built app not found"
  exit 1
fi

echo "PASS: GUI integration generate/build"
