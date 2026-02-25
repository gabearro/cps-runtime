## HTTP/3 request-stream state machine strictness tests.

import cps/http/shared/http3_connection
import cps/http/shared/http3
import cps/http/shared/webtransport
import cps/http/shared/masque
import cps/quic/varint

proc hasProtocolError(events: seq[Http3Event]): bool =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return true
  false

proc firstProtocolErrorCode(events: seq[Http3Event]): uint64 =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return ev.errorCode
  0'u64

block testDataBeforeHeadersRejected:
  let conn = newHttp3Connection(isClient = false)
  let payload = encodeDataFrame(@[0x01'u8, 0x02])
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 request DATA-before-HEADERS rejected"

block testTrailersWithoutDataAccepted:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]
  let trailers = @[("x-trailer", "done")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add conn.encodeHeadersFrame(trailers)
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert not hasProtocolError(evs)
  doAssert evs.len == 2
  doAssert evs[0].kind == h3evHeaders
  doAssert evs[1].kind == h3evHeaders
  echo "PASS: HTTP/3 request trailers without DATA accepted"

block testDataAfterTrailerWithoutBodyRejected:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]
  let trailers = @[("x-trailer", "done")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add conn.encodeHeadersFrame(trailers)
  payload.add encodeDataFrame(@[0x01'u8])
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 rejects DATA after trailer HEADERS without body"

block testResponseDataBeforeFinalHeadersRejected:
  let client = newHttp3Connection(isClient = true, useRfcQpackWire = false)
  let server = newHttp3Connection(isClient = false, useRfcQpackWire = false)
  var payload: seq[byte] = @[]
  payload.add server.encodeHeadersFrame(@[(":status", "103"), ("link", "</a.css>; rel=preload")])
  payload.add encodeDataFrame(@[0xAA'u8])
  let evs = client.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 response DATA-before-final-HEADERS rejected at stream parser"

block testResponseDataAfterTrailersRejectedByStreamState:
  let client = newHttp3Connection(isClient = true, useRfcQpackWire = false)
  let server = newHttp3Connection(isClient = false, useRfcQpackWire = false)
  var payload: seq[byte] = @[]
  payload.add server.encodeHeadersFrame(@[(":status", "200"), ("content-type", "text/plain")])
  payload.add server.encodeHeadersFrame(@[("x-trailer", "done")])
  payload.add encodeDataFrame(@[0xBB'u8])
  let evs = client.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 response DATA-after-trailers rejected at stream parser"

block testFatalRequestErrorStopsFurtherFrameParsing:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add conn.encodeHeadersFrame(@[("x-trailer", "done")])
  payload.add encodeDataFrame(@[0xAA'u8])
  payload.add encodeDataFrame(@[0xBB'u8])

  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert evs.len == 3
  doAssert evs[0].kind == h3evHeaders
  doAssert evs[1].kind == h3evHeaders
  doAssert evs[2].kind == h3evProtocolError
  doAssert evs[2].errorCode == H3ErrFrameUnexpected
  doAssert conn.requestStreamBufferedBytes(0'u64) == 0
  echo "PASS: HTTP/3 fatal request errors stop further frame parsing"

block testFatalRequestErrorDoesNotCreateTunnelState:
  let conn = newHttp3Connection(isClient = false)
  var payload: seq[byte] = @[]
  payload.add encodeDataFrame(@[0x01'u8])
  payload.add conn.encodeHeadersFrame(
    buildWebTransportConnectHeaders("example.com", "/wt")
  )

  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert evs.len == 1
  doAssert evs[0].kind == h3evProtocolError
  doAssert evs[0].errorCode == H3ErrFrameUnexpected
  doAssert not conn.hasWebTransportSession(0'u64)
  doAssert not conn.hasMasqueSession(0'u64)
  echo "PASS: HTTP/3 fatal request errors do not create tunnel session state"

block testFatalRequestErrorIsFailClosedAcrossCalls:
  let conn = newHttp3Connection(isClient = false)
  let bad = encodeDataFrame(@[0x42'u8]) # DATA before initial HEADERS
  let ev1 = conn.processRequestStreamData(0'u64, bad)
  doAssert hasProtocolError(ev1)
  doAssert firstProtocolErrorCode(ev1) == H3ErrFrameUnexpected

  let goodHeaders = conn.encodeHeadersFrame(@[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/")
  ])
  let ev2 = conn.processRequestStreamData(0'u64, goodHeaders)
  doAssert hasProtocolError(ev2)
  doAssert firstProtocolErrorCode(ev2) == H3ErrFrameUnexpected

  conn.clearRequestStreamState(0'u64)
  let ev3 = conn.processRequestStreamData(0'u64, goodHeaders)
  doAssert not hasProtocolError(ev3)
  doAssert ev3.len == 1
  doAssert ev3[0].kind == h3evHeaders
  echo "PASS: HTTP/3 fatal request stream errors stay fail-closed until cleared"

block testTrailersAfterDataAccepted:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/ok")]
  let trailers = @[("x-trailer", "done")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add encodeDataFrame(@[0xAA'u8])
  payload.add conn.encodeHeadersFrame(trailers)
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert not hasProtocolError(evs)
  doAssert evs.len == 3
  doAssert evs[0].kind == h3evHeaders
  doAssert evs[1].kind == h3evData
  doAssert evs[2].kind == h3evHeaders
  echo "PASS: HTTP/3 HEADERS->DATA->trailing-HEADERS accepted"

block testTrailingPseudoHeadersRejected:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add encodeDataFrame(@[0xAA'u8])
  payload.add conn.encodeHeadersFrame(@[(":status", "200")])
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrMessageError
  echo "PASS: HTTP/3 request trailers reject pseudo-headers"

block testTrailingConnectionSpecificHeaderRejected:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add encodeDataFrame(@[0xBB'u8])
  payload.add conn.encodeHeadersFrame(@[("connection", "keep-alive")])
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrMessageError
  echo "PASS: HTTP/3 request trailers reject connection-specific headers"

block testTrailingContentLengthHeaderRejected:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]
  var payload: seq[byte] = @[]
  payload.add conn.encodeHeadersFrame(headers)
  payload.add encodeDataFrame(@[0xCC'u8])
  payload.add conn.encodeHeadersFrame(@[("content-length", "1")])
  let evs = conn.processRequestStreamData(0'u64, payload)
  doAssert hasProtocolError(evs)
  doAssert firstProtocolErrorCode(evs) == H3ErrMessageError
  echo "PASS: HTTP/3 request trailers reject content-length header"

block testTrailingPseudoHeadersDoNotCreateTunnelState:
  let conn = newHttp3Connection(isClient = false)
  let headers = @[(":method", "GET"), (":scheme", "https"), (":authority", "example.com"), (":path", "/")]

  var wtPayload: seq[byte] = @[]
  wtPayload.add conn.encodeHeadersFrame(headers)
  wtPayload.add encodeDataFrame(@[0x01'u8])
  wtPayload.add conn.encodeHeadersFrame(buildWebTransportConnectHeaders("example.com", "/wt"))

  let wtEvents = conn.processRequestStreamData(0'u64, wtPayload)
  doAssert hasProtocolError(wtEvents)
  doAssert firstProtocolErrorCode(wtEvents) == H3ErrMessageError
  doAssert not conn.hasWebTransportSession(0'u64)

  var masquePayload: seq[byte] = @[]
  masquePayload.add conn.encodeHeadersFrame(headers)
  masquePayload.add encodeDataFrame(@[0x02'u8])
  masquePayload.add conn.encodeHeadersFrame(buildMasqueConnectUdpHeaders("example.com", "example.com:53"))

  let masqueEvents = conn.processRequestStreamData(4'u64, masquePayload)
  doAssert hasProtocolError(masqueEvents)
  doAssert firstProtocolErrorCode(masqueEvents) == H3ErrMessageError
  doAssert not conn.hasMasqueSession(4'u64)
  echo "PASS: trailing pseudo-headers do not create tunnel side effects"

block testIncompleteFrameAtStreamEndRejected:
  let conn = newHttp3Connection(isClient = false)
  var partial: seq[byte] = @[]
  partial.appendQuicVarInt(H3FrameHeaders)
  partial.appendQuicVarInt(16'u64)
  partial.add @[0x01'u8, 0x02'u8]
  discard conn.processRequestStreamData(0'u64, partial)
  let finEvs = conn.finalizeRequestStream(0'u64)
  doAssert hasProtocolError(finEvs)
  doAssert firstProtocolErrorCode(finEvs) == H3ErrFrameError
  echo "PASS: HTTP/3 ended request stream with incomplete frame rejected"

echo "All HTTP/3 request state-machine strict tests passed"
