## HTTP/3 pseudo-header validation tests.

import std/tables
import cps/runtime
import cps/transform
import cps/eventloop
import cps/http/server/types
import cps/http/server/http3 as server_http3
import cps/http/client/http3 as client_http3
import cps/http/shared/http3
import cps/http/shared/http3_connection

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 10_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future"

proc testHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  discard req
  return newResponse(200, "ok")

proc oversizedResponseHeaderHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  discard req
  return newResponse(
    200,
    "ok",
    @[("x-oversized", "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789")]
  )

proc expectRequestRejected(server: server_http3.Http3ServerSession,
                           streamId: uint64,
                           reqFrames: seq[byte],
                           msg: string) =
  var raised = false
  try:
    let fut = server.handleHttp3RequestFrames(streamId, reqFrames)
    runLoopUntilFinished(fut)
    raised = fut.hasError()
  except ValueError:
    raised = true
  doAssert raised, msg

proc expectRequestRejectedWithCode(server: server_http3.Http3ServerSession,
                                   streamId: uint64,
                                   reqFrames: seq[byte],
                                   expectedCode: uint64,
                                   msg: string) =
  var raised = false
  var gotCode = 0'u64
  try:
    let fut = server.handleHttp3RequestFrames(streamId, reqFrames)
    runLoopUntilFinished(fut)
    if fut.hasError():
      raised = true
      let err = fut.getError()
      if not err.isNil and err of server_http3.Http3ProtocolViolation:
        let h3 = cast[server_http3.Http3ProtocolViolation](err)
        gotCode = h3.errorCode
  except server_http3.Http3ProtocolViolation as e:
    raised = true
    gotCode = e.errorCode
  doAssert raised, msg
  doAssert gotCode == expectedCode,
    "Expected HTTP/3 protocol code " & $expectedCode & " but got " & $gotCode

block testValidPseudoHeadersRoundTrip:
  let server = server_http3.newHttp3ServerSession(@[0x01'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()

  let reqFrames = client.encodeRequestFrames("GET", "/health", "example.com", @[], "")
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError(), "Expected valid HTTP/3 request to succeed"

  let respFrames = fut.read()
  let frames = decodeAllHttp3Frames(respFrames)
  doAssert frames.len >= 1
  doAssert frames[0].frameType == H3FrameHeaders
  echo "PASS: HTTP/3 valid pseudo-header request handling"

block testMissingPseudoHeadersRejected:
  let server = server_http3.newHttp3ServerSession(@[0x02'u8], testHandler)
  let badHeaders = @[
    (":method", "GET"),
    (":authority", "example.com"),
    (":path", "/missing-scheme")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejected(server, 4'u64, badReqFrames, "Expected missing :scheme pseudo-header to fail")
  echo "PASS: HTTP/3 pseudo-header validation rejects malformed request"

block testPseudoHeaderOrderingRejected:
  let server = server_http3.newHttp3ServerSession(@[0x03'u8], testHandler)
  let badHeaders = @[
    ("x-regular", "1"),
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/order")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejected(server, 4'u64, badReqFrames, "Expected pseudo-header ordering violation to fail")
  echo "PASS: HTTP/3 pseudo-header ordering validation rejects malformed request"

block testDuplicatePseudoHeadersRejected:
  let server = server_http3.newHttp3ServerSession(@[0x04'u8], testHandler)
  let badHeaders = @[
    (":method", "GET"),
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/dup")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejected(server, 4'u64, badReqFrames, "Expected duplicate pseudo-header to fail")
  echo "PASS: HTTP/3 duplicate pseudo-header validation rejects malformed request"

block testInvalidRequestStreamIdRejected:
  let server = server_http3.newHttp3ServerSession(@[0x05'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/invalid-stream-id", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    1'u64, # server-initiated bidirectional stream id, invalid for requests
    reqFrames,
    H3ErrStreamCreation,
    "Expected invalid request stream id to fail with H3_STREAM_CREATION"
  )
  echo "PASS: HTTP/3 rejects non-request bidirectional stream IDs"

block testRequestStreamIdOverflowRejected:
  let server = server_http3.newHttp3ServerSession(@[0x05'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/overflow-stream-id", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    0x1_0000_0000'u64,
    reqFrames,
    H3ErrStreamCreation,
    "Expected unsupported large HTTP/3 request stream IDs to be rejected"
  )
  echo "PASS: HTTP/3 rejects unsupported request stream ID overflow"

block testProtocolPseudoHeaderRequiresExtendedConnectSetting:
  let server = server_http3.newHttp3ServerSession(@[0x06'u8], testHandler)
  server.conn.localSettings = @[
    (H3SettingQpackMaxTableCapacity, 4096'u64),
    (H3SettingQpackBlockedStreams, 16'u64),
    (H3SettingMaxFieldSectionSize, 1_048_576'u64),
    (H3SettingEnableConnectProtocol, 0'u64)
  ]
  let extendedConnectHeaders = @[
    (":method", "CONNECT"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/wt"),
    (":protocol", "webtransport")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(extendedConnectHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected :protocol request to fail when SETTINGS_ENABLE_CONNECT_PROTOCOL is disabled"
  )
  echo "PASS: HTTP/3 rejects :protocol request when extended CONNECT setting is disabled"

block testPlainConnectWithoutSchemePathAccepted:
  let server = server_http3.newHttp3ServerSession(@[0x07'u8], testHandler)
  let connectHeaders = @[
    (":method", "CONNECT"),
    (":authority", "example.com:443")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(connectHeaders)
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError(), "Expected plain CONNECT without :scheme/:path to be accepted"
  echo "PASS: HTTP/3 accepts plain CONNECT with :authority only"

block testPlainConnectWithSchemePathRejected:
  let server = server_http3.newHttp3ServerSession(@[0x08'u8], testHandler)
  let connectHeaders = @[
    (":method", "CONNECT"),
    (":authority", "example.com:443"),
    (":scheme", "https"),
    (":path", "/")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(connectHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected plain CONNECT carrying :scheme/:path to be rejected"
  )
  echo "PASS: HTTP/3 rejects plain CONNECT with :scheme/:path"

block testForbiddenConnectionSpecificHeaderRejected:
  let server = server_http3.newHttp3ServerSession(@[0x09'u8], testHandler)
  let badHeaders = @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/forbidden"),
    ("connection", "keep-alive")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected HTTP/3 request with connection-specific header to be rejected"
  )
  echo "PASS: HTTP/3 rejects connection-specific request headers"

block testRequestHeaderSectionSizeLimitEnforced:
  let server = server_http3.newHttp3ServerSession(@[0x09'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()
  server.conn.setLocalSettingValue(H3SettingMaxFieldSectionSize, 64'u64)
  let reqFrames = client.encodeRequestFrames(
    "GET",
    "/oversized-headers",
    "example.com",
    @[("x-oversized", "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789")],
    ""
  )
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrExcessiveLoad,
    "Expected oversized request header section to be rejected"
  )
  echo "PASS: HTTP/3 enforces request header section size limits"

block testUppercaseHeaderNameRejected:
  let server = server_http3.newHttp3ServerSession(@[0x0A'u8], testHandler)
  let badHeaders = @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/uppercase"),
    ("Content-Type", "text/plain")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected uppercase HTTP/3 header name to be rejected"
  )
  echo "PASS: HTTP/3 rejects uppercase request header names"

block testHostAuthorityMismatchRejected:
  let server = server_http3.newHttp3ServerSession(@[0x0B'u8], testHandler)
  let badHeaders = @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/host-mismatch"),
    ("host", "evil.example")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected mismatched host/:authority request to be rejected"
  )
  echo "PASS: HTTP/3 rejects host/:authority mismatch"

block testEmptyMethodPseudoHeaderRejected:
  let server = server_http3.newHttp3ServerSession(@[0x0C'u8], testHandler)
  let badHeaders = @[
    (":method", ""),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/empty-method")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected empty :method pseudo-header to be rejected"
  )
  echo "PASS: HTTP/3 rejects empty :method pseudo-header"

block testServerRejectsInvalidRequestContentLengthValue:
  let server = server_http3.newHttp3ServerSession(@[0x0D'u8], testHandler)
  let badHeaders = @[
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/bad-content-length"),
    ("content-length", "12x")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    badReqFrames,
    H3ErrMessageError,
    "Expected server to reject request with invalid content-length value"
  )
  echo "PASS: HTTP/3 server rejects invalid request content-length value"

block testServerRejectsConflictingRequestContentLengthValues:
  let server = server_http3.newHttp3ServerSession(@[0x0E'u8], testHandler)
  let badHeaders = @[
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/conflicting-content-length"),
    ("content-length", "3"),
    ("content-length", "7")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    badReqFrames,
    H3ErrMessageError,
    "Expected server to reject request with conflicting content-length values"
  )
  echo "PASS: HTTP/3 server rejects conflicting request content-length values"

block testServerRejectsRequestBodyLengthMismatchWithContentLength:
  let server = server_http3.newHttp3ServerSession(@[0x0F'u8], testHandler)
  let headers = @[
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/content-length-mismatch"),
    ("content-length", "5")
  ]
  var reqFrames: seq[byte] = @[]
  reqFrames.add server.conn.encodeHeadersFrame(headers)
  reqFrames.add encodeDataFrame(@[0x6F'u8, 0x6B'u8]) # "ok"
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject request body length mismatch with content-length"
  )
  echo "PASS: HTTP/3 server rejects request body/content-length mismatch"

block testServerAcceptsMatchingRequestContentLength:
  let server = server_http3.newHttp3ServerSession(@[0x1B'u8], testHandler)
  let headers = @[
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/content-length-match"),
    ("content-length", "2")
  ]
  var reqFrames: seq[byte] = @[]
  reqFrames.add server.conn.encodeHeadersFrame(headers)
  reqFrames.add encodeDataFrame(@[0x6F'u8, 0x6B'u8]) # "ok"
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError(), "Expected server to accept request with matching content-length"
  echo "PASS: HTTP/3 server accepts request with matching content-length"

block testClientRejectsInvalidRequestContentLengthValue:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "POST",
      "/bad-content-length",
      "example.com",
      @[("content-length", "12x")],
      "ok"
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject invalid content-length value"
  echo "PASS: HTTP/3 client encode rejects invalid request content-length value"

block testClientRejectsConflictingRequestContentLengthValues:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "POST",
      "/conflicting-content-length",
      "example.com",
      @[("content-length", "2"), ("content-length", "7")],
      "ok"
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject conflicting content-length values"
  echo "PASS: HTTP/3 client encode rejects conflicting request content-length values"

block testClientRejectsRequestBodyLengthMismatchWithContentLength:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "POST",
      "/content-length-mismatch",
      "example.com",
      @[("content-length", "5")],
      "ok"
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject request body/content-length mismatch"
  echo "PASS: HTTP/3 client encode rejects request body/content-length mismatch"

block testClientAcceptsMatchingRequestContentLength:
  let client = client_http3.newHttp3ClientSession()
  var reqFrames: seq[byte] = @[]
  var encodeError = ""
  try:
    reqFrames = client.encodeRequestFrames(
      "POST",
      "/content-length-match",
      "example.com",
      @[("content-length", "2")],
      "ok"
    )
  except ValueError as e:
    encodeError = e.msg
  doAssert encodeError.len == 0, "Expected client request encode to accept matching content-length: " & encodeError
  doAssert reqFrames.len > 0, "Expected client request encode to return encoded frames"
  echo "PASS: HTTP/3 client encode accepts matching request content-length"

block testClientRejectsForbiddenConnectionSpecificRequestHeader:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/forbidden",
      "example.com",
      @[("connection", "keep-alive")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject connection-specific headers"
  echo "PASS: HTTP/3 client encode rejects connection-specific request headers"

block testClientRejectsInvalidRequestTeHeader:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/bad-te",
      "example.com",
      @[("te", "gzip")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject invalid TE header"
  echo "PASS: HTTP/3 client encode rejects non-trailers TE request header"

block testClientRejectsPseudoHeaderOverrides:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/override",
      "example.com",
      @[(":path", "/evil")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject pseudo-header overrides"
  echo "PASS: HTTP/3 client encode rejects pseudo-header overrides"

block testClientRejectsRequestHeadersExceedingPeerFieldSectionLimit:
  let client = client_http3.newHttp3ClientSession()
  client.conn.peerSettingsReceived = true
  client.conn.peerSettings[H3SettingMaxFieldSectionSize] = 64'u64
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/too-large",
      "example.com",
      @[("x-oversized", "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject headers over peer field-section limit"
  echo "PASS: HTTP/3 client encode enforces peer field-section size limit"

block testClientRejectsInvalidRequestHeaderValue:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/bad-value",
      "example.com",
      @[("x-test", "ok\r\nbad")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject invalid header values"
  echo "PASS: HTTP/3 client encode rejects invalid request header values"

block testClientRejectsMismatchedHostHeader:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/host-mismatch",
      "example.com",
      @[("host", "other.example")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject host header mismatching :authority"
  echo "PASS: HTTP/3 client encode rejects mismatched host header"

block testClientRejectsDuplicateHostHeaders:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GET",
      "/host-duplicate",
      "example.com",
      @[("host", "example.com"), ("host", "example.com")],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject duplicate host headers"
  echo "PASS: HTTP/3 client encode rejects duplicate host headers"

block testClientRejectsConnectWithPathWithoutProtocol:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "CONNECT",
      "/extended-connect-without-protocol",
      "example.com",
      @[],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected,
    "Expected client request encode to reject CONNECT requests that carry :path without :protocol"
  echo "PASS: HTTP/3 client encode rejects CONNECT with :path but no :protocol"

block testClientRejectsInvalidMethodToken:
  let client = client_http3.newHttp3ClientSession()
  var rejected = false
  try:
    discard client.encodeRequestFrames(
      "GE T",
      "/bad-method",
      "example.com",
      @[],
      ""
    )
  except ValueError:
    rejected = true
  doAssert rejected, "Expected client request encode to reject invalid :method token"
  echo "PASS: HTTP/3 client encode rejects invalid :method token"

block testServerRejectsInvalidMethodToken:
  let server = server_http3.newHttp3ServerSession(@[0x13'u8], testHandler)
  let badHeaders = @[
    (":method", "GE T"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/bad-method")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    badReqFrames,
    H3ErrMessageError,
    "Expected server to reject invalid :method token"
  )
  echo "PASS: HTTP/3 server rejects invalid :method token"

block testServerRejectsInvalidSchemeValue:
  let server = server_http3.newHttp3ServerSession(@[0x14'u8], testHandler)
  let badHeaders = @[
    (":method", "GET"),
    (":scheme", "http s"),
    (":authority", "example.com"),
    (":path", "/bad-scheme")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    badReqFrames,
    H3ErrMessageError,
    "Expected server to reject invalid :scheme pseudo-header value"
  )
  echo "PASS: HTTP/3 server rejects invalid :scheme value"

block testServerRejectsInvalidProtocolToken:
  let server = server_http3.newHttp3ServerSession(@[0x15'u8], testHandler)
  let badHeaders = @[
    (":method", "CONNECT"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/bad-protocol"),
    (":protocol", "bad protocol")
  ]
  let badReqFrames = server.conn.encodeHeadersFrame(badHeaders)
  expectRequestRejectedWithCode(
    server,
    4'u64,
    badReqFrames,
    H3ErrMessageError,
    "Expected server to reject invalid :protocol pseudo-header token"
  )
  echo "PASS: HTTP/3 server rejects invalid :protocol token"

block testServerAcceptsCaseInsensitiveHostAuthorityMatch:
  let server = server_http3.newHttp3ServerSession(@[0x11'u8], testHandler)
  let reqHeaders = @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/host-case"),
    ("host", "EXAMPLE.COM")
  ]
  let reqFrames = server.conn.encodeHeadersFrame(reqHeaders)
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError(),
    "Expected server to treat host and :authority as equivalent ignoring host case"
  echo "PASS: HTTP/3 server accepts case-insensitive host/:authority match"

block testClientEncodesPlainConnectWithoutSchemePath:
  let server = server_http3.newHttp3ServerSession(@[0x10'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()
  var reqFrames: seq[byte] = @[]
  var encodeError = ""
  try:
    reqFrames = client.encodeRequestFrames(
      "CONNECT",
      "",
      "example.com:443",
      @[],
      ""
    )
  except ValueError as e:
    encodeError = e.msg
  doAssert encodeError.len == 0,
    "Expected client to encode plain CONNECT without :scheme/:path, got: " & encodeError
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError(), "Expected plain CONNECT encoded by client to be accepted"
  echo "PASS: HTTP/3 client can encode plain CONNECT without :scheme/:path"

block testServerPushPromiseApiRejectsInvalidRequestStreamId:
  let server = server_http3.newHttp3ServerSession(@[0x17'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()
  server.conn.hasPeerMaxPushId = true
  server.conn.maxPushIdReceived = 8'u64

  let reqFrames = client.encodeRequestFrames("GET", "/push", "example.com", @[], "")
  let reqFut = server.handleHttp3RequestFrames(4'u64, reqFrames, streamEnded = false)
  runLoopUntilFinished(reqFut)
  doAssert not reqFut.hasError(), "Expected request preface to establish active request stream context"

  var raised = false
  var gotCode = 0'u64
  try:
    discard server.createPushPromise(
      5'u64,
      1'u64,
      @[
        (":method", "GET"),
        (":scheme", "https"),
        (":authority", "example.com"),
        (":path", "/asset.js")
      ]
    )
  except server_http3.Http3ProtocolViolation as e:
    raised = true
    gotCode = e.errorCode
  doAssert raised, "Expected PUSH_PROMISE API to reject invalid request stream IDs"
  doAssert gotCode == H3ErrStreamCreation
  echo "PASS: HTTP/3 server PUSH_PROMISE API rejects invalid request stream IDs"

block testServerPushPromiseApiRejectsMissingRequestContext:
  let server = server_http3.newHttp3ServerSession(@[0x18'u8], testHandler)
  server.conn.hasPeerMaxPushId = true
  server.conn.maxPushIdReceived = 8'u64

  var raised = false
  var gotCode = 0'u64
  try:
    discard server.createPushPromise(
      4'u64,
      1'u64,
      @[
        (":method", "GET"),
        (":scheme", "https"),
        (":authority", "example.com"),
        (":path", "/asset.js")
      ]
    )
  except server_http3.Http3ProtocolViolation as e:
    raised = true
    gotCode = e.errorCode
  doAssert raised, "Expected PUSH_PROMISE API to require active request stream context"
  doAssert gotCode == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 server PUSH_PROMISE API requires active request stream context"

block testServerPushPromiseApiRejectsBeforeRequestHeaders:
  let server = server_http3.newHttp3ServerSession(@[0x1A'u8], testHandler)
  server.conn.hasPeerMaxPushId = true
  server.conn.maxPushIdReceived = 8'u64

  let reqFut = server.handleHttp3RequestFrames(4'u64, @[], streamEnded = false)
  runLoopUntilFinished(reqFut)
  doAssert not reqFut.hasError(), "Expected stream context creation before HEADERS"

  var raised = false
  var gotCode = 0'u64
  try:
    discard server.createPushPromise(
      4'u64,
      1'u64,
      @[
        (":method", "GET"),
        (":scheme", "https"),
        (":authority", "example.com"),
        (":path", "/asset.js")
      ]
    )
  except server_http3.Http3ProtocolViolation as e:
    raised = true
    gotCode = e.errorCode
  doAssert raised, "Expected PUSH_PROMISE API to reject request streams without HEADERS"
  doAssert gotCode == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 server PUSH_PROMISE API rejects streams without request HEADERS"

block testServerPushPromiseApiAcceptsActiveRequestStream:
  let server = server_http3.newHttp3ServerSession(@[0x19'u8], testHandler)
  let client = client_http3.newHttp3ClientSession()
  server.conn.hasPeerMaxPushId = true
  server.conn.maxPushIdReceived = 8'u64

  let reqFrames = client.encodeRequestFrames("GET", "/push-ok", "example.com", @[], "")
  let reqFut = server.handleHttp3RequestFrames(4'u64, reqFrames, streamEnded = false)
  runLoopUntilFinished(reqFut)
  doAssert not reqFut.hasError(), "Expected request stream context creation before PUSH_PROMISE"

  let pushPromise = server.createPushPromise(
    4'u64,
    2'u64,
    @[
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "example.com"),
      (":path", "/asset-ok.js")
    ]
  )
  doAssert pushPromise.len > 0
  let frames = decodeAllHttp3Frames(pushPromise)
  doAssert frames.len == 1
  doAssert frames[0].frameType == H3FramePushPromise
  echo "PASS: HTTP/3 server PUSH_PROMISE API accepts active request stream context"

block testServerRejectsConnectionSpecificResponseHeader:
  proc badHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "ok", @[("connection", "keep-alive")])

  let server = server_http3.newHttp3ServerSession(@[0x10'u8], badHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/bad-response-header", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject connection-specific response header during HTTP/3 response encoding"
  )
  echo "PASS: HTTP/3 server rejects connection-specific response headers"

block testServerRejectsInvalidResponseContentLengthValue:
  proc badContentLengthHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "ok", @[("content-length", "12x")])

  let server = server_http3.newHttp3ServerSession(@[0x1C'u8], badContentLengthHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/bad-response-content-length", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject invalid response content-length value"
  )
  echo "PASS: HTTP/3 server rejects invalid response content-length value"

block testServerRejectsConflictingResponseContentLengthValues:
  proc conflictingContentLengthHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "ok", @[("content-length", "2"), ("content-length", "7")])

  let server = server_http3.newHttp3ServerSession(@[0x1D'u8], conflictingContentLengthHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/conflicting-response-content-length", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject conflicting response content-length values"
  )
  echo "PASS: HTTP/3 server rejects conflicting response content-length values"

block testServerRejectsResponseBodyLengthMismatchWithContentLength:
  proc mismatchedContentLengthHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "ok", @[("content-length", "5")])

  let server = server_http3.newHttp3ServerSession(@[0x1E'u8], mismatchedContentLengthHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/response-content-length-mismatch", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject response body/content-length mismatch"
  )
  echo "PASS: HTTP/3 server rejects response body/content-length mismatch"

block testServerAcceptsMatchingResponseContentLength:
  proc matchingContentLengthHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "ok", @[("content-length", "2")])

  let server = server_http3.newHttp3ServerSession(@[0x1F'u8], matchingContentLengthHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/response-content-length-match", "example.com", @[], "")
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError(), "Expected server to accept response with matching content-length"
  let resp = client.decodeResponseFrames(0'u64, fut.read())
  doAssert resp.statusCode == 200
  doAssert resp.body == "ok"
  echo "PASS: HTTP/3 server accepts response with matching content-length"

block testServerRejectsOutOfRangeResponseStatus:
  proc badStatusHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(42, "bad", @[("content-type", "text/plain")])

  let server = server_http3.newHttp3ServerSession(@[0x11'u8], badStatusHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/bad-status", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject out-of-range HTTP/3 response status code"
  )
  echo "PASS: HTTP/3 server rejects out-of-range response status code"

block testServerRejectsInformationalOnlyResponseStatus:
  proc infoStatusHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(103, "early-hints", @[("link", "</a.css>; rel=preload")])

  let server = server_http3.newHttp3ServerSession(@[0x12'u8], infoStatusHandler)
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/info-status", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrMessageError,
    "Expected server to reject informational-only status from single-response handler"
  )
  echo "PASS: HTTP/3 server rejects informational-only response status"

block testServerRejectsResponseHeadersExceedingPeerFieldSectionLimit:
  let server = server_http3.newHttp3ServerSession(@[0x16'u8], oversizedResponseHeaderHandler)
  server.conn.peerSettingsReceived = true
  server.conn.peerSettings[H3SettingMaxFieldSectionSize] = 64'u64
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("GET", "/oversized-response", "example.com", @[], "")
  expectRequestRejectedWithCode(
    server,
    4'u64,
    reqFrames,
    H3ErrExcessiveLoad,
    "Expected server to reject response header section exceeding peer limit"
  )
  echo "PASS: HTTP/3 server enforces peer field-section size limit for responses"

block testServerRejectsEmptyRequestStreamAtFin:
  let server = server_http3.newHttp3ServerSession(@[0x13'u8], testHandler)
  var raised = false
  var gotCode = 0'u64
  try:
    let fut = server.handleHttp3RequestFrames(4'u64, @[], streamEnded = true)
    runLoopUntilFinished(fut)
    if fut.hasError():
      raised = true
      let err = fut.getError()
      if not err.isNil and err of server_http3.Http3ProtocolViolation:
        let h3 = cast[server_http3.Http3ProtocolViolation](err)
        gotCode = h3.errorCode
  except server_http3.Http3ProtocolViolation as e:
    raised = true
    gotCode = e.errorCode
  doAssert raised, "Expected empty HTTP/3 request stream to be rejected"
  doAssert gotCode == H3ErrMessageError, "Expected H3_MESSAGE_ERROR for empty HTTP/3 request stream"
  echo "PASS: HTTP/3 server rejects empty request stream at FIN"

echo "All HTTP/3 header validation tests passed"
