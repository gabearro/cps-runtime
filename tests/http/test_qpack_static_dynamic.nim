## QPACK static + dynamic table tests.

import cps/http/shared/qpack

block testStaticAndDynamicRoundTrip:
  let enc = newQpackEncoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  let dec = newQpackDecoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)

  let headers = @[
    (":method", "GET"),
    ("x-demo", "1"),
    ("x-extra", "2")
  ]

  let first = enc.encodeHeaders(headers)
  let firstDecoded = dec.decodeHeaders(first)
  doAssert firstDecoded == headers

  # After first decode, dynamic table entries exist and second pass can reference them.
  let second = enc.encodeHeaders(headers)
  let secondDecoded = dec.decodeHeaders(second)
  doAssert secondDecoded == headers
  doAssert enc.dynamicTable.len >= 2
  doAssert dec.dynamicTable.len >= 2
  doAssert dec.knownInsertCount >= 2
  echo "PASS: QPACK static + dynamic header round-trip"

block testStaticTableCardinality:
  doAssert QpackStaticTable.len == 99
  echo "PASS: QPACK static table cardinality"

block testDynamicEviction:
  let enc = newQpackEncoder(maxTableCapacity = 33, blockedStreamsLimit = 4)
  discard enc.encodeHeaders(@[("a", "b")])
  # field size is name+value+32 => 34, so it must be evicted immediately.
  doAssert enc.dynamicTable.len == 0
  echo "PASS: QPACK dynamic table eviction by capacity"

block testEncoderInstructionCodec:
  let inst = encodeEncoderInsertInstruction("x-key", "x-value")
  let decoded = decodeEncoderInstruction(inst)
  doAssert decoded.kind == qeikInsertLiteral
  doAssert decoded.name == "x-key"
  doAssert decoded.value == "x-value"

  let dec = newQpackDecoder(maxTableCapacity = 1024, blockedStreamsLimit = 4)
  dec.applyEncoderInstruction(decoded)
  doAssert dec.dynamicTable.len == 1
  doAssert dec.dynamicTable[0] == ("x-key", "x-value")

  let ack = encodeDecoderInstruction(QpackDecoderInstruction(kind: qdikInsertCountIncrement, insertCountDelta: 2))
  let ackDecoded = decodeDecoderInstruction(ack)
  doAssert ackDecoded.kind == qdikInsertCountIncrement
  doAssert ackDecoded.insertCountDelta == 2
  echo "PASS: QPACK encoder instruction codec"

block testEncoderNameReferenceInstructions:
  let dec = newQpackDecoder(maxTableCapacity = 1024, blockedStreamsLimit = 4)

  # Static-name reference insert.
  let staticRef = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 31'u64,   # accept-encoding
    nameRefIsStatic: true,
    value: "gzip"
  ))
  dec.applyEncoderInstruction(decodeEncoderInstruction(staticRef))
  doAssert dec.dynamicTable.len == 1
  doAssert dec.dynamicTable[0] == ("accept-encoding", "gzip")

  # Dynamic-name reference insert (index 0 => most-recent dynamic entry).
  let dynRef = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 0'u64,
    nameRefIsStatic: false,
    value: "br"
  ))
  dec.applyEncoderInstruction(decodeEncoderInstruction(dynRef))
  doAssert dec.dynamicTable.len == 2
  doAssert dec.dynamicTable[0] == ("accept-encoding", "br")
  echo "PASS: QPACK encoder name-reference instruction codec"

block testRfcEncoderInsertCountOverflowRejected:
  let enc = newQpackEncoder(maxTableCapacity = 4096, blockedStreamsLimit = 4)
  enc.insertCount = high(uint64)
  enc.requiredInsertCount = 0'u64
  var emitted: seq[QpackEncoderInstruction] = @[]
  var rejected = false
  try:
    discard enc.encodeHeadersRfcWireWithInstructions(@[("x-ovf", "1")], emitted)
  except ValueError:
    rejected = true
  doAssert rejected, "QPACK RFC-wire encoder must reject insert-count overflow"
  doAssert enc.insertCount == high(uint64)
  echo "PASS: QPACK RFC-wire encoder rejects insert-count overflow"

echo "All QPACK static/dynamic tests passed"
