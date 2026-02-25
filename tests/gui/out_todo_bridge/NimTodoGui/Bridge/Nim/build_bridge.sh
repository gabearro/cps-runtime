#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="/Users/gabriel/Documents/nimlang/cps-impl"
	ENTRY_DEFAULT="examples/gui/todo/bridge.nim"
SOURCE_ENTRY="${GUI_BRIDGE_ENTRY:-$ENTRY_DEFAULT}"
if [[ "$SOURCE_ENTRY" != /* ]]; then
  SOURCE_ENTRY="$REPO_ROOT/$SOURCE_ENTRY"
fi

if [[ ! -f "$SOURCE_ENTRY" ]]; then
  echo "GUI bridge entry not found: $SOURCE_ENTRY" >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  EXT="dylib"
else
  EXT="so"
fi

STAMP="$(date +%s)"
OUT_FILE="$SCRIPT_DIR/libgui_bridge_${STAMP}.${EXT}"
LATEST_FILE="$SCRIPT_DIR/libgui_bridge_latest.${EXT}"

nim c \
  --path:"$REPO_ROOT/src" \
  --threads:on \
  --mm:atomicArc \
  --app:lib \
  --out:"$OUT_FILE" \
  "$SOURCE_ENTRY"

cp "$OUT_FILE" "$LATEST_FILE"

echo "$LATEST_FILE"
