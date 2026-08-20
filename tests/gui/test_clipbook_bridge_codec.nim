import ../../examples/gui/clipbook/bridge
import std/[json, os, strutils]

type
  RequestField = tuple[fieldId: uint16, valueType: uint8, payload: seq[byte]]
  PatchField = tuple[fieldId: uint16, valueType: uint8, payload: seq[byte]]

const
  tagStartCapture = 1'u32
  tagCaptureClipboard = 2'u32
  tagSelectItem = 3'u32
  tagSearchChanged = 4'u32
  tagAddTag = 14'u32
  tagCopyItem = 18'u32
  tagSaveEdit = 28'u32
  tagDeleteItem = 30'u32
  tagRestoreWindow = 52'u32
  fldHistory = 1'u16
  fldSelectedItemId = 6'u16
  fldSelectedTitle = 8'u16
  fldSearchQuery = 18'u16
  fldEditTitle = 22'u16
  fldEditText = 23'u16
  fldTagDraft = 24'u16
  fldIncomingClipboardKind = 51'u16
  fldIncomingClipboardText = 52'u16
  fldIncomingClipboardSource = 54'u16
  fldActionItemId = 56'u16
  bridgeTypeInt64 = 2'u8
  bridgeTypeString = 4'u8
  bridgeTypeJson = 5'u8

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

proc int64Bytes(value: int64): seq[byte] =
  result = newSeq[byte](8)
  var v = uint64(value)
  for i in 0 ..< 8:
    result[i] = byte((v shr (i * 8)) and 0xFF'u64)

proc toText(bytes: seq[byte]): string =
  if bytes.len == 0:
    return ""
  result = newString(bytes.len)
  copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc encodeRequest(actionTag: uint32, fields: seq[RequestField] = @[]): seq[byte] =
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

proc findField(fields: seq[PatchField], fieldId: uint16, valueType: uint8): tuple[found: bool, value: string] =
  for field in fields:
    if field.fieldId == fieldId and field.valueType == valueType:
      return (found: true, value: toText(field.payload))
  (found: false, value: "")

let oldSupport = getEnv("CLIPBOOK_APP_SUPPORT")
let tmpSupport = getTempDir() / "clipbook-bridge-codec-test-" & $getCurrentProcessId()
if dirExists(tmpSupport):
  removeDir(tmpSupport)
putEnv("CLIPBOOK_APP_SUPPORT", tmpSupport)

var runtime = newTestRuntime()

let captureResult = dispatchTest(runtime, encodeRequest(
  tagCaptureClipboard,
  @[
    (fieldId: fldIncomingClipboardKind, valueType: bridgeTypeString, payload: toBytes("Text")),
    (fieldId: fldIncomingClipboardText, valueType: bridgeTypeString, payload: toBytes("Sample clipboard text")),
    (fieldId: fldIncomingClipboardSource, valueType: bridgeTypeString, payload: toBytes("UnitTest"))
  ]
))
assert captureResult.status == 0
let captureFields = decodePatchFields(captureResult.statePatch)
let history = findField(captureFields, fldHistory, bridgeTypeJson)
assert history.found
assert "Sample clipboard text" in history.value

let secondCaptureResult = dispatchTest(runtime, encodeRequest(
  tagCaptureClipboard,
  @[
    (fieldId: fldIncomingClipboardKind, valueType: bridgeTypeString, payload: toBytes("Text")),
    (fieldId: fldIncomingClipboardText, valueType: bridgeTypeString, payload: toBytes("Second clipboard text")),
    (fieldId: fldIncomingClipboardSource, valueType: bridgeTypeString, payload: toBytes("UnitTest"))
  ]
))
assert secondCaptureResult.status == 0

let selectResult = dispatchTest(runtime, encodeRequest(
  tagSelectItem,
  @[(fieldId: fldActionItemId, valueType: bridgeTypeInt64, payload: int64Bytes(1))]
))
assert selectResult.status == 0
let selectFields = decodePatchFields(selectResult.statePatch)
let selectedTitle = findField(selectFields, fldSelectedTitle, bridgeTypeString)
assert selectedTitle.found
assert selectedTitle.value == "Sample clipboard text"

let persistedHistory = readFile(historyMetadataPath())
assert "Sample clipboard text" in persistedHistory

let copyResult = dispatchTest(runtime, encodeRequest(
  tagCopyItem,
  @[(fieldId: fldActionItemId, valueType: bridgeTypeInt64, payload: int64Bytes(1))]
))
assert copyResult.status == 0
let copyFields = decodePatchFields(copyResult.statePatch)
let reorderedHistory = findField(copyFields, fldHistory, bridgeTypeJson)
assert reorderedHistory.found
assert reorderedHistory.value.find("Sample clipboard text") < reorderedHistory.value.find("Second clipboard text")
let copiedHistory = readFile(historyMetadataPath())
let copiedItems = parseJson(copiedHistory)
var sampleItems = 0
var clipBookCopies = 0
for item in copiedItems.items:
  if item{"text"}.getStr() == "Sample clipboard text":
    inc sampleItems
    if item{"sourceApp"}.getStr() == "ClipBook":
      inc clipBookCopies
assert sampleItems == 1
assert clipBookCopies == 0

let editResult = dispatchTest(runtime, encodeRequest(
  tagSaveEdit,
  @[
    (fieldId: fldSelectedItemId, valueType: bridgeTypeInt64, payload: int64Bytes(1)),
    (fieldId: fldEditTitle, valueType: bridgeTypeString, payload: toBytes("Edited sample title")),
    (fieldId: fldEditText, valueType: bridgeTypeString, payload: toBytes("Edited sample body"))
  ]
))
assert editResult.status == 0
let editedItems = parseJson(readFile(historyMetadataPath()))
var editedFound = false
for item in editedItems.items:
  if item{"id"}.getInt() == 1:
    editedFound = item{"title"}.getStr() == "Edited sample title" and item{"text"}.getStr() == "Edited sample body"
assert editedFound

let tagResult = dispatchTest(runtime, encodeRequest(
  tagAddTag,
  @[
    (fieldId: fldSelectedItemId, valueType: bridgeTypeInt64, payload: int64Bytes(1)),
    (fieldId: fldTagDraft, valueType: bridgeTypeString, payload: toBytes("important"))
  ]
))
assert tagResult.status == 0
assert "\"important\"" in readFile(historyMetadataPath())

var startupRuntime = BridgeRuntime()
let restoreResult = dispatchTest(startupRuntime, encodeRequest(tagRestoreWindow))
assert restoreResult.status == 0
assert "Edited sample body" in readFile(historyMetadataPath())

let startupResult = dispatchTest(startupRuntime, encodeRequest(tagStartCapture))
assert startupResult.status == 0
let startupFields = decodePatchFields(startupResult.statePatch)
let startupHistory = findField(startupFields, fldHistory, bridgeTypeJson)
assert startupHistory.found
assert "Edited sample body" in startupHistory.value

let query = "sample"
let searchResult = dispatchTest(runtime, encodeRequest(
  tagSearchChanged,
  @[(fieldId: fldSearchQuery, valueType: bridgeTypeString, payload: toBytes(query))]
))
assert searchResult.status == 0
let searchFields = decodePatchFields(searchResult.statePatch)
let searchQuery = findField(searchFields, fldSearchQuery, bridgeTypeString)
assert searchQuery.found
assert searchQuery.value == query

let deleteResult = dispatchTest(runtime, encodeRequest(
  tagDeleteItem,
  @[(fieldId: fldActionItemId, valueType: bridgeTypeInt64, payload: int64Bytes(1))]
))
assert deleteResult.status == 0
let deletedItems = parseJson(readFile(historyMetadataPath()))
for item in deletedItems.items:
  assert item{"id"}.getInt() != 1

if oldSupport.len > 0:
  putEnv("CLIPBOOK_APP_SUPPORT", oldSupport)
else:
  putEnv("CLIPBOOK_APP_SUPPORT", "")
if dirExists(tmpSupport):
  removeDir(tmpSupport)

echo "PASS: ClipBook bridge binary request->patch roundtrip"
