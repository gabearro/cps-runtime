## QPACK instruction-stream malformed input handling tests.

import cps/quic/varint
import cps/http/shared/qpack
import cps/http/shared/http3
import cps/http/shared/http3_connection

proc hasProtocolError(events: seq[Http3Event]): bool =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return true
  false

block testMalformedEncoderInstructionRaisesProtocolError:
  let conn = newHttp3Connection(isClient = false)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackEncoderStream)
  discard conn.ingestUniStreamData(7'u64, preface)

  # DUPLICATE with out-of-range index should fail immediately and surface as protocol error.
  let badInst = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikDuplicate,
    duplicateIndex: 9'u64
  ))
  let events = conn.ingestUniStreamData(7'u64, badInst)
  doAssert hasProtocolError(events)
  echo "PASS: malformed QPACK encoder instruction surfaced as protocol error"

block testFragmentedEncoderInstructionStillAccepted:
  let conn = newHttp3Connection(isClient = false)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackEncoderStream)
  discard conn.ingestUniStreamData(7'u64, preface)

  let inst = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertLiteral,
    name: "x-frag-ok",
    value: "1"
  ))
  doAssert inst.len >= 2
  let firstPart = inst[0 ..< 1]
  let secondPart = inst[1 .. ^1]
  let evFirst = conn.ingestUniStreamData(7'u64, firstPart)
  let evSecond = conn.ingestUniStreamData(7'u64, secondPart)
  doAssert not hasProtocolError(evFirst)
  doAssert not hasProtocolError(evSecond)
  doAssert conn.qpackDecoder.dynamicTable.len > 0
  doAssert conn.qpackDecoder.dynamicTable[0] == ("x-frag-ok", "1")
  echo "PASS: fragmented QPACK encoder instruction remains buffered and decodes"

block testOversizedEncoderSetCapacityInstructionRejected:
  let conn = newHttp3Connection(isClient = false)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackEncoderStream)
  discard conn.ingestUniStreamData(7'u64, preface)

  # Malformed Set-Capacity instruction with an oversized prefixed integer.
  let badInst = @[
    0x3F'u8,
    0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
    0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
    0x00'u8
  ]
  let events = conn.ingestUniStreamData(7'u64, badInst)
  doAssert hasProtocolError(events)
  doAssert events[0].errorCode == QpackErrEncoderStream
  echo "PASS: oversized QPACK encoder prefixed integer rejected as protocol error"

block testOversizedDecoderInsertCountIncrementRejected:
  let conn = newHttp3Connection(isClient = true)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackDecoderStream)
  discard conn.ingestUniStreamData(11'u64, preface)

  # Malformed Insert Count Increment instruction with oversized prefixed integer.
  let badInst = @[
    0x3F'u8,
    0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
    0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
    0x00'u8
  ]
  let events = conn.ingestUniStreamData(11'u64, badInst)
  doAssert hasProtocolError(events)
  doAssert events[0].errorCode == QpackErrDecoderStream
  echo "PASS: oversized QPACK decoder prefixed integer rejected as protocol error"

block testDecoderInsertCountIncrementOverflowRejected:
  let conn = newHttp3Connection(isClient = true)
  conn.qpackEncoder.requiredInsertCount = high(uint64) - 1'u64
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackDecoderStream)
  discard conn.ingestUniStreamData(11'u64, preface)

  let inst = encodeDecoderInstruction(
    QpackDecoderInstruction(kind: qdikInsertCountIncrement, insertCountDelta: 2'u64)
  )
  let events = conn.ingestUniStreamData(11'u64, inst)
  doAssert hasProtocolError(events)
  doAssert events[0].errorCode == QpackErrDecoderStream
  doAssert conn.qpackEncoder.requiredInsertCount == high(uint64) - 1'u64
  echo "PASS: overflowing QPACK decoder insert-count increment rejected as protocol error"

block testEncoderInstructionKnownInsertCountOverflowRejected:
  let conn = newHttp3Connection(isClient = false)
  conn.qpackDecoder.knownInsertCount = high(uint64)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackEncoderStream)
  discard conn.ingestUniStreamData(7'u64, preface)

  let inst = encodeEncoderInstruction(
    QpackEncoderInstruction(kind: qeikInsertLiteral, name: "x-ovf", value: "1")
  )
  let events = conn.ingestUniStreamData(7'u64, inst)
  doAssert hasProtocolError(events)
  doAssert events[0].errorCode == QpackErrEncoderStream
  doAssert conn.qpackDecoder.knownInsertCount == high(uint64)
  echo "PASS: overflowing QPACK encoder instruction insert-count rejected as protocol error"

echo "All QPACK instruction-stream error tests passed"
