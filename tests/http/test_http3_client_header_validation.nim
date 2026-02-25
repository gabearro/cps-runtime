## HTTP/3 client response-header validation tests.

import std/tables
import cps/http/client/http3 as client_http3
import cps/http/shared/http3
import cps/http/shared/http3_connection

proc expectProtocolError(session: client_http3.Http3ClientSession,
                         streamId: uint64,
                         payload: seq[byte],
                         expectedCode: uint64,
                         msg: string,
                         requestMethod: string = "") =
  var raised = false
  var gotCode = 0'u64
  var gotStreamId = high(uint64)
  try:
    discard session.decodeResponseFrames(streamId, payload, requestMethod = requestMethod)
  except client_http3.Http3ProtocolError as e:
    raised = true
    gotCode = e.errorCode
    gotStreamId = e.streamId
  doAssert raised, msg
  doAssert gotCode == expectedCode, "Unexpected HTTP/3 error code: " & $gotCode
  doAssert gotStreamId == streamId, "Unexpected HTTP/3 error stream id: " & $gotStreamId

block testMissingStatusPseudoHeaderRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[("content-type", "text/plain")])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected missing :status pseudo-header to be rejected"
  )
  echo "PASS: HTTP/3 client rejects response missing :status pseudo-header"

block testDuplicateStatusPseudoHeaderRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    (":status", "204")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected duplicate :status pseudo-header to be rejected"
  )
  echo "PASS: HTTP/3 client rejects duplicate :status pseudo-header"

block testStatusPseudoHeaderMustBeThreeDigits:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "0200"),
    ("content-type", "text/plain")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected non-3-digit :status pseudo-header to be rejected"
  )
  echo "PASS: HTTP/3 client rejects non-3-digit :status pseudo-header"

block testUnknownResponsePseudoHeaderRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    (":unknown", "x")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected unknown response pseudo-header to be rejected"
  )
  echo "PASS: HTTP/3 client rejects unknown response pseudo-header"

block testPseudoHeaderOrderingRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    ("x-test", "1"),
    (":status", "200")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected pseudo-header ordering violation to be rejected"
  )
  echo "PASS: HTTP/3 client rejects pseudo-header ordering violations"

block testPseudoHeaderInTrailersRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[(":status", "200")])
  payload.add encodeDataFrame(@[0x41'u8])
  payload.add session.conn.encodeHeadersFrame(@[(":status", "204")])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected pseudo-header in trailers to be rejected"
  )
  echo "PASS: HTTP/3 client rejects pseudo-headers in trailers"

block testInformationalThenFinalResponseAccepted:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "103"),
    ("link", "</style.css>; rel=preload")
  ])
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-type", "text/plain")
  ])
  payload.add encodeDataFrame(@[byte('o'), byte('k')])
  let resp = session.decodeResponseFrames(streamId, payload)
  doAssert resp.statusCode == 200
  doAssert resp.body == "ok"
  doAssert ("content-type", "text/plain") in resp.headers
  doAssert ("link", "</style.css>; rel=preload") notin resp.headers,
    "Informational headers should not leak into final response headers"
  echo "PASS: HTTP/3 client accepts informational response before final response"

block testStatus101InformationalRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "101")
  ])
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected HTTP/3 client to reject 101 informational responses"
  )
  echo "PASS: HTTP/3 client rejects unsupported 101 informational response"

block testInformationalOnlyResponseRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "103"),
    ("link", "</preload.css>; rel=preload")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected informational-only response to be rejected without final HEADERS"
  )
  echo "PASS: HTTP/3 client rejects informational-only response without final HEADERS"

block testDataBeforeFinalResponseHeadersRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[(":status", "103")])
  payload.add encodeDataFrame(@[0x41'u8])
  payload.add session.conn.encodeHeadersFrame(@[(":status", "200")])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrFrameUnexpected,
    "Expected DATA before final response HEADERS to be rejected"
  )
  echo "PASS: HTTP/3 client rejects DATA before final response HEADERS"

block testDataAfterTrailersRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-type", "text/plain")
  ])
  payload.add session.conn.encodeHeadersFrame(@[
    ("x-trailer", "done")
  ])
  payload.add encodeDataFrame(@[byte('x')])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrFrameUnexpected,
    "Expected DATA after trailing HEADERS to be rejected"
  )
  echo "PASS: HTTP/3 client rejects DATA after trailing HEADERS"

block testUppercaseResponseHeaderNameRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("Content-Type", "text/plain")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected uppercase response header name to be rejected"
  )
  echo "PASS: HTTP/3 client rejects uppercase response header names"

block testConnectionSpecificResponseHeaderRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("connection", "keep-alive")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected connection-specific response header to be rejected"
  )
  echo "PASS: HTTP/3 client rejects connection-specific response headers"

block testTeResponseHeaderRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("te", "trailers")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected TE response header to be rejected"
  )
  echo "PASS: HTTP/3 client rejects TE response header"

block testInvalidResponseHeaderValueRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("x-test", "ok\r\nbad")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected invalid response header value to be rejected"
  )
  echo "PASS: HTTP/3 client rejects invalid response header values"

block testResponseHeaderSectionSizeLimitEnforced:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  session.conn.setLocalSettingValue(H3SettingMaxFieldSectionSize, 64'u64)
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("x-oversized", "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrExcessiveLoad,
    "Expected response headers exceeding SETTINGS_MAX_FIELD_SECTION_SIZE to be rejected"
  )
  echo "PASS: HTTP/3 client enforces response header section size limits"

block testInvalidResponseStreamIdRejected:
  let session = client_http3.newHttp3ClientSession()
  let payload = session.conn.encodeHeadersFrame(@[(":status", "200")])
  expectProtocolError(
    session,
    1'u64, # server-initiated bidirectional stream id
    payload,
    H3ErrStreamCreation,
    "Expected client to reject response on server-initiated bidirectional stream"
  )
  echo "PASS: HTTP/3 client rejects invalid response stream id"

block testMalformedResponseDoesNotCreateTunnelSessionState:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let malformedResponseHeaders = session.conn.encodeHeadersFrame(@[
    (":method", "CONNECT"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/wt"),
    (":protocol", "webtransport")
  ])
  expectProtocolError(
    session,
    streamId,
    malformedResponseHeaders,
    H3ErrMessageError,
    "Expected malformed response pseudo-headers to be rejected"
  )
  doAssert not session.conn.hasWebTransportSession(streamId),
    "Malformed response must not create WebTransport session state"
  doAssert not session.conn.hasMasqueSession(streamId),
    "Malformed response must not create MASQUE session state"
  echo "PASS: HTTP/3 malformed response does not create tunnel session state"

block testTruncatedResponseFrameRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[(":status", "200")])
  let fullDataFrame = encodeDataFrame(@[0x41'u8, 0x42'u8])
  doAssert fullDataFrame.len > 0
  payload.add fullDataFrame[0 ..< fullDataFrame.len - 1]
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrFrameError,
    "Expected truncated response frame payload to be rejected"
  )
  echo "PASS: HTTP/3 client rejects truncated response frame payload"

block testTerminalDecodeErrorClearsStreamState:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = encodeDataFrame(@[0x41'u8]) # DATA before HEADERS
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrFrameUnexpected,
    "Expected malformed response ordering to be rejected"
  )
  doAssert not session.conn.requestStates.hasKey(streamId),
    "Expected terminal decode error to clear request stream state"
  doAssert session.conn.requestStreamBufferedBytes(streamId) == 0,
    "Expected terminal decode error to clear buffered request stream bytes"
  echo "PASS: HTTP/3 client decode errors clear request stream state"

block testConflictingResponseContentLengthRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-length", "5"),
    ("content-length", "7")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected conflicting response content-length values to be rejected"
  )
  echo "PASS: HTTP/3 client rejects conflicting response content-length values"

block testResponseBodyExceedsContentLengthRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-length", "1")
  ])
  payload.add encodeDataFrame(@[byte('o'), byte('k')])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected response body larger than content-length to be rejected"
  )
  echo "PASS: HTTP/3 client rejects response body exceeding content-length"

block testResponseBodyShorterThanContentLengthRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-length", "5")
  ])
  payload.add encodeDataFrame(@[byte('o'), byte('k')])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected response body shorter than content-length to be rejected at end-of-stream"
  )
  echo "PASS: HTTP/3 client rejects response body shorter than content-length"

block testResponseTrailerContentLengthRejected:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-length", "2")
  ])
  payload.add encodeDataFrame(@[byte('o'), byte('k')])
  payload.add session.conn.encodeHeadersFrame(@[
    ("content-length", "2")
  ])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected content-length in response trailers to be rejected"
  )
  echo "PASS: HTTP/3 client rejects content-length in response trailers"

block testHeadResponseAllowsContentLengthWithoutData:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  let payload = session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-length", "2")
  ])
  let resp = session.decodeResponseFrames(streamId, payload, requestMethod = "HEAD")
  doAssert resp.statusCode == 200
  doAssert resp.body.len == 0
  doAssert ("content-length", "2") in resp.headers
  echo "PASS: HTTP/3 client accepts HEAD response content-length without DATA"

block testHeadResponseRejectsDataFrames:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  var payload: seq[byte] = @[]
  payload.add session.conn.encodeHeadersFrame(@[
    (":status", "200"),
    ("content-length", "2")
  ])
  payload.add encodeDataFrame(@[byte('o'), byte('k')])
  expectProtocolError(
    session,
    streamId,
    payload,
    H3ErrMessageError,
    "Expected HEAD response DATA frames to be rejected",
    requestMethod = "HEAD"
  )
  echo "PASS: HTTP/3 client rejects HEAD response DATA frames"

echo "All HTTP/3 client header validation tests passed"
