import ../../examples/gui/torrent/bridge

type
  RequestField = tuple[fieldId: uint16, valueType: uint8, payload: seq[byte]]
  PatchField = tuple[fieldId: uint16, valueType: uint8, payload: seq[byte]]

const
  tagSetDownloadDir = 19'u32
  fldDownloadDir = 12'u16
  bridgeTypeString = 4'u8

proc appendLeU16(dst: var seq[byte], value: uint16) =
  dst.add byte(value and 0xFF'u16)
  dst.add byte((value shr 8) and 0xFF'u16)

proc appendLeU32(dst: var seq[byte], value: uint32) =
  dst.add byte(value and 0xFF'u32)
  dst.add byte((value shr 8) and 0xFF'u32)
  dst.add byte((value shr 16) and 0xFF'u32)
  dst.add byte((value shr 24) and 0xFF'u32)

proc toBytes(text: string): seq[byte] =
  if text.len == 0:
    return @[]
  result = newSeq[byte](text.len)
  copyMem(addr result[0], unsafeAddr text[0], text.len)

proc toText(bytes: seq[byte]): string =
  if bytes.len == 0:
    return ""
  result = newString(bytes.len)
  copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc encodeRequest(actionTag: uint32, fields: seq[RequestField]): seq[byte] =
  appendLeU32(result, actionTag)
  appendLeU16(result, fields.len.uint16)
  appendLeU16(result, 0'u16)
  for field in fields:
    appendLeU16(result, field.fieldId)
    result.add field.valueType
    result.add 0'u8
    appendLeU32(result, field.payload.len.uint32)
    if field.payload.len > 0:
      result.add field.payload

proc decodePatchFields(blob: seq[byte]): seq[PatchField] =
  if blob.len < 4:
    return @[]
  let count = uint16(blob[0]) or (uint16(blob[1]) shl 8)
  var offset = 4
  var i = 0
  while i < count.int and offset + 7 < blob.len:
    let fieldId = uint16(blob[offset]) or (uint16(blob[offset + 1]) shl 8)
    let valueType = blob[offset + 2]
    let valueLen =
      uint32(blob[offset + 4]) or
      (uint32(blob[offset + 5]) shl 8) or
      (uint32(blob[offset + 6]) shl 16) or
      (uint32(blob[offset + 7]) shl 24)
    offset += 8
    if offset + valueLen.int > blob.len:
      break
    var payload: seq[byte] = @[]
    if valueLen > 0:
      payload = newSeq[byte](valueLen.int)
      copyMem(addr payload[0], unsafeAddr blob[offset], valueLen.int)
    result.add((fieldId: fieldId, valueType: valueType, payload: payload))
    offset += valueLen.int
    inc i

proc findStringField(fields: seq[PatchField], fieldId: uint16): tuple[found: bool, value: string] =
  for field in fields:
    if field.fieldId == fieldId and field.valueType == bridgeTypeString:
      return (found: true, value: toText(field.payload))
  (found: false, value: "")

var runtime = newTestRuntime()

let expectedDir = "/tmp/cps-bridge-cutover"
let validPayload = encodeRequest(
  tagSetDownloadDir,
  @[(fieldId: fldDownloadDir, valueType: bridgeTypeString, payload: toBytes(expectedDir))]
)
let validResult = dispatchTest(runtime, validPayload)
assert validResult.status == 0
let validFields = decodePatchFields(validResult.statePatch)
let dirField = findStringField(validFields, fldDownloadDir)
assert dirField.found
assert dirField.value == expectedDir

echo "PASS: torrent bridge binary request->patch roundtrip"

var malformedPayload: seq[byte] = @[]
appendLeU32(malformedPayload, tagSetDownloadDir)
appendLeU16(malformedPayload, 1'u16)
appendLeU16(malformedPayload, 0'u16)
appendLeU16(malformedPayload, fldDownloadDir)
malformedPayload.add bridgeTypeString
malformedPayload.add 0'u8
appendLeU32(malformedPayload, 8'u32)
malformedPayload.add byte('x')
malformedPayload.add byte('y')

let malformedResult = dispatchTest(runtime, malformedPayload)
assert malformedResult.status == 0
let malformedFields = decodePatchFields(malformedResult.statePatch)
let dirAfterMalformed = findStringField(malformedFields, fldDownloadDir)
assert dirAfterMalformed.found
assert dirAfterMalformed.value == expectedDir

echo "PASS: torrent bridge rejects malformed request frame payload"
