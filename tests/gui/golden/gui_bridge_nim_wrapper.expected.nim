## Generated Nim bridge shim (typed ABI helpers).

const GUI_BRIDGE_ABI_VERSION* = 5

type
  GuiBridgeActionTag* = enum
    gbatIncrement,
    gbatRefresh,
    gbatSync

  GuiBridgeFieldValue* = object
    fieldId*: uint16
    valueType*: uint8
    payload*: seq[byte]

  GuiBridgeDispatchPayload* = object
    actionTag*: GuiBridgeActionTag
    fields*: seq[GuiBridgeFieldValue]

  GuiBridgeValueType* = enum
    gbvtBool = 1,
    gbvtInt64 = 2,
    gbvtDouble = 3,
    gbvtString = 4,
    gbvtJson = 5

  GuiBridgeDispatchResult* = object
    statePatchBlob*: seq[byte]
    effectsBlob*: seq[byte]
    emittedActionsBlob*: seq[byte]
    diagnosticsBlob*: seq[byte]

proc appendLeU16(dst: var seq[byte], value: uint16) =
  dst.add byte(value and 0xFF'u16)
  dst.add byte((value shr 8) and 0xFF'u16)

proc appendLeU32(dst: var seq[byte], value: uint32) =
  dst.add byte(value and 0xFF'u32)
  dst.add byte((value shr 8) and 0xFF'u32)
  dst.add byte((value shr 16) and 0xFF'u32)
  dst.add byte((value shr 24) and 0xFF'u32)

proc encodeBridgePayload*(payload: GuiBridgeDispatchPayload): seq[byte] =
  ## Binary wire format: [u32 actionTag][u16 fieldCount][u16 reserved][fields...]
  appendLeU32(result, ord(payload.actionTag).uint32)
  let count = min(payload.fields.len, int(high(uint16))).uint16
  appendLeU16(result, count)
  appendLeU16(result, 0'u16)
  var i = 0
  while i < count.int:
    let f = payload.fields[i]
    appendLeU16(result, f.fieldId)
    result.add f.valueType
    result.add 0'u8
    appendLeU32(result, f.payload.len.uint32)
    if f.payload.len > 0:
      result.add f.payload
    inc i

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

  let fieldCount = uint16(blob[4]) or (uint16(blob[5]) shl 8)
  var offset = 8
  var i = 0
  while i < fieldCount.int and offset + 7 < blob.len:
    let fieldId = uint16(blob[offset]) or (uint16(blob[offset + 1]) shl 8)
    let valueType = blob[offset + 2]
    let valueLen =
      uint32(blob[offset + 4]) or (uint32(blob[offset + 5]) shl 8) or
      (uint32(blob[offset + 6]) shl 16) or (uint32(blob[offset + 7]) shl 24)
    offset += 8
    if offset + valueLen.int > blob.len:
      break
    var payloadBytes: seq[byte] = @[]
    if valueLen > 0:
      payloadBytes = newSeq[byte](valueLen.int)
      copyMem(addr payloadBytes[0], unsafeAddr blob[offset], valueLen.int)
    result.fields.add GuiBridgeFieldValue(fieldId: fieldId, valueType: valueType, payload: payloadBytes)
    offset += valueLen.int
    inc i
