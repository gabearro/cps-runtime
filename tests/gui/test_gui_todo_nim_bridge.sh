#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "SKIP: xcodebuild not available"
  exit 0
fi

OUT_DIR="$ROOT_DIR/tests/gui/out_todo_bridge"
rm -rf "$OUT_DIR"

nimble gui -- check examples/gui/todo/app.gui
nimble gui -- build examples/gui/todo/app.gui --out "$OUT_DIR" --configuration Debug

APP_ROOT="$OUT_DIR/NimTodoGui"
test -d "$APP_ROOT/NimTodoGui.xcodeproj"
test -f "$APP_ROOT/App/Generated/GUI.generated.swift"
test -f "$APP_ROOT/Bridge/Generated/GUIBridge.generated.h"

if [[ -f "$APP_ROOT/Bridge/Nim/libgui_bridge_latest.dylib" ]]; then
  BRIDGE_DYLIB="$APP_ROOT/Bridge/Nim/libgui_bridge_latest.dylib"
elif [[ -f "$APP_ROOT/Bridge/Nim/libgui_bridge_latest.so" ]]; then
  BRIDGE_DYLIB="$APP_ROOT/Bridge/Nim/libgui_bridge_latest.so"
else
  echo "ERROR: bridge dylib not found"
  exit 1
fi

APP_BUNDLE="$(find "$APP_ROOT/.derivedData" -name 'NimTodoGui.app' -type d | head -n 1 || true)"
if [[ -z "$APP_BUNDLE" ]]; then
  echo "ERROR: built app not found"
  exit 1
fi

if [[ -f "$APP_BUNDLE/Contents/Frameworks/libgui_bridge_latest.dylib" ]]; then
  BUNDLED_BRIDGE="$APP_BUNDLE/Contents/Frameworks/libgui_bridge_latest.dylib"
elif [[ -f "$APP_BUNDLE/Contents/Frameworks/libgui_bridge_latest.so" ]]; then
  BUNDLED_BRIDGE="$APP_BUNDLE/Contents/Frameworks/libgui_bridge_latest.so"
else
  echo "ERROR: bundled bridge dylib not found in app framework dir"
  exit 1
fi

echo "bridge: $BRIDGE_DYLIB"
echo "bundled bridge: $BUNDLED_BRIDGE"
echo "PASS: Todo GUI bridge build"
