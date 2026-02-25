## QPACK instruction-stream fragmentation tests.

import cps/quic/varint
import cps/http/shared/qpack
import cps/http/shared/http3
import cps/http/shared/http3_connection

block testEncoderInstructionFragmentedAcrossUniStreamData:
  let conn = newHttp3Connection(isClient = false)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackEncoderStream)
  discard conn.ingestUniStreamData(7'u64, preface)

  let inst = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertLiteral,
    name: "x-frag",
    value: "1"
  ))
  for b in inst:
    discard conn.ingestUniStreamData(7'u64, @[b])

  doAssert conn.qpackDecoder.dynamicTable.len >= 1
  doAssert conn.qpackDecoder.dynamicTable[0] == ("x-frag", "1")
  echo "PASS: QPACK encoder instruction fragmentation buffered/decoded"

block testDecoderInstructionFragmentedAcrossUniStreamData:
  let conn = newHttp3Connection(isClient = true)
  var preface: seq[byte] = @[]
  preface.appendQuicVarInt(H3UniQpackDecoderStream)
  discard conn.ingestUniStreamData(11'u64, preface)

  let inst = encodeDecoderInstruction(QpackDecoderInstruction(
    kind: qdikInsertCountIncrement,
    insertCountDelta: 3'u64
  ))
  for b in inst:
    discard conn.ingestUniStreamData(11'u64, @[b])

  doAssert conn.qpackEncoder.requiredInsertCount >= 3'u64
  echo "PASS: QPACK decoder instruction fragmentation buffered/decoded"

echo "All QPACK instruction-stream fragmentation tests passed"
