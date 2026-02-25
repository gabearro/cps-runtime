## Generated Nim bridge shim (typed ABI helpers).

const GUI_BRIDGE_ABI_VERSION* = 2

type
  GuiBridgeActionTag* = enum
    gbatIncrement,
    gbatRefresh,
    gbatSync

  GuiBridgeDispatchPayload* = object
    actionTag*: GuiBridgeActionTag
    stateBlob*: seq[byte]

  GuiBridgeDispatchResult* = object
    statePatchBlob*: seq[byte]
    effectsBlob*: seq[byte]
    emittedActionsBlob*: seq[byte]
    diagnosticsBlob*: seq[byte]

proc encodeBridgePayload*(payload: GuiBridgeDispatchPayload): seq[byte] =
  ## Binary wire format: [u32 actionTag][u32 stateLen][stateBlob...]
  let stateLen = payload.stateBlob.len
  result = newSeq[byte](8 + stateLen)
  let actionVal = ord(payload.actionTag).uint32
  result[0] = byte(actionVal and 0xFF'u32)
  result[1] = byte((actionVal shr 8) and 0xFF'u32)
  result[2] = byte((actionVal shr 16) and 0xFF'u32)
  result[3] = byte((actionVal shr 24) and 0xFF'u32)
  let lenVal = stateLen.uint32
  result[4] = byte(lenVal and 0xFF'u32)
  result[5] = byte((lenVal shr 8) and 0xFF'u32)
  result[6] = byte((lenVal shr 16) and 0xFF'u32)
  result[7] = byte((lenVal shr 24) and 0xFF'u32)
  if stateLen > 0:
    copyMem(addr result[8], unsafeAddr payload.stateBlob[0], stateLen)

proc decodeBridgePayload*(blob: openArray[byte]): GuiBridgeDispatchPayload =
  if blob.len < 8:
    result.actionTag = low(GuiBridgeActionTag)
    return
  let actionVal =
    uint32(blob[0]) or (uint32(blob[1]) shl 8) or
    (uint32(blob[2]) shl 16) or (uint32(blob[3]) shl 24)
  if actionVal <= ord(high(GuiBridgeActionTag)).uint32:
    result.actionTag = GuiBridgeActionTag(actionVal.int)
  else:
    result.actionTag = low(GuiBridgeActionTag)

  let stateLen =
    uint32(blob[4]) or (uint32(blob[5]) shl 8) or
    (uint32(blob[6]) shl 16) or (uint32(blob[7]) shl 24)
  let needed = 8 + stateLen.int
  if stateLen > 0 and blob.len >= needed:
    result.stateBlob = newSeq[byte](stateLen.int)
    copyMem(addr result.stateBlob[0], unsafeAddr blob[8], stateLen.int)
