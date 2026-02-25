## QPACK RFC-wire Huffman encode/decode tests.

import cps/http/shared/qpack
import cps/http/shared/hpack

proc decodePrefixedIntForTest(data: openArray[byte],
                              offset: var int,
                              firstByte: uint8,
                              prefixBits: int): uint64 =
  let prefixMask = uint8((1 shl prefixBits) - 1)
  let prefixMax = uint64(prefixMask)
  result = uint64(firstByte and prefixMask)
  if result < prefixMax:
    return
  var shift = 0'u32
  while true:
    doAssert offset < data.len, "truncated prefixed integer in test parser"
    let b = data[offset]
    inc offset
    result += uint64(b and 0x7F'u8) shl shift
    if (b and 0x80'u8) == 0'u8:
      break
    shift += 7

proc appendPlainRfcString(dst: var seq[byte], s: string) =
  doAssert s.len < 128
  dst.add uint8(s.len)
  for c in s:
    dst.add byte(ord(c) and 0xFF)

block testHuffmanCodecRoundTrip:
  let samples = @[
    "www.example.com",
    "gzip, deflate, br",
    "accept-encoding",
    "this is a long header value with repeated letters"
  ]

  for sample in samples:
    let encoded = huffmanEncode(sample)
    let decoded = huffmanDecode(encoded, 0, encoded.len)
    doAssert decoded == sample
  echo "PASS: RFC7541 Huffman codec round-trip"

block testQpackRfcWireUsesAndDecodesHuffman:
  let enc = newQpackEncoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  let dec = newQpackDecoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)

  let headers = @[
    ("x-very-long-custom-header-name", "this is a very long value with repeated letters and digits 123456")
  ]
  let encodedBlock = enc.encodeHeadersRfcWire(headers)
  doAssert encodedBlock.len > 2

  var off = 2 # required insert count + delta/base in current RFC-wire fallback path.
  let first = encodedBlock[off]
  inc off
  doAssert (first and 0xE0'u8) == 0x20'u8, "expected literal with literal name field line"
  doAssert (first and 0x08'u8) != 0'u8, "expected Huffman-coded literal name"

  let nameLen = decodePrefixedIntForTest(encodedBlock, off, first, 3)
  off += int(nameLen)
  doAssert off < encodedBlock.len
  doAssert (encodedBlock[off] and 0x80'u8) != 0'u8, "expected Huffman-coded literal value"

  let decodedHeaders = dec.decodeHeadersRfcWire(encodedBlock)
  doAssert decodedHeaders == headers
  echo "PASS: QPACK RFC-wire Huffman name/value encode/decode"

block testQpackRfcWireDecodeDoesNotMutateDynamicTable:
  let enc = newQpackEncoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  let dec = newQpackDecoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  dec.applyEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertLiteral,
    name: "x-dyn",
    value: "1"
  ))
  let knownBefore = dec.knownInsertCount
  let tableBefore = dec.dynamicTable

  let encoded = enc.encodeHeadersRfcWire(@[
    (":method", "GET"),
    ("x-literal", "abc")
  ])
  let decoded = dec.decodeHeadersRfcWire(encoded)
  doAssert decoded == @[
    (":method", "GET"),
    ("x-literal", "abc")
  ]
  doAssert dec.knownInsertCount == knownBefore
  doAssert dec.dynamicTable == tableBefore
  echo "PASS: QPACK RFC-wire header decode leaves dynamic table ownership to encoder stream"

block testQpackRfcWirePostBaseFieldLines:
  let dec = newQpackDecoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  dec.applyEncoderInstruction(QpackEncoderInstruction(kind: qeikInsertLiteral, name: "a", value: "1"))
  dec.applyEncoderInstruction(QpackEncoderInstruction(kind: qeikInsertLiteral, name: "b", value: "2"))
  dec.applyEncoderInstruction(QpackEncoderInstruction(kind: qeikInsertLiteral, name: "c", value: "3"))
  doAssert dec.knownInsertCount == 3'u64
  doAssert dec.dynamicTable.len >= 3

  var encoded: seq[byte] = @[]
  # Header block prefix:
  # - required insert count = 3 -> encoded RIC 4 (with maxEntries=128)
  # - base = 1 -> sign bit set, delta-base = 1
  encoded.add 0x04'u8
  encoded.add 0x81'u8
  # Indexed field line with post-base index = 1 -> dynamic absolute index 2 -> ("c","3")
  encoded.add 0x11'u8
  # Literal field line with post-base name ref index = 0 -> name "b", value "v2"
  encoded.add 0x00'u8
  encoded.appendPlainRfcString("v2")

  let decoded = dec.decodeHeadersRfcWire(encoded)
  doAssert decoded.len == 2
  doAssert decoded[0] == ("c", "3")
  doAssert decoded[1] == ("b", "v2")
  echo "PASS: QPACK RFC-wire post-base indexed/name-ref field lines decode"

block testQpackRfcWireUsesDynamicReferencesAfterAck:
  let enc = newQpackEncoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  let dec = newQpackDecoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  let headers = @[("x-dyn", "v1")]

  var emitted1: seq[QpackEncoderInstruction] = @[]
  let first = enc.encodeHeadersRfcWireWithInstructions(headers, emitted1)
  doAssert first.len > 0
  doAssert first[0] == 0x00'u8, "first encode should be non-blocking literal form"
  doAssert emitted1.len > 0
  for inst in emitted1:
    dec.applyEncoderInstruction(inst)

  enc.applyDecoderInstruction(QpackDecoderInstruction(
    kind: qdikInsertCountIncrement,
    insertCountDelta: uint64(emitted1.len)
  ))
  doAssert enc.requiredInsertCount >= 1'u64

  var emitted2: seq[QpackEncoderInstruction] = @[]
  let second = enc.encodeHeadersRfcWireWithInstructions(headers, emitted2)
  doAssert emitted2.len == 0, "acknowledged dynamic entry should be referenced without reinsertion"

  var off = 0
  let ricFirst = second[off]
  inc off
  let encodedRic = decodePrefixedIntForTest(second, off, ricFirst, 8)
  doAssert encodedRic > 0'u64, "dynamic reference header block must carry non-zero Encoded Required Insert Count"
  doAssert off < second.len
  let dbFirst = second[off]
  inc off
  discard decodePrefixedIntForTest(second, off, dbFirst, 7)
  doAssert off < second.len
  let fieldFirst = second[off]
  doAssert (fieldFirst and 0xC0'u8) == 0x80'u8, "expected indexed field line"
  doAssert (fieldFirst and 0x40'u8) == 0'u8, "expected dynamic (not static) indexed field line"

  let decoded = dec.decodeHeadersRfcWire(second)
  doAssert decoded == headers
  echo "PASS: QPACK RFC-wire dynamic indexed field references after decoder acknowledgment"

block testQpackRfcWireRequiredInsertCountOverflowRejected:
  let dec = newQpackDecoder(maxTableCapacity = 4096, blockedStreamsLimit = 8)
  dec.knownInsertCount = high(uint64)

  # encodedRic=1, deltaBase=0, static indexed field line :status=200.
  # Without overflow checks, Required Insert Count arithmetic wrapped and this
  # malformed block decoded as if requiredInsertCount were 0.
  let malformed = @[0x01'u8, 0x00'u8, 0xD9'u8]
  var rejected = false
  try:
    discard dec.decodeHeadersRfcWire(malformed)
  except ValueError:
    rejected = true
  doAssert rejected, "QPACK RFC-wire decoder must reject Required Insert Count arithmetic overflow"
  echo "PASS: QPACK RFC-wire Required Insert Count overflow rejected"

echo "All QPACK Huffman tests passed"
