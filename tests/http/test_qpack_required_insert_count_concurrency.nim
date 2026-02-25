## QPACK Required Insert Count and blocked-stream progression tests.

import cps/quic/varint
import cps/http/shared/qpack

proc buildHeaderBlock(requiredInsertCount: uint64, staticIndex: uint64): seq[byte] =
  result = @[]
  result.appendQuicVarInt(requiredInsertCount)
  result.appendQuicVarInt(0'u64) # base
  result.add 0x80'u8
  result.appendQuicVarInt(staticIndex)

block testBlockedThenUnblockedByInsertProgress:
  let dec = newQpackDecoder(maxTableCapacity = 1024, blockedStreamsLimit = 2)
  let hb = buildHeaderBlock(requiredInsertCount = 2'u64, staticIndex = 17'u64) # :method GET

  var blockedCount = 0
  for _ in 0 ..< 2:
    try:
      discard dec.decodeHeaders(hb)
    except ValueError:
      inc blockedCount
  doAssert blockedCount == 2
  doAssert dec.blockedStreams == 2

  dec.applyEncoderInstruction(QpackEncoderInstruction(kind: qeikInsertLiteral, name: "x-a", value: "1"))
  dec.applyEncoderInstruction(QpackEncoderInstruction(kind: qeikInsertLiteral, name: "x-b", value: "2"))
  doAssert dec.knownInsertCount >= 2'u64

  let fields = dec.decodeHeaders(hb)
  doAssert fields.len == 1
  doAssert fields[0] == (":method", "GET")
  doAssert dec.blockedStreams < 2
  echo "PASS: QPACK Required Insert Count blocked/unblocked progression"

echo "All QPACK Required Insert Count concurrency tests passed"
