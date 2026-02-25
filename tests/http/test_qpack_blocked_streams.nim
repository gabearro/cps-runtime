## QPACK blocked stream accounting tests.

import cps/http/shared/qpack
import cps/quic/varint

block testEncoderBlockedCounters:
  let enc = newQpackEncoder(maxTableCapacity = 1024, blockedStreamsLimit = 2)
  enc.markBlocked()
  enc.markBlocked()
  enc.markBlocked()
  doAssert enc.blockedStreams == 2

  enc.markUnblocked()
  enc.markUnblocked()
  enc.markUnblocked()
  doAssert enc.blockedStreams == 0
  echo "PASS: QPACK encoder blocked stream accounting"

block testDecoderBlockedCounters:
  let dec = newQpackDecoder(maxTableCapacity = 1024, blockedStreamsLimit = 3)
  dec.markBlocked()
  dec.markBlocked()
  dec.markBlocked()
  dec.markBlocked()
  doAssert dec.blockedStreams == 3

  dec.markUnblocked()
  dec.markUnblocked()
  dec.markUnblocked()
  dec.markUnblocked()
  doAssert dec.blockedStreams == 0
  echo "PASS: QPACK decoder blocked stream accounting"

block testRequiredInsertCountBlocking:
  let dec = newQpackDecoder(maxTableCapacity = 1024, blockedStreamsLimit = 2)
  # Header block prefix: requiredInsertCount=3, base=0, then one static field.
  var headerBlock: seq[byte] = @[]
  headerBlock.appendQuicVarInt(3'u64)
  headerBlock.appendQuicVarInt(0'u64)
  headerBlock.add 0x80'u8
  headerBlock.appendQuicVarInt(17'u64) # :method GET

  var blocked = false
  try:
    discard dec.decodeHeaders(headerBlock)
  except ValueError:
    blocked = true
  doAssert blocked
  doAssert dec.blockedStreams == 1
  echo "PASS: QPACK required-insert-count blocks decode"

echo "All QPACK blocked stream tests passed"
