import std/[algorithm, math, times]
import ../../examples/gui/torrent/bridge

type RequestField = tuple[fieldId: uint16, valueType: uint8, payload: seq[byte]]

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

proc percentile95(samples: seq[float]): float =
  if samples.len == 0:
    return 0.0
  var sorted = samples
  sorted.sort()
  let idx = max(0, min(sorted.len - 1, int(ceil(sorted.len.float * 0.95)) - 1))
  sorted[idx]

var runtime = newTestRuntime()

const warmupCount = 25
const sampleCount = 500
var latenciesMs: seq[float] = @[]

for i in 0 ..< warmupCount + sampleCount:
  let dir = "/tmp/cps-bridge-latency-" & $i
  let payload = encodeRequest(
    tagSetDownloadDir,
    @[(fieldId: fldDownloadDir, valueType: bridgeTypeString, payload: toBytes(dir))]
  )
  let t0 = epochTime()
  let result = dispatchTest(runtime, payload)
  let elapsedMs = (epochTime() - t0) * 1000.0
  assert result.status == 0
  if i >= warmupCount:
    latenciesMs.add(elapsedMs)

let p95Ms = percentile95(latenciesMs)
echo "Bridge dispatch p95(ms): ", p95Ms
assert p95Ms < 150.0

echo "PASS: bridge dispatch p95 under 150ms"
