#!/bin/bash
if [ -x "$SRCROOT/Bridge/Nim/build_bridge.sh" ]; then
  "$SRCROOT/Bridge/Nim/build_bridge.sh"
fi
BRIDGE_DIR="$SRCROOT/Bridge/Nim"
DEST_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST_DIR"
if [ -f "$BRIDGE_DIR/libgui_bridge_latest.dylib" ]; then
  cp -f "$BRIDGE_DIR/libgui_bridge_latest.dylib" "$DEST_DIR/libgui_bridge_latest.dylib"
elif [ -f "$BRIDGE_DIR/libgui_bridge_latest.so" ]; then
  cp -f "$BRIDGE_DIR/libgui_bridge_latest.so" "$DEST_DIR/libgui_bridge_latest.so"
fi
