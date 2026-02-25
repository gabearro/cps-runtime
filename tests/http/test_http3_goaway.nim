## HTTP/3 GOAWAY tests.

import cps/quic/varint
import cps/http/shared/http3
import cps/http/shared/http3_connection

block testGoawayDecodeOnControlStream:
  let conn = newHttp3Connection(isClient = true)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  let goaway = encodeGoawayFrame(124'u64)
  let events = conn.processControlStreamData(2'u64, goaway)
  doAssert events.len == 1
  doAssert events[0].kind == h3evGoaway
  doAssert events[0].goawayId == 124'u64
  doAssert conn.controlState == h3csClosing
  echo "PASS: HTTP/3 GOAWAY frame decode"

block testGoawayViaUniStreamIngest:
  let conn = newHttp3Connection(isClient = false)
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, @[])
  payload.add encodeGoawayFrame(41'u64)

  let events = conn.ingestUniStreamData(2'u64, payload)
  doAssert events.len == 2
  doAssert events[0].kind == h3evSettings
  doAssert events[1].kind == h3evGoaway
  doAssert events[1].goawayId == 41'u64
  doAssert conn.controlState == h3csClosing
  echo "PASS: HTTP/3 GOAWAY via control uni-stream"

block testMalformedGoawayPayloadSignalsFrameError:
  let conn = newHttp3Connection(isClient = true)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  let malformed = encodeHttp3Frame(H3FrameGoaway, @[0x40'u8]) # varint prefix without full payload
  let events = conn.processControlStreamData(2'u64, malformed)
  doAssert events.len == 1
  doAssert events[0].kind == h3evProtocolError
  doAssert events[0].errorCode == H3ErrFrameError
  echo "PASS: malformed HTTP/3 GOAWAY payload maps to H3_FRAME_ERROR"

block testGoawayPayloadWithTrailingBytesSignalsFrameError:
  let conn = newHttp3Connection(isClient = true)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  let malformed = encodeHttp3Frame(H3FrameGoaway, @[0x00'u8, 0x00'u8]) # valid varint + trailing junk
  let events = conn.processControlStreamData(2'u64, malformed)
  doAssert events.len == 1
  doAssert events[0].kind == h3evProtocolError
  doAssert events[0].errorCode == H3ErrFrameError
  echo "PASS: GOAWAY payload with trailing bytes maps to H3_FRAME_ERROR"

block testGoawayMustBeNonIncreasing:
  let conn = newHttp3Connection(isClient = true)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  let first = conn.processControlStreamData(2'u64, encodeGoawayFrame(12'u64))
  doAssert first.len == 1
  doAssert first[0].kind == h3evGoaway
  let second = conn.processControlStreamData(2'u64, encodeGoawayFrame(16'u64))
  doAssert second.len == 1
  doAssert second[0].kind == h3evProtocolError
  doAssert second[0].errorCode == H3ErrIdError
  echo "PASS: increasing GOAWAY ID maps to H3_ID_ERROR"

block testGoawayIdMustMatchPeerRequestStreamType:
  let conn = newHttp3Connection(isClient = true)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  let invalid = conn.processControlStreamData(2'u64, encodeGoawayFrame(5'u64))
  doAssert invalid.len == 1
  doAssert invalid[0].kind == h3evProtocolError
  doAssert invalid[0].errorCode == H3ErrIdError
  echo "PASS: invalid GOAWAY request-stream type maps to H3_ID_ERROR"

block testServerAcceptsClientGoawayPushId:
  let conn = newHttp3Connection(isClient = false)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  let events = conn.processControlStreamData(2'u64, encodeGoawayFrame(6'u64))
  doAssert events.len == 1
  doAssert events[0].kind == h3evGoaway
  doAssert events[0].goawayId == 6'u64
  doAssert conn.controlState == h3csClosing
  echo "PASS: server accepts client GOAWAY push ID"

block testLocalGoawayDoesNotRelaxPeerGoawayLimit:
  let conn = newHttp3Connection(isClient = true)
  discard conn.processControlStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  discard conn.processControlStreamData(2'u64, encodeGoawayFrame(4'u64))
  doAssert conn.openRequest() == 0'u64
  discard conn.sendGoaway(128'u64)

  var rejected = false
  try:
    discard conn.openRequest()
  except ValueError:
    rejected = true
  doAssert rejected, "peer GOAWAY limit must still block new request IDs after sending local GOAWAY"
  echo "PASS: local GOAWAY does not modify peer GOAWAY request limit"

block testServerLocalGoawayIdMustBeValidRequestStreamType:
  let server = newHttp3Connection(isClient = false)
  var rejected = false
  try:
    discard server.sendGoaway(1'u64) # not a client-initiated bidirectional stream ID
  except ValueError:
    rejected = true
  doAssert rejected, "server local GOAWAY must reject non-request-stream IDs"
  echo "PASS: server local GOAWAY rejects invalid request-stream ID type"

block testLocalGoawayMustBeNonIncreasing:
  let server = newHttp3Connection(isClient = false)
  discard server.sendGoaway(12'u64)
  discard server.sendGoaway(8'u64)
  var rejected = false
  try:
    discard server.sendGoaway(16'u64)
  except ValueError:
    rejected = true
  doAssert rejected, "local GOAWAY IDs must be non-increasing"
  echo "PASS: local GOAWAY ID monotonicity enforced"

block testClientLocalGoawayMayDecreasePushId:
  let client = newHttp3Connection(isClient = true)
  discard client.sendGoaway(10'u64)
  var raised = false
  try:
    discard client.sendGoaway(6'u64)
  except ValueError:
    raised = true
  doAssert not raised, "client local GOAWAY should allow decreasing push-id limits"
  echo "PASS: client local GOAWAY supports decreasing push-id limits"

block testLocalGoawayRejectsOutOfRangeVarintWithoutStateMutation:
  let client = newHttp3Connection(isClient = true)
  let outOfRange = 1'u64 shl 62
  var rejected = false
  try:
    discard client.sendGoaway(outOfRange)
  except ValueError:
    rejected = true
  doAssert rejected, "local GOAWAY must reject IDs outside QUIC varint range"
  doAssert client.controlState == h3csInit

  # A valid GOAWAY must still be sendable after rejecting the invalid ID.
  let ok = client.sendGoaway(0'u64)
  doAssert ok.len > 0
  doAssert client.controlState == h3csGoawaySent
  echo "PASS: local GOAWAY rejects out-of-range varint IDs without mutating state"

block testServerCannotOpenLocalRequestStreams:
  let server = newHttp3Connection(isClient = false)
  var rejected = false
  try:
    discard server.openRequest()
  except ValueError:
    rejected = true
  doAssert rejected, "server role must not open local request streams"
  echo "PASS: server cannot open local request streams"

block testClientOpenRequestRejectsOutOfRangeQuicStreamId:
  let client = newHttp3Connection(isClient = true)
  client.nextLocalRequestStreamId = 1'u64 shl 62
  var rejected = false
  try:
    discard client.openRequest()
  except ValueError:
    rejected = true
  doAssert rejected, "client openRequest must reject stream IDs above QUIC varint range"
  echo "PASS: client openRequest rejects out-of-range QUIC stream IDs"

block testClientOpenRequestRejectsMisalignedNextStreamId:
  let client = newHttp3Connection(isClient = true)
  client.nextLocalRequestStreamId = 2'u64
  var rejected = false
  try:
    discard client.openRequest()
  except ValueError:
    rejected = true
  doAssert rejected, "client openRequest must reject non-client-bidirectional next stream IDs"
  echo "PASS: client openRequest rejects misaligned next stream ID"

echo "All HTTP/3 GOAWAY tests passed"
