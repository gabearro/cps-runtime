## Bridge artifact codegen for Nim side.

import std/[strutils]
import ./ir
import ./bridge_codegen_swift

proc nimEscape(value: string): string =
  value
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")

proc identPart(value: string): string =
  var text = ""
  for c in value:
    if c.isAlphaNumeric or c == '_':
      text.add c
    else:
      text.add '_'
  if text.len == 0:
    return "Action"
  if text[0].isDigit:
    text = "A_" & text
  text

proc emitBridgeNimShim*(irProgram: GuiIrProgram): string =
  var lines: seq[string] = @[]

  lines.add "## Generated Nim bridge shim (typed ABI helpers)."
  lines.add ""
  lines.add "const GUI_BRIDGE_ABI_VERSION* = " & $guiBridgeAbiVersion
  lines.add ""
  lines.add "type"
  lines.add "  GuiBridgeActionTag* = enum"
  if irProgram.actions.len == 0:
    lines.add "    gbatNone"
  else:
    for i, action in irProgram.actions:
      let suffix = if i + 1 < irProgram.actions.len: "," else: ""
      lines.add "    gbat" & identPart(action.name) & suffix
  lines.add ""
  lines.add "  GuiBridgeFieldValue* = object"
  lines.add "    fieldId*: uint16"
  lines.add "    valueType*: uint8"
  lines.add "    payload*: seq[byte]"
  lines.add ""
  lines.add "  GuiBridgeDispatchPayload* = object"
  lines.add "    actionTag*: GuiBridgeActionTag"
  lines.add "    fields*: seq[GuiBridgeFieldValue]"
  lines.add ""
  lines.add "  GuiBridgeValueType* = enum"
  lines.add "    gbvtBool = 1,"
  lines.add "    gbvtInt64 = 2,"
  lines.add "    gbvtDouble = 3,"
  lines.add "    gbvtString = 4,"
  lines.add "    gbvtJson = 5"
  lines.add ""
  lines.add "  GuiBridgeDispatchResult* = object"
  lines.add "    statePatchBlob*: seq[byte]"
  lines.add "    effectsBlob*: seq[byte]"
  lines.add "    emittedActionsBlob*: seq[byte]"
  lines.add "    diagnosticsBlob*: seq[byte]"
  lines.add ""
  lines.add "proc appendLeU16(dst: var seq[byte], value: uint16) ="
  lines.add "  dst.add byte(value and 0xFF'u16)"
  lines.add "  dst.add byte((value shr 8) and 0xFF'u16)"
  lines.add ""
  lines.add "proc appendLeU32(dst: var seq[byte], value: uint32) ="
  lines.add "  dst.add byte(value and 0xFF'u32)"
  lines.add "  dst.add byte((value shr 8) and 0xFF'u32)"
  lines.add "  dst.add byte((value shr 16) and 0xFF'u32)"
  lines.add "  dst.add byte((value shr 24) and 0xFF'u32)"
  lines.add ""
  lines.add "proc encodeBridgePayload*(payload: GuiBridgeDispatchPayload): seq[byte] ="
  lines.add "  ## Binary wire format: [u32 actionTag][u16 fieldCount][u16 reserved][fields...]"
  lines.add "  appendLeU32(result, ord(payload.actionTag).uint32)"
  lines.add "  let count = min(payload.fields.len, int(high(uint16))).uint16"
  lines.add "  appendLeU16(result, count)"
  lines.add "  appendLeU16(result, 0'u16)"
  lines.add "  var i = 0"
  lines.add "  while i < count.int:"
  lines.add "    let f = payload.fields[i]"
  lines.add "    appendLeU16(result, f.fieldId)"
  lines.add "    result.add f.valueType"
  lines.add "    result.add 0'u8"
  lines.add "    appendLeU32(result, f.payload.len.uint32)"
  lines.add "    if f.payload.len > 0:"
  lines.add "      result.add f.payload"
  lines.add "    inc i"
  lines.add ""
  lines.add "proc decodeBridgePayload*(blob: openArray[byte]): GuiBridgeDispatchPayload ="
  lines.add "  if blob.len < 8:"
  lines.add "    result.actionTag = low(GuiBridgeActionTag)"
  lines.add "    return"
  lines.add "  let actionVal ="
  lines.add "    uint32(blob[0]) or (uint32(blob[1]) shl 8) or"
  lines.add "    (uint32(blob[2]) shl 16) or (uint32(blob[3]) shl 24)"
  lines.add "  if actionVal <= ord(high(GuiBridgeActionTag)).uint32:"
  lines.add "    result.actionTag = GuiBridgeActionTag(actionVal.int)"
  lines.add "  else:"
  lines.add "    result.actionTag = low(GuiBridgeActionTag)"
  lines.add ""
  lines.add "  let fieldCount = uint16(blob[4]) or (uint16(blob[5]) shl 8)"
  lines.add "  var offset = 8"
  lines.add "  var i = 0"
  lines.add "  while i < fieldCount.int and offset + 7 < blob.len:"
  lines.add "    let fieldId = uint16(blob[offset]) or (uint16(blob[offset + 1]) shl 8)"
  lines.add "    let valueType = blob[offset + 2]"
  lines.add "    let valueLen ="
  lines.add "      uint32(blob[offset + 4]) or (uint32(blob[offset + 5]) shl 8) or"
  lines.add "      (uint32(blob[offset + 6]) shl 16) or (uint32(blob[offset + 7]) shl 24)"
  lines.add "    offset += 8"
  lines.add "    if offset + valueLen.int > blob.len:"
  lines.add "      break"
  lines.add "    var payloadBytes: seq[byte] = @[]"
  lines.add "    if valueLen > 0:"
  lines.add "      payloadBytes = newSeq[byte](valueLen.int)"
  lines.add "      copyMem(addr payloadBytes[0], unsafeAddr blob[offset], valueLen.int)"
  lines.add "    result.fields.add GuiBridgeFieldValue(fieldId: fieldId, valueType: valueType, payload: payloadBytes)"
  lines.add "    offset += valueLen.int"
  lines.add "    inc i"

  lines.join("\n") & "\n"

proc emitBridgeImplTemplate*(irProgram: GuiIrProgram): string =
  var lines: seq[string] = @[]

  lines.add "## User-editable bridge implementation template."
  lines.add "## This file is created once and not overwritten by regeneration."
  lines.add ""
  lines.add "import std/[os, strutils]"
  lines.add "import ./Generated/GUIBridgeNim.generated"
  lines.add ""
  lines.add "type"
  lines.add "  GUIBridgeBuffer {.bycopy.} = object"
  lines.add "    data: ptr uint8"
  lines.add "    len: uint32"
  lines.add ""
  lines.add "  GUIBridgeDispatchOutput {.bycopy.} = object"
  lines.add "    statePatch: GUIBridgeBuffer"
  lines.add "    effects: GUIBridgeBuffer"
  lines.add "    emittedActions: GUIBridgeBuffer"
  lines.add "    diagnostics: GUIBridgeBuffer"
  lines.add ""
  lines.add "  GUIBridgeFunctionTable {.bycopy.} = object"
  lines.add "    abiVersion: uint32"
  lines.add "    alloc: proc(size: csize_t): pointer {.cdecl.}"
  lines.add "    free: proc(ptr: pointer) {.cdecl.}"
  lines.add "    dispatch: proc(payload: ptr uint8, payloadLen: uint32, outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}"
  lines.add "    getNotifyFd: proc(): int32 {.cdecl.}"
  lines.add "    waitShutdown: proc(timeoutMs: int32): int32 {.cdecl.}"
  lines.add ""
  lines.add "proc bridgeAlloc(size: csize_t): pointer {.cdecl.} ="
  lines.add "  if size <= 0: return nil"
  lines.add "  allocShared(size)"
  lines.add ""
  lines.add "proc bridgeFree(p: pointer) {.cdecl.} ="
  lines.add "  if p != nil:"
  lines.add "    deallocShared(p)"
  lines.add ""
  lines.add "proc writeBlob(value: openArray[byte]): GUIBridgeBuffer ="
  lines.add "  if value.len == 0:"
  lines.add "    return GUIBridgeBuffer(data: nil, len: 0)"
  lines.add "  let mem = cast[ptr uint8](bridgeAlloc(value.len.csize_t))"
  lines.add "  if mem == nil:"
  lines.add "    return GUIBridgeBuffer(data: nil, len: 0)"
  lines.add "  copyMem(mem, unsafeAddr value[0], value.len)"
  lines.add "  GUIBridgeBuffer(data: mem, len: value.len.uint32)"
  lines.add ""
  lines.add "proc bridgeGetNotifyFd(): int32 {.cdecl.} ="
  lines.add "  -1'i32"
  lines.add ""
  lines.add "proc bridgeWaitShutdown(timeoutMs: int32): int32 {.cdecl.} ="
  lines.add "  0'i32"
  lines.add ""
  lines.add "proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32, outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} ="
  lines.add "  var inBlob: seq[byte] = @[]"
  lines.add "  if payload != nil and payloadLen > 0:"
  lines.add "    inBlob = newSeq[byte](payloadLen.int)"
  lines.add "    copyMem(addr inBlob[0], payload, payloadLen.int)"
  lines.add ""
  lines.add "  let decoded = decodeBridgePayload(inBlob)"
  lines.add ""
  lines.add "  var statePatch: seq[byte] = @[]"
  lines.add "  var effects: seq[byte] = @[]"
  lines.add "  var emitted: seq[byte] = @[]"
  lines.add "  var diagnostics: seq[byte] = @[]"
  lines.add ""
  lines.add "  # TODO: replace with real reducer/action handling."
  lines.add "  let debugMsg = \"bridge dispatch actionTag=\" & $ord(decoded.actionTag) & \" fieldCount=\" & $decoded.fields.len"
  lines.add "  diagnostics = newSeq[byte](debugMsg.len)"
  lines.add "  if debugMsg.len > 0:"
  lines.add "    copyMem(addr diagnostics[0], unsafeAddr debugMsg[0], debugMsg.len)"
  lines.add ""
  lines.add "  if outp != nil:"
  lines.add "    outp[].statePatch = writeBlob(statePatch)"
  lines.add "    outp[].effects = writeBlob(effects)"
  lines.add "    outp[].emittedActions = writeBlob(emitted)"
  lines.add "    outp[].diagnostics = writeBlob(diagnostics)"
  lines.add ""
  lines.add "  0'i32"
  lines.add ""
  lines.add "var gBridgeTable = GUIBridgeFunctionTable("
  lines.add "  abiVersion: GUI_BRIDGE_ABI_VERSION.uint32,"
  lines.add "  alloc: bridgeAlloc,"
  lines.add "  free: bridgeFree,"
  lines.add "  dispatch: bridgeDispatch,"
  lines.add "  getNotifyFd: bridgeGetNotifyFd,"
  lines.add "  waitShutdown: bridgeWaitShutdown"
  lines.add ")"
  lines.add ""
  lines.add "proc gui_bridge_get_table*(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} ="
  lines.add "  addr gBridgeTable"

  lines.join("\n") & "\n"

proc emitBridgeBuildScript*(repoRoot: string, defaultBridgeEntry: string): string =
  let escapedRoot = nimEscape(repoRoot)
  let escapedEntry = nimEscape(defaultBridgeEntry)

  """#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=""" & "\"" & escapedRoot & "\"" & """

	ENTRY_DEFAULT=""" & "\"" & escapedEntry & "\"" & """

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
"""
