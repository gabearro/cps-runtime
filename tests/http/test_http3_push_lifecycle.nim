## HTTP/3 push and control-stream lifecycle tests.

import std/[tables, strutils]
import cps/http/shared/http3_connection
import cps/http/shared/http3
import cps/http/shared/qpack
import cps/quic/varint

proc hasEvent(events: seq[Http3Event], kind: Http3EventKind): bool =
  for ev in events:
    if ev.kind == kind:
      return true
  false

proc advertiseMaxPushIdTo(server: Http3Connection, client: Http3Connection, maxPushId: uint64) =
  var controlPayload = client.encodeControlStreamPreface()
  controlPayload.add client.advertiseMaxPushId(maxPushId)
  let events = server.ingestUniStreamData(2'u64, controlPayload)
  doAssert hasEvent(events, h3evSettings)
  doAssert hasEvent(events, h3evMaxPushId)

proc samplePushRequestHeaders(path: string): seq[QpackHeaderField] =
  @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", path)
  ]

block testPushPromiseLifecycle:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 8'u64)

  var requestStreamPayload: seq[byte] = @[]
  requestStreamPayload.add server.encodeHeadersFrame(@[(":status", "200")])
  requestStreamPayload.add server.createPushPromise(0'u64, @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/asset.js")
  ])

  let events = client.processRequestStreamData(0'u64, requestStreamPayload)
  doAssert hasEvent(events, h3evHeaders)
  doAssert hasEvent(events, h3evPushPromise)
  doAssert client.pushPromises.hasKey(0'u64)
  echo "PASS: HTTP/3 PUSH_PROMISE parsed on request stream"

block testPushPromiseLifecycleRfcQpackWire:
  let server = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  let client = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  advertiseMaxPushIdTo(server, client, 8'u64)

  var requestStreamPayload: seq[byte] = @[]
  requestStreamPayload.add server.encodeHeadersFrame(@[(":status", "200")])
  requestStreamPayload.add server.createPushPromise(2'u64, @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/asset.css")
  ])

  let events = client.processRequestStreamData(0'u64, requestStreamPayload)
  doAssert hasEvent(events, h3evHeaders)
  doAssert hasEvent(events, h3evPushPromise)
  doAssert client.pushPromises.hasKey(2'u64)
  echo "PASS: HTTP/3 PUSH_PROMISE parses in RFC QPACK wire mode"

block testPushPromiseInvalidHeaderSectionRejected:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 8'u64)

  var payload: seq[byte] = @[]
  payload.add server.encodeHeadersFrame(@[(":status", "200")])
  let invalidPushHeaders = encodeHeaders(server.qpackEncoder, @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/asset.js"),
    ("connection", "keep-alive")
  ])
  payload.add encodePushPromiseFrame(3'u64, invalidPushHeaders)

  let events = client.processRequestStreamData(0'u64, payload)
  doAssert events.len == 2
  doAssert events[1].kind == h3evProtocolError
  doAssert events[1].errorCode == H3ErrMessageError
  doAssert not client.pushPromises.hasKey(3'u64)
  echo "PASS: HTTP/3 PUSH_PROMISE rejects invalid request header sections"

block testDuplicatePushPromiseIdRejectedByClient:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 8'u64)

  var payload: seq[byte] = @[]
  payload.add server.encodeHeadersFrame(@[(":status", "200")])
  payload.add server.createPushPromise(1'u64, samplePushRequestHeaders("/asset.js"))
  let duplicateBlock = encodeHeaders(server.qpackEncoder, samplePushRequestHeaders("/asset-dup.js"))
  payload.add encodePushPromiseFrame(1'u64, duplicateBlock)

  let events = client.processRequestStreamData(0'u64, payload)
  doAssert events.len == 3
  doAssert events[2].kind == h3evProtocolError
  doAssert events[2].errorCode == H3ErrIdError
  echo "PASS: HTTP/3 duplicate PUSH_PROMISE push IDs map to H3_ID_ERROR"

block testServerCannotReuseLocalPushPromiseId:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 8'u64)

  discard server.createPushPromise(3'u64, samplePushRequestHeaders("/asset-a.js"))
  var rejected = false
  try:
    discard server.createPushPromise(3'u64, samplePushRequestHeaders("/asset-b.js"))
  except ValueError:
    rejected = true
  doAssert rejected, "server must reject local PUSH_PROMISE ID reuse"
  echo "PASS: server rejects local PUSH_PROMISE push-id reuse"

block testCreatePushPromiseRejectsOutOfRangeWithoutStateMutation:
  let server = newHttp3Connection(isClient = false)
  let outOfRange = 1'u64 shl 62
  server.hasPeerMaxPushId = true
  server.maxPushIdReceived = outOfRange

  var rejected = false
  try:
    discard server.createPushPromise(outOfRange, samplePushRequestHeaders("/oversized-id"))
  except ValueError:
    rejected = true
  doAssert rejected, "PUSH_PROMISE API must reject push IDs outside QUIC varint range"
  doAssert outOfRange notin server.pushPromises

  let ok = server.createPushPromise(7'u64, samplePushRequestHeaders("/ok"))
  doAssert ok.len > 0
  doAssert 7'u64 in server.pushPromises
  echo "PASS: local PUSH_PROMISE rejects out-of-range varint IDs without mutating state"

block testServerRejectsInvalidLocalPushPromiseHeaders:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 8'u64)

  var rejected = false
  var err = ""
  try:
    discard server.createPushPromise(4'u64, @[
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "example.com")
    ])
  except ValueError as e:
    rejected = true
    err = e.msg
  doAssert rejected, "server must reject locally-generated invalid PUSH_PROMISE headers"
  doAssert err.contains("missing required :path"), "unexpected validation error: " & err
  echo "PASS: server rejects locally-generated invalid PUSH_PROMISE header sections"

block testServerRejectsOversizedLocalPushPromiseHeadersForPeerLimit:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 8'u64)
  server.peerSettings[H3SettingMaxFieldSectionSize] = 64'u64

  var rejected = false
  var err = ""
  try:
    discard server.createPushPromise(5'u64, @[
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "example.com"),
      (":path", "/asset-big.js"),
      ("x-oversized", repeat('a', 256))
    ])
  except ValueError as e:
    rejected = true
    err = e.msg
  doAssert rejected, "server must reject PUSH_PROMISE headers exceeding peer field-section limit"
  doAssert err.contains("SETTINGS_MAX_FIELD_SECTION_SIZE"), "unexpected field-section error: " & err
  echo "PASS: server rejects locally-generated oversized PUSH_PROMISE header sections"

block testClientCannotCreatePushPromiseLocally:
  let client = newHttp3Connection(isClient = true)
  client.hasPeerMaxPushId = true
  client.maxPushIdReceived = 8'u64
  var rejected = false
  try:
    discard client.createPushPromise(1'u64, samplePushRequestHeaders("/client-push"))
  except ValueError:
    rejected = true
  doAssert rejected, "client must not be able to emit PUSH_PROMISE locally"
  echo "PASS: client-side PUSH_PROMISE API usage rejected"

block testControlStreamPushFrames:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)

  var controlPayload = client.encodeControlStreamPreface()
  controlPayload.add client.cancelPush(3'u64)
  controlPayload.add client.sendGoaway(20'u64)

  let events = server.ingestUniStreamData(2'u64, controlPayload)
  doAssert hasEvent(events, h3evSettings)
  doAssert hasEvent(events, h3evCancelPush)
  doAssert hasEvent(events, h3evGoaway)
  doAssert server.hasPeerGoaway
  echo "PASS: HTTP/3 control stream handles client CANCEL_PUSH / GOAWAY"

block testCancelPushFromServerRejectedByClient:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)

  var controlPayload = server.encodeControlStreamPreface()
  controlPayload.add encodeCancelPushFrame(3'u64)
  let events = client.ingestUniStreamData(3'u64, controlPayload)
  doAssert events.len >= 2
  doAssert events[^1].kind == h3evProtocolError
  doAssert events[^1].errorCode == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 CANCEL_PUSH from server maps to H3_FRAME_UNEXPECTED"

block testServerCannotSendCancelPushFrame:
  let server = newHttp3Connection(isClient = false)
  var rejected = false
  try:
    discard server.cancelPush(1'u64)
  except ValueError:
    rejected = true
  doAssert rejected, "server must not be able to emit CANCEL_PUSH frames"
  echo "PASS: server-side CANCEL_PUSH API usage rejected"

block testCancelPushClearsBufferedPushStreamState:
  let client = newHttp3Connection(isClient = true)
  discard client.advertiseMaxPushId(32'u64)

  let streamId = 11'u64
  let pushId = 5'u64
  var partialPush: seq[byte] = @[]
  partialPush.appendQuicVarInt(H3UniPushStream)
  partialPush.appendQuicVarInt(pushId)
  partialPush.appendQuicVarInt(H3FrameHeaders)
  partialPush.appendQuicVarInt(10'u64)
  partialPush.add @[0x01'u8]

  let beforeCancel = client.ingestUniStreamData(streamId, partialPush)
  doAssert beforeCancel.len == 0
  doAssert client.requestStreamBufferedBytes(streamId) > 0
  doAssert streamId in client.requestStates
  doAssert streamId in client.uniStreamTypes

  let cancelFrame = client.cancelPush(pushId)
  doAssert cancelFrame.len > 0
  doAssert client.requestStreamBufferedBytes(streamId) == 0
  doAssert streamId notin client.requestStates
  doAssert streamId notin client.uniStreamTypes
  echo "PASS: local CANCEL_PUSH clears buffered state for existing push stream"

block testMaxPushIdDirectionAndMonotonicity:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)

  var controlPayload = client.encodeControlStreamPreface()
  controlPayload.add encodeMaxPushIdFrame(16'u64)
  let events = server.ingestUniStreamData(2'u64, controlPayload)
  doAssert hasEvent(events, h3evSettings)
  doAssert hasEvent(events, h3evMaxPushId)
  doAssert server.maxPushIdReceived == 16'u64

  let down = server.ingestUniStreamData(2'u64, encodeMaxPushIdFrame(8'u64))
  doAssert down.len == 1
  doAssert down[0].kind == h3evProtocolError
  doAssert down[0].errorCode == H3ErrIdError
  echo "PASS: HTTP/3 MAX_PUSH_ID accepted client->server and rejects decreases"

block testAdvertiseMaxPushIdRejectsOutOfRangeWithoutStateMutation:
  let client = newHttp3Connection(isClient = true)
  let outOfRange = 1'u64 shl 62
  var rejected = false
  try:
    discard client.advertiseMaxPushId(outOfRange)
  except ValueError:
    rejected = true
  doAssert rejected, "MAX_PUSH_ID API must reject values outside QUIC varint range"
  doAssert not client.hasAdvertisedMaxPushId
  doAssert client.maxPushIdAdvertised == 0'u64

  let ok = client.advertiseMaxPushId(5'u64)
  doAssert ok.len > 0
  doAssert client.hasAdvertisedMaxPushId
  doAssert client.maxPushIdAdvertised == 5'u64
  echo "PASS: local MAX_PUSH_ID rejects out-of-range varint IDs without mutating state"

block testMaxPushIdFromServerRejectedByClient:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)

  var controlPayload = server.encodeControlStreamPreface()
  controlPayload.add encodeMaxPushIdFrame(8'u64)
  let events = client.ingestUniStreamData(3'u64, controlPayload)
  doAssert events.len >= 2
  doAssert events[^1].kind == h3evProtocolError
  doAssert events[^1].errorCode == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 MAX_PUSH_ID from server maps to H3_FRAME_UNEXPECTED"

block testCancelPushRejectsOutOfRangeWithoutStateMutation:
  let client = newHttp3Connection(isClient = true)
  let outOfRange = 1'u64 shl 62
  var rejected = false
  try:
    discard client.cancelPush(outOfRange)
  except ValueError:
    rejected = true
  doAssert rejected, "CANCEL_PUSH API must reject values outside QUIC varint range"
  doAssert outOfRange notin client.cancelledPushIds

  let ok = client.cancelPush(7'u64)
  doAssert ok.len > 0
  doAssert 7'u64 in client.cancelledPushIds
  echo "PASS: local CANCEL_PUSH rejects out-of-range varint IDs without mutating state"

block testMalformedControlVarintPayloads:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)

  # Establish control stream first.
  discard server.ingestUniStreamData(2'u64, client.encodeControlStreamPreface())

  let badCancel = server.ingestUniStreamData(2'u64, encodeHttp3Frame(H3FrameCancelPush, @[0x00'u8, 0x00'u8]))
  doAssert badCancel.len == 1
  doAssert badCancel[0].kind == h3evProtocolError
  doAssert badCancel[0].errorCode == H3ErrFrameError

  let peerClient = newHttp3Connection(isClient = true)
  let peerServer = newHttp3Connection(isClient = false)
  discard peerServer.ingestUniStreamData(2'u64, peerClient.encodeControlStreamPreface())
  let badMaxPush = peerServer.ingestUniStreamData(2'u64, encodeHttp3Frame(H3FrameMaxPushId, @[0x00'u8, 0x00'u8]))
  doAssert badMaxPush.len == 1
  doAssert badMaxPush[0].kind == h3evProtocolError
  doAssert badMaxPush[0].errorCode == H3ErrFrameError
  echo "PASS: malformed CANCEL_PUSH/MAX_PUSH_ID payloads map to H3_FRAME_ERROR"

block testFragmentedPushStreamCarriesStablePushId:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  discard client.advertiseMaxPushId(8'u64)

  var pushStreamPayload: seq[byte] = @[]
  pushStreamPayload.appendQuicVarInt(H3UniPushStream)
  pushStreamPayload.appendQuicVarInt(5'u64)
  pushStreamPayload.add server.encodeHeadersFrame(@[(":status", "200")])
  pushStreamPayload.add encodeDataFrame(@[byte('o'), byte('k')])
  doAssert pushStreamPayload.len > 4

  let p1 = pushStreamPayload[0 .. 1]
  let p2 = pushStreamPayload[2 .. 3]
  let p3 = pushStreamPayload[4 .. ^1]

  let ev1 = client.ingestUniStreamData(11'u64, p1)
  doAssert ev1.len == 0
  let ev2 = client.ingestUniStreamData(11'u64, p2)
  doAssert ev2.len == 0
  let ev3 = client.ingestUniStreamData(11'u64, p3)
  doAssert hasEvent(ev3, h3evHeaders)
  doAssert hasEvent(ev3, h3evData)
  for ev in ev3:
    if ev.kind in {h3evHeaders, h3evData}:
      doAssert ev.pushId == 5'u64
  echo "PASS: HTTP/3 fragmented push stream keeps push-id state"

block testPushStreamPrefaceSplitAcrossTypeAndPushId:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  discard client.advertiseMaxPushId(8'u64)

  let partTypeOnly = @[byte(H3UniPushStream)]
  var partRest: seq[byte] = @[]
  partRest.appendQuicVarInt(5'u64)
  partRest.add server.encodeHeadersFrame(@[(":status", "200")])
  partRest.add encodeDataFrame(@[byte('o'), byte('k')])

  let ev1 = client.ingestUniStreamData(11'u64, partTypeOnly)
  doAssert ev1.len == 0
  let ev2 = client.ingestUniStreamData(11'u64, partRest)
  doAssert hasEvent(ev2, h3evHeaders)
  doAssert hasEvent(ev2, h3evData)
  for ev in ev2:
    doAssert ev.kind != h3evProtocolError,
      "Unexpected protocol error after split push preface: " & ev.errorMessage
    if ev.kind in {h3evHeaders, h3evData}:
      doAssert ev.pushId == 5'u64
  echo "PASS: HTTP/3 split push preface preserves PUSH_ID decoding"

block testPushPromiseFromClientRejectedByServer:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)

  var payload: seq[byte] = @[]
  payload.add client.encodeHeadersFrame(@[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/")
  ])
  let invalidPushHeaders = encodeHeaders(client.qpackEncoder, @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/invalid")
  ])
  payload.add encodePushPromiseFrame(0'u64, invalidPushHeaders)
  let events = server.processRequestStreamData(0'u64, payload)
  doAssert events.len == 2
  doAssert events[1].kind == h3evProtocolError
  doAssert events[1].errorCode == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 PUSH_PROMISE from client maps to H3_FRAME_UNEXPECTED"

block testServerCannotPromiseBeforeMaxPushId:
  let server = newHttp3Connection(isClient = false)
  var rejected = false
  try:
    discard server.createPushPromise(0'u64, samplePushRequestHeaders("/early-push"))
  except ValueError:
    rejected = true
  doAssert rejected, "server push must be rejected until MAX_PUSH_ID is received"
  echo "PASS: HTTP/3 server rejects PUSH_PROMISE before receiving MAX_PUSH_ID"

block testServerCannotPromiseAtOrAbovePeerGoawayPushId:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)

  var controlPayload = client.encodeControlStreamPreface()
  controlPayload.add client.advertiseMaxPushId(16'u64)
  controlPayload.add encodeGoawayFrame(6'u64)
  let events = server.ingestUniStreamData(2'u64, controlPayload)
  doAssert hasEvent(events, h3evMaxPushId)
  doAssert hasEvent(events, h3evGoaway)

  var rejectedEq = false
  var rejectedGt = false
  try:
    discard server.createPushPromise(6'u64, samplePushRequestHeaders("/goaway-eq"))
  except ValueError:
    rejectedEq = true
  try:
    discard server.createPushPromise(9'u64, samplePushRequestHeaders("/goaway-gt"))
  except ValueError:
    rejectedGt = true

  doAssert rejectedEq and rejectedGt,
    "server must reject PUSH_PROMISE IDs at/above peer GOAWAY push limit"
  echo "PASS: server enforces peer GOAWAY push-id limit for PUSH_PROMISE creation"

block testServerCannotPromiseCancelledPushId:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)

  var controlPayload = client.encodeControlStreamPreface()
  controlPayload.add client.advertiseMaxPushId(16'u64)
  controlPayload.add encodeCancelPushFrame(3'u64)
  let events = server.ingestUniStreamData(2'u64, controlPayload)
  doAssert hasEvent(events, h3evCancelPush)

  var rejected = false
  try:
    discard server.createPushPromise(3'u64, samplePushRequestHeaders("/cancelled"))
  except ValueError:
    rejected = true
  doAssert rejected, "server must reject PUSH_PROMISE for peer-cancelled push IDs"

  let allowed = server.createPushPromise(4'u64, samplePushRequestHeaders("/allowed"))
  doAssert allowed.len > 0
  echo "PASS: server rejects peer-cancelled push IDs while allowing other IDs"

block testClientRejectsPushPromiseWithoutAdvertisedMaxPushId:
  let client = newHttp3Connection(isClient = true)
  var payload: seq[byte] = @[]
  payload.add client.encodeHeadersFrame(@[(":status", "200")])
  payload.add encodePushPromiseFrame(0'u64, @[])
  let events = client.processRequestStreamData(0'u64, payload)
  var sawIdError = false
  for ev in events:
    if ev.kind == h3evProtocolError and ev.errorCode == H3ErrIdError:
      sawIdError = true
  doAssert sawIdError, "expected H3_ID_ERROR for PUSH_PROMISE before advertised MAX_PUSH_ID"
  echo "PASS: HTTP/3 client rejects PUSH_PROMISE before advertising MAX_PUSH_ID"

block testPushStreamRejectsPushPromiseFrame:
  let client = newHttp3Connection(isClient = true)
  discard client.advertiseMaxPushId(32'u64)

  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(1'u64)
  pushPayload.add client.encodeHeadersFrame(@[(":status", "200")])
  pushPayload.add encodePushPromiseFrame(2'u64, @[])

  let events = client.ingestUniStreamData(11'u64, pushPayload)
  var sawFrameUnexpected = false
  for ev in events:
    if ev.kind == h3evProtocolError and ev.errorCode == H3ErrFrameUnexpected:
      sawFrameUnexpected = true
  doAssert sawFrameUnexpected, "expected H3_FRAME_UNEXPECTED for PUSH_PROMISE on push stream"
  echo "PASS: HTTP/3 push stream rejects PUSH_PROMISE frame"

block testPushStreamMissingStatusRejected:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)
  discard client.advertiseMaxPushId(32'u64)

  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(1'u64)
  pushPayload.add server.encodeHeadersFrame(@[
    ("content-type", "text/plain")
  ])

  let events = client.ingestUniStreamData(11'u64, pushPayload)
  var sawMessageError = false
  for ev in events:
    if ev.kind == h3evProtocolError and ev.errorCode == H3ErrMessageError:
      sawMessageError = true
  doAssert sawMessageError, "expected H3_MESSAGE_ERROR for push stream response without :status"
  echo "PASS: HTTP/3 push stream rejects response HEADERS missing :status"

block testPushStreamConnectionSpecificHeaderRejected:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)
  discard client.advertiseMaxPushId(32'u64)

  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(2'u64)
  pushPayload.add server.encodeHeadersFrame(@[
    (":status", "200"),
    ("connection", "keep-alive")
  ])

  let events = client.ingestUniStreamData(11'u64, pushPayload)
  var sawMessageError = false
  for ev in events:
    if ev.kind == h3evProtocolError and ev.errorCode == H3ErrMessageError:
      sawMessageError = true
  doAssert sawMessageError, "expected H3_MESSAGE_ERROR for push stream response with connection-specific header"
  echo "PASS: HTTP/3 push stream rejects connection-specific response headers"

block testPushStreamPrefaceDoesNotOverwritePushPromiseMetadata:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 16'u64)

  var requestStreamPayload: seq[byte] = @[]
  requestStreamPayload.add server.encodeHeadersFrame(@[(":status", "200")])
  requestStreamPayload.add server.createPushPromise(6'u64, @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/asset.svg")
  ])
  let events = client.processRequestStreamData(0'u64, requestStreamPayload)
  doAssert hasEvent(events, h3evPushPromise)
  doAssert client.pushPromises.hasKey(6'u64)
  doAssert client.pushPromises[6'u64].len > 0

  var prefaceOnly: seq[byte] = @[]
  prefaceOnly.appendQuicVarInt(H3UniPushStream)
  prefaceOnly.appendQuicVarInt(6'u64)
  let prefaceEvents = client.ingestUniStreamData(15'u64, prefaceOnly)
  doAssert prefaceEvents.len == 0
  doAssert client.pushPromises[6'u64].len > 0
  echo "PASS: HTTP/3 push stream preface preserves PUSH_PROMISE metadata"

block testClientIgnoresCancelledPushPromise:
  let server = newHttp3Connection(isClient = false)
  let client = newHttp3Connection(isClient = true)
  advertiseMaxPushIdTo(server, client, 16'u64)
  discard client.cancelPush(4'u64)

  var requestStreamPayload: seq[byte] = @[]
  requestStreamPayload.add server.encodeHeadersFrame(@[(":status", "200")])
  requestStreamPayload.add server.createPushPromise(4'u64, samplePushRequestHeaders("/cancelled-promise"))

  let events = client.processRequestStreamData(0'u64, requestStreamPayload)
  doAssert hasEvent(events, h3evHeaders)
  doAssert not hasEvent(events, h3evPushPromise)
  doAssert not client.pushPromises.hasKey(4'u64)
  echo "PASS: client ignores PUSH_PROMISE for locally-cancelled push ID"

block testDuplicatePushStreamIdRejected:
  let client = newHttp3Connection(isClient = true)
  discard client.advertiseMaxPushId(32'u64)

  var firstPush: seq[byte] = @[]
  firstPush.appendQuicVarInt(H3UniPushStream)
  firstPush.appendQuicVarInt(4'u64)
  let firstEvents = client.ingestUniStreamData(11'u64, firstPush)
  doAssert firstEvents.len == 0

  var duplicatePush: seq[byte] = @[]
  duplicatePush.appendQuicVarInt(H3UniPushStream)
  duplicatePush.appendQuicVarInt(4'u64)
  let secondEvents = client.ingestUniStreamData(15'u64, duplicatePush)
  doAssert secondEvents.len == 1
  doAssert secondEvents[0].kind == h3evProtocolError
  doAssert secondEvents[0].errorCode == H3ErrIdError
  echo "PASS: HTTP/3 duplicate push stream ID maps to H3_ID_ERROR"

block testInvalidServerPushStreamClearsBufferedState:
  let server = newHttp3Connection(isClient = false)
  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.add newSeq[byte](1024)

  let events = server.ingestUniStreamData(14'u64, pushPayload)
  doAssert events.len == 1
  doAssert events[0].kind == h3evProtocolError
  doAssert events[0].errorCode == H3ErrStreamCreation
  doAssert server.totalUniBufferedBytes() == 0
  echo "PASS: invalid push stream clears uni-stream buffered state"

block testClientIgnoresCancelledPushStream:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)
  discard client.advertiseMaxPushId(32'u64)
  discard client.cancelPush(5'u64)

  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(5'u64)
  pushPayload.add server.encodeHeadersFrame(@[(":status", "200")])
  pushPayload.add encodeDataFrame(@[byte('o'), byte('k')])

  let streamId = 11'u64
  let events = client.ingestUniStreamData(streamId, pushPayload)
  doAssert events.len == 0
  doAssert client.requestStreamBufferedBytes(streamId) == 0
  doAssert client.totalUniBufferedBytes() == 0
  doAssert streamId notin client.requestStates
  doAssert streamId notin client.uniStreamTypes
  echo "PASS: client ignores push stream data for locally-cancelled push ID"

block testPushBeforeMaxPushIdClearsStateAndDoesNotPoisonPushIdMap:
  let client = newHttp3Connection(isClient = true)
  var pushPreface: seq[byte] = @[]
  pushPreface.appendQuicVarInt(H3UniPushStream)
  pushPreface.appendQuicVarInt(6'u64)

  let blocked = client.ingestUniStreamData(11'u64, pushPreface)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evProtocolError
  doAssert blocked[0].errorCode == H3ErrIdError
  doAssert client.totalUniBufferedBytes() == 0

  discard client.advertiseMaxPushId(16'u64)
  let accepted = client.ingestUniStreamData(15'u64, pushPreface)
  doAssert accepted.len == 0
  doAssert client.totalUniBufferedBytes() == 0
  doAssert client.pushPromises.hasKey(6'u64)
  echo "PASS: pre-MAX_PUSH_ID push error cleanup avoids stale push-id poisoning"

block testBlockedPushStreamFinPreservesStateForQpackUnblock:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  discard conn.advertiseMaxPushId(8'u64)

  let streamId = 11'u64
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(5'u64)
  pushPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let blocked = conn.ingestUniStreamData(streamId, pushPayload)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evNone
  doAssert blocked[0].errorMessage == "qpack_blocked"

  let finEvents = conn.finalizeUniStream(streamId)
  doAssert finEvents.len == 1
  doAssert finEvents[0].kind == h3evNone
  doAssert finEvents[0].errorMessage == "qpack_blocked"
  doAssert conn.requestStates.hasKey(streamId)
  doAssert conn.requestStreamBufferedBytes(streamId) > 0
  doAssert conn.uniStreamTypes.hasKey(streamId)

  var encoderStreamBytes: seq[byte] = @[]
  encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  let encoderEvents = conn.ingestUniStreamData(7'u64, encoderStreamBytes)
  for ev in encoderEvents:
    doAssert ev.kind != h3evProtocolError

  let retryEvents = conn.ingestUniStreamData(streamId, @[])
  doAssert hasEvent(retryEvents, h3evHeaders)
  for ev in retryEvents:
    if ev.kind == h3evHeaders:
      doAssert ev.pushId == 5'u64
  doAssert streamId notin conn.requestStates
  doAssert streamId notin conn.uniStreamTypes
  doAssert conn.requestStreamBufferedBytes(streamId) == 0
  doAssert conn.totalUniBufferedBytes() == 0
  echo "PASS: blocked push stream can unblock after FIN once QPACK updates arrive"

block testBlockedPushStreamFinKeepsStateUntilQpackUnblock:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  discard conn.advertiseMaxPushId(8'u64)

  let streamId = 13'u64
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(7'u64)
  pushPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let blocked = conn.ingestUniStreamData(streamId, pushPayload)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evNone
  doAssert blocked[0].errorMessage == "qpack_blocked"

  let finEvents = conn.finalizeUniStream(streamId)
  doAssert finEvents.len == 1
  doAssert finEvents[0].kind == h3evNone
  doAssert finEvents[0].errorMessage == "qpack_blocked"

  let retryWithoutUpdates = conn.ingestUniStreamData(streamId, @[])
  doAssert retryWithoutUpdates.len == 1
  doAssert retryWithoutUpdates[0].kind == h3evNone
  doAssert retryWithoutUpdates[0].errorMessage == "qpack_blocked"
  doAssert streamId in conn.requestStates
  doAssert streamId in conn.uniStreamTypes
  echo "PASS: blocked push stream FIN keeps state until QPACK unblock"

block testDirectPushRetryApiPreservesPushId:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  discard conn.advertiseMaxPushId(8'u64)

  let streamId = 11'u64
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(5'u64)
  pushPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let blocked = conn.ingestUniStreamData(streamId, pushPayload)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evNone
  doAssert blocked[0].errorMessage == "qpack_blocked"
  discard conn.finalizeUniStream(streamId)

  var encoderStreamBytes: seq[byte] = @[]
  encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, encoderStreamBytes)

  let retryEvents = conn.processRequestStreamData(streamId, @[], streamRole = h3srPush)
  doAssert hasEvent(retryEvents, h3evHeaders)
  for ev in retryEvents:
    if ev.kind in {h3evHeaders, h3evData}:
      doAssert ev.pushId == 5'u64
  doAssert streamId notin conn.requestStates
  doAssert streamId notin conn.uniStreamTypes
  doAssert conn.requestStreamBufferedBytes(streamId) == 0
  doAssert conn.totalUniBufferedBytes() == 0
  echo "PASS: direct push retry API preserves push-id on unblocked events"

block testDirectPushFinalizeApiPreservesPushId:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  discard conn.advertiseMaxPushId(8'u64)

  let streamId = 15'u64
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(6'u64)
  pushPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let blocked = conn.ingestUniStreamData(streamId, pushPayload)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evNone
  doAssert blocked[0].errorMessage == "qpack_blocked"
  discard conn.finalizeUniStream(streamId)

  var encoderStreamBytes: seq[byte] = @[]
  encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, encoderStreamBytes)

  let retryEvents = conn.finalizeRequestStream(
    streamId,
    allowInformationalHeaders = false,
    streamRole = h3srPush
  )
  doAssert hasEvent(retryEvents, h3evHeaders)
  for ev in retryEvents:
    if ev.kind in {h3evHeaders, h3evData}:
      doAssert ev.pushId == 6'u64
  doAssert streamId notin conn.requestStates
  doAssert streamId notin conn.uniStreamTypes
  doAssert conn.requestStreamBufferedBytes(streamId) == 0
  doAssert conn.totalUniBufferedBytes() == 0
  echo "PASS: direct push finalize API preserves push-id on unblocked events"

block testBlockedPushFinUnblockRejectsIncompleteTail:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  discard conn.advertiseMaxPushId(8'u64)

  let streamId = 17'u64
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  var pushPayload: seq[byte] = @[]
  pushPayload.appendQuicVarInt(H3UniPushStream)
  pushPayload.appendQuicVarInt(7'u64)
  pushPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)
  let fullDataFrame = encodeDataFrame(@[0xAA'u8, 0xBB'u8])
  pushPayload.add fullDataFrame[0 ..< fullDataFrame.len - 1] # truncated tail

  let blocked = conn.ingestUniStreamData(streamId, pushPayload)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evNone
  doAssert blocked[0].errorMessage == "qpack_blocked"

  let finEvents = conn.finalizeUniStream(streamId)
  doAssert finEvents.len == 1
  doAssert finEvents[0].kind == h3evNone
  doAssert finEvents[0].errorMessage == "qpack_blocked"

  var encoderStreamBytes: seq[byte] = @[]
  encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, encoderStreamBytes)

  let retryEvents = conn.ingestUniStreamData(streamId, @[])
  var sawFrameError = false
  for ev in retryEvents:
    if ev.kind == h3evProtocolError and ev.errorCode == H3ErrFrameError:
      sawFrameError = true
  doAssert sawFrameError,
    "Expected ended blocked push stream replay to reject incomplete frame tail"
  doAssert streamId notin conn.requestStates
  doAssert streamId notin conn.uniStreamTypes
  doAssert conn.requestStreamBufferedBytes(streamId) == 0
  doAssert conn.totalUniBufferedBytes() == 0
  echo "PASS: blocked push stream replay rejects incomplete tail after QPACK unblock"

echo "All HTTP/3 push lifecycle tests passed"
