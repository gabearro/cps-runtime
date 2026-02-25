## User-editable bridge implementation template.
## This file is created once and not overwritten by regeneration.

import std/[os, strutils]
import ./Generated/GUIBridgeNim.generated

type
  GUIBridgeBuffer {.bycopy.} = object
    data: ptr uint8
    len: uint32

  GUIBridgeDispatchOutput {.bycopy.} = object
    statePatch: GUIBridgeBuffer
    effects: GUIBridgeBuffer
    emittedActions: GUIBridgeBuffer
    diagnostics: GUIBridgeBuffer

  GUIBridgeFunctionTable {.bycopy.} = object
    abiVersion: uint32
    alloc: proc(size: csize_t): pointer {.cdecl.}
    free: proc(ptr: pointer) {.cdecl.}
    dispatch: proc(payload: ptr uint8, payloadLen: uint32, outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}

proc bridgeAlloc(size: csize_t): pointer {.cdecl.} =
  if size <= 0: return nil
  allocShared(size)

proc bridgeFree(p: pointer) {.cdecl.} =
  if p != nil:
    deallocShared(p)

proc writeBlob(value: openArray[byte]): GUIBridgeBuffer =
  if value.len == 0:
    return GUIBridgeBuffer(data: nil, len: 0)
  let mem = cast[ptr uint8](bridgeAlloc(value.len.csize_t))
  if mem == nil:
    return GUIBridgeBuffer(data: nil, len: 0)
  copyMem(mem, unsafeAddr value[0], value.len)
  GUIBridgeBuffer(data: mem, len: value.len.uint32)

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32, outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} =
  var inBlob: seq[byte] = @[]
  if payload != nil and payloadLen > 0:
    inBlob = newSeq[byte](payloadLen.int)
    copyMem(addr inBlob[0], payload, payloadLen.int)

  let decoded = decodeBridgePayload(inBlob)

  var statePatch: seq[byte] = @[]
  var effects: seq[byte] = @[]
  var emitted: seq[byte] = @[]
  var diagnostics: seq[byte] = @[]

  # TODO: replace with real reducer/action handling.
  let debugMsg = "bridge dispatch actionTag=" & $ord(decoded.actionTag) & " stateBytes=" & $decoded.stateBlob.len
  diagnostics = newSeq[byte](debugMsg.len)
  if debugMsg.len > 0:
    copyMem(addr diagnostics[0], unsafeAddr debugMsg[0], debugMsg.len)

  if outp != nil:
    outp[].statePatch = writeBlob(statePatch)
    outp[].effects = writeBlob(effects)
    outp[].emittedActions = writeBlob(emitted)
    outp[].diagnostics = writeBlob(diagnostics)

  0'i32

var gBridgeTable = GUIBridgeFunctionTable(
  abiVersion: GUI_BRIDGE_ABI_VERSION.uint32,
  alloc: bridgeAlloc,
  free: bridgeFree,
  dispatch: bridgeDispatch
)

proc gui_bridge_get_table*(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} =
  addr gBridgeTable
