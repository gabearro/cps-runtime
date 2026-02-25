## HTTP/3 server adapter.

import std/[strutils, tables]
import ../../runtime
import ../../transform
import ../shared/http3
import ../shared/qpack
import ../shared/http3_connection
import ../shared/masque
import ./types

type
  Http3ProtocolViolation* = object of ValueError
    errorCode*: uint64

  PendingRequestState = object
    headers: seq[QpackHeaderField]
    body: string
    sawHeaders: bool
    responseDispatched: bool
    masqueTunnel: bool
    webTransportTunnel: bool

  Http3ServerSession* = ref object
    connId*: seq[byte]
    conn*: Http3Connection
    handler*: HttpHandler
    maxRequestBodySize*: int
    pendingRequests: Table[uint64, PendingRequestState]
    qpackBlockedRequestStreams: Table[uint64, bool]
    rejectedRequestStreams: Table[uint64, bool]

const RequestBufferGraceBytes = 64 * 1024

proc raiseProtocolViolation(code: uint64, msg: string) {.noreturn.} =
  var err = newException(Http3ProtocolViolation, msg)
  err.errorCode = if code != 0'u64: code else: H3ErrGeneralProtocol
  raise err

proc newHttp3ServerSession*(connId: seq[byte],
                            handler: HttpHandler,
                            maxRequestBodySize: int = 10 * 1024 * 1024,
                            enableDatagram: bool = true): Http3ServerSession =
  let conn = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  if not enableDatagram:
    conn.setLocalSettingValue(H3SettingH3Datagram, 0'u64)
  Http3ServerSession(
    connId: connId,
    conn: conn,
    handler: handler,
    maxRequestBodySize: maxRequestBodySize,
    pendingRequests: initTable[uint64, PendingRequestState](),
    qpackBlockedRequestStreams: initTable[uint64, bool](),
    rejectedRequestStreams: initTable[uint64, bool]()
  )

proc statusPseudoHeader(statusCode: int): QpackHeaderField =
  (":status", $statusCode)

proc validatePseudoHeaders(headers: seq[QpackHeaderField]) =
  proc parseContentLengthValue(value: string): uint64 =
    if value.len == 0:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    for ch in value:
      if ch notin Digits:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    let parsed =
      try:
        parseInt(value)
      except ValueError:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    if parsed < 0:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    uint64(parsed)

  var hasMethod = false
  var hasScheme = false
  var hasAuthority = false
  var hasPath = false
  var hasProtocol = false
  var methodValue = ""
  var schemeValue = ""
  var authorityValue = ""
  var pathValue = ""
  var protocolValue = ""
  var sawHostHeader = false
  var hostValue = ""
  var sawContentLength = false
  var contentLengthValue = 0'u64
  var seenRegularHeader = false
  for (k, v) in headers:
    if k.len == 0:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request contains empty header name")
    if k.startsWith(":"):
      if seenRegularHeader:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 pseudo-headers must appear before regular headers")
      case k
      of ":method":
        if hasMethod:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has duplicate :method pseudo-header")
        hasMethod = true
        methodValue = v
      of ":scheme":
        if hasScheme:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has duplicate :scheme pseudo-header")
        hasScheme = true
        schemeValue = v
      of ":authority":
        if hasAuthority:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has duplicate :authority pseudo-header")
        hasAuthority = true
        authorityValue = v
      of ":path":
        if hasPath:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has duplicate :path pseudo-header")
        hasPath = true
        pathValue = v
      of ":protocol":
        if hasProtocol:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has duplicate :protocol pseudo-header")
        hasProtocol = true
        protocolValue = v
      else:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request contains unsupported pseudo-header: " & k)
    else:
      seenRegularHeader = true
      if k != k.toLowerAscii:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request header names must be lowercase")
      if not isValidHeaderName(k) or not isValidHeaderValue(v):
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request contains invalid header field")
      case k
      of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding":
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request contains forbidden connection-specific header: " & k)
      of "te":
        if v.toLowerAscii != "trailers":
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request TE header must be \"trailers\"")
      of "host":
        if sawHostHeader:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has duplicate host header field")
        sawHostHeader = true
        hostValue = v
      of "content-length":
        let parsed = parseContentLengthValue(v)
        if sawContentLength and parsed != contentLengthValue:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has conflicting content-length values")
        sawContentLength = true
        contentLengthValue = parsed
      else:
        discard
  if methodValue.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has empty :method pseudo-header")
  if not isValidHeaderName(methodValue):
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid :method pseudo-header token")
  if hasScheme and schemeValue.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has empty :scheme pseudo-header")
  if hasScheme:
    if schemeValue[0] notin Letters:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid :scheme pseudo-header")
    for i in 1 ..< schemeValue.len:
      let c = schemeValue[i]
      if c notin (Letters + Digits + {'+', '-', '.'}):
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid :scheme pseudo-header")
  if hasAuthority and authorityValue.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has empty :authority pseudo-header")
  if hasPath and pathValue.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has empty :path pseudo-header")
  if hasProtocol and protocolValue.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has empty :protocol pseudo-header")
  if hasProtocol and not isValidHeaderName(protocolValue):
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid :protocol pseudo-header token")
  if hasAuthority and sawHostHeader and authorityValue.toLowerAscii != hostValue.toLowerAscii:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request host header must match :authority pseudo-header")
  if not hasMethod:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request missing required :method pseudo-header")
  if methodValue == "CONNECT":
    if hasProtocol:
      if not (hasScheme and hasAuthority and hasPath):
        raiseProtocolViolation(
          H3ErrMessageError,
          "HTTP/3 extended CONNECT request missing required pseudo headers"
        )
    else:
      if not hasAuthority:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 CONNECT request missing required :authority pseudo-header")
      if hasScheme or hasPath:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 CONNECT request must omit :scheme and :path")
  else:
    if hasProtocol:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request uses :protocol without CONNECT method")
    if not (hasScheme and hasAuthority and hasPath):
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request missing required pseudo headers")

proc appendBytesToString(dst: var string, data: openArray[byte]) =
  if data.len == 0:
    return
  let start = dst.len
  dst.setLen(start + data.len)
  for i in 0 ..< data.len:
    dst[start + i] = char(data[i])

proc fieldSectionSize(headers: openArray[QpackHeaderField]): uint64 =
  for (name, value) in headers:
    let entry = uint64(name.len + value.len + 32)
    if high(uint64) - result < entry:
      return high(uint64)
    result += entry

proc hasProtocolPseudoHeader(headers: openArray[QpackHeaderField]): bool =
  for (k, _) in headers:
    if k == ":protocol":
      return true
  false

proc localExtendedConnectEnabled(session: Http3ServerSession): bool =
  if session.isNil or session.conn.isNil:
    return false
  session.conn.localSettingValue(H3SettingEnableConnectProtocol, 0'u64) == 1'u64

proc validateResponseStatusCode(statusCode: int) =
  # This single-response API emits one final HEADERS block. Informational
  # responses (1xx) are interim by definition and require a subsequent final
  # response, so they are rejected here.
  if statusCode < 200 or statusCode > 999:
    raiseProtocolViolation(
      H3ErrMessageError,
      "HTTP/3 response status code must be in range 200..999"
    )

proc validateResponseHeader(name: string, value: string) =
  if name.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response contains empty header name")
  let lower = name.toLowerAscii
  if name != lower:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response header names must be lowercase")
  if not isValidHeaderName(name) or not isValidHeaderValue(value):
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response contains invalid header field")
  case name
  of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te":
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response contains forbidden connection-specific header: " & name)
  else:
    discard

proc parseResponseContentLengthValue(value: string): uint64 =
  if value.len == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response has invalid content-length value")
  for ch in value:
    if ch notin Digits:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response has invalid content-length value")
  let parsed =
    try:
      parseInt(value)
    except ValueError:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response has invalid content-length value")
  if parsed < 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response has invalid content-length value")
  uint64(parsed)

proc validateResponseContentLength(headers: openArray[QpackHeaderField], bodyLen: int) =
  var hasContentLength = false
  var declaredContentLength = 0'u64
  for (k, v) in headers:
    if k != "content-length":
      continue
    let parsed = parseResponseContentLengthValue(v)
    if hasContentLength and parsed != declaredContentLength:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response has conflicting content-length values")
    hasContentLength = true
    declaredContentLength = parsed
  if hasContentLength and uint64(max(0, bodyLen)) != declaredContentLength:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 response body length does not match content-length")

proc buildRequest(streamId: uint64, headers: seq[QpackHeaderField], body: string): HttpRequest =
  proc parseContentLengthValue(value: string): uint64 =
    if value.len == 0:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    for ch in value:
      if ch notin Digits:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    let parsed =
      try:
        parseInt(value)
      except ValueError:
        raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    if parsed < 0:
      raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has invalid content-length value")
    uint64(parsed)

  validatePseudoHeaders(headers)
  var reqHeaders: seq[(string, string)] = @[]
  var meth = ""
  var path = ""
  var authority = ""
  var scheme = ""
  var sawContentLength = false
  var declaredContentLength = 0'u64
  for (k, v) in headers:
    case k
    of ":method": meth = v
    of ":path": path = v
    of ":authority": authority = v
    of ":scheme": scheme = v
    else:
      if k == "content-length":
        let parsed = parseContentLengthValue(v)
        if sawContentLength and parsed != declaredContentLength:
          raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has conflicting content-length values")
        sawContentLength = true
        declaredContentLength = parsed
      reqHeaders.add (k, v)
  if sawContentLength and uint64(max(0, body.len)) != declaredContentLength:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request body length does not match content-length")
  HttpRequest(
    meth: meth,
    path: path,
    httpVersion: "HTTP/3",
    headers: reqHeaders,
    body: body,
    remoteAddr: "",
    streamId: uint32(streamId and 0xFFFF_FFFF'u64),
    authority: authority,
    scheme: scheme,
    stream: nil,
    reader: nil,
    templateRenderer: nil,
    context: nil,
    appState: nil
  )

proc buildResponseFrames(session: Http3ServerSession, resp: HttpResponseBuilder): seq[byte] =
  validateResponseStatusCode(resp.statusCode)
  var headers: seq[QpackHeaderField] = @[statusPseudoHeader(resp.statusCode)]
  for (k, v) in resp.headers:
    validateResponseHeader(k, v)
    headers.add (k, v)
  validateResponseContentLength(headers, resp.body.len)
  let peerFieldSectionLimit = session.conn.peerSettingValue(H3SettingMaxFieldSectionSize, high(uint64))
  if fieldSectionSize(headers) > peerFieldSectionLimit:
    raiseProtocolViolation(
      H3ErrExcessiveLoad,
      "HTTP/3 response headers exceed peer SETTINGS_MAX_FIELD_SECTION_SIZE"
    )
  result = @[]
  result.add session.conn.encodeHeadersFrame(headers)
  if resp.body.len > 0:
    result.add encodeDataFrame(resp.body.toOpenArrayByte(0, resp.body.high))

proc handleHttp3RequestFrames*(session: Http3ServerSession,
                               streamId: uint64,
                               framePayload: seq[byte],
                               streamEnded: bool = true): CpsFuture[seq[byte]] {.cps.} =
  ## Parse HTTP/3 request frames, call existing HttpHandler, and return encoded response frames.
  # HTTP/3 request streams are client-initiated bidirectional streams only.
  if (streamId and 0x03'u64) != 0'u64:
    raiseProtocolViolation(
      H3ErrStreamCreation,
      "invalid HTTP/3 request stream id: " & $streamId
    )
  if streamId > uint64(high(uint32)):
    raiseProtocolViolation(
      H3ErrStreamCreation,
      "HTTP/3 request stream id exceeds supported range: " & $streamId
    )
  if streamId in session.rejectedRequestStreams:
    if streamEnded:
      session.rejectedRequestStreams.del(streamId)
      if streamId in session.qpackBlockedRequestStreams:
        session.qpackBlockedRequestStreams.del(streamId)
      session.conn.clearRequestStreamState(streamId)
      session.conn.clearMasqueSessionState(streamId)
      session.conn.clearWebTransportSessionState(streamId)
      if streamId in session.pendingRequests:
        session.pendingRequests.del(streamId)
    return @[]
  if streamEnded and framePayload.len == 0 and streamId notin session.pendingRequests and
      session.conn.requestStreamBufferedBytes(streamId) == 0:
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has no HEADERS frame")

  if session.maxRequestBodySize > 0:
    let buffered = session.conn.requestStreamBufferedBytes(streamId)
    let maxBuffered = session.maxRequestBodySize + RequestBufferGraceBytes
    if buffered + framePayload.len > maxBuffered:
      if streamId in session.pendingRequests:
        session.pendingRequests.del(streamId)
      if streamId in session.qpackBlockedRequestStreams:
        session.qpackBlockedRequestStreams.del(streamId)
      session.conn.clearRequestStreamState(streamId)
      session.conn.clearMasqueSessionState(streamId)
      session.conn.clearWebTransportSessionState(streamId)
      session.rejectedRequestStreams[streamId] = true
      return session.buildResponseFrames(
        newResponse(
          413,
          "payload too large",
          @[("content-type", "text/plain")]
        )
      )

  var pending =
    if streamId in session.pendingRequests:
      session.pendingRequests[streamId]
    else:
      PendingRequestState(
        headers: @[],
        body: "",
        sawHeaders: false,
        responseDispatched: false,
        masqueTunnel: false,
        webTransportTunnel: false
      )
  var events = session.conn.processRequestStreamData(streamId, framePayload)
  if streamEnded:
    let finEvents = session.conn.finalizeRequestStream(streamId)
    if finEvents.len > 0:
      events.add finEvents
  var qpackBlocked = false
  var i = 0
  while i < events.len:
    let kind = events[i].kind
    if kind == h3evHeaders:
      if not pending.sawHeaders:
        pending.headers = events[i].headers
        pending.sawHeaders = true
        if hasProtocolPseudoHeader(pending.headers) and not localExtendedConnectEnabled(session):
          if streamId in session.pendingRequests:
            session.pendingRequests.del(streamId)
          if streamId in session.qpackBlockedRequestStreams:
            session.qpackBlockedRequestStreams.del(streamId)
          session.conn.clearRequestStreamState(streamId)
          session.conn.clearMasqueSessionState(streamId)
          session.conn.clearWebTransportSessionState(streamId)
          raiseProtocolViolation(
            H3ErrMessageError,
            "HTTP/3 request uses :protocol but SETTINGS_ENABLE_CONNECT_PROTOCOL is disabled"
          )
        pending.masqueTunnel = session.conn.hasMasqueSession(streamId)
        pending.webTransportTunnel = session.conn.hasWebTransportSession(streamId)
    elif kind == h3evData:
      let dataLen = events[i].data.len
      if dataLen > 0:
        if pending.masqueTunnel:
          try:
            discard session.conn.ingestMasqueCapsuleData(streamId, events[i].data)
          except ValueError:
            if streamId in session.pendingRequests:
              session.pendingRequests.del(streamId)
            if streamId in session.qpackBlockedRequestStreams:
              session.qpackBlockedRequestStreams.del(streamId)
            session.conn.clearRequestStreamState(streamId)
            session.conn.clearMasqueSessionState(streamId)
            session.conn.clearWebTransportSessionState(streamId)
            raiseProtocolViolation(
              H3ErrMessageError,
              "HTTP/3 MASQUE capsule decode failure: " &
                (if getCurrentExceptionMsg().len > 0:
                   getCurrentExceptionMsg()
                 else:
                   "malformed capsule")
            )
        elif pending.webTransportTunnel:
          if dataLen > 0:
            if streamId in session.pendingRequests:
              session.pendingRequests.del(streamId)
            if streamId in session.qpackBlockedRequestStreams:
              session.qpackBlockedRequestStreams.del(streamId)
            session.conn.clearRequestStreamState(streamId)
            session.conn.clearMasqueSessionState(streamId)
            session.conn.clearWebTransportSessionState(streamId)
            raiseProtocolViolation(H3ErrFrameUnexpected, "HTTP/3 WebTransport CONNECT stream must not carry DATA frames")
        else:
          let newLen = pending.body.len + dataLen
          if session.maxRequestBodySize > 0 and newLen > session.maxRequestBodySize:
            session.pendingRequests.del(streamId)
            if streamId in session.qpackBlockedRequestStreams:
              session.qpackBlockedRequestStreams.del(streamId)
            session.conn.clearRequestStreamState(streamId)
            session.conn.clearMasqueSessionState(streamId)
            session.conn.clearWebTransportSessionState(streamId)
            session.rejectedRequestStreams[streamId] = true
            return session.buildResponseFrames(
              newResponse(
                413,
                "payload too large",
                @[("content-type", "text/plain")]
              )
            )
          appendBytesToString(pending.body, events[i].data)
    elif kind == h3evProtocolError:
      if streamId in session.pendingRequests:
        session.pendingRequests.del(streamId)
      if streamId in session.qpackBlockedRequestStreams:
        session.qpackBlockedRequestStreams.del(streamId)
      session.conn.clearRequestStreamState(streamId)
      session.conn.clearMasqueSessionState(streamId)
      session.conn.clearWebTransportSessionState(streamId)
      raiseProtocolViolation(
        if events[i].errorCode != 0'u64: events[i].errorCode else: H3ErrGeneralProtocol,
        "HTTP/3 protocol error on request stream: " & events[i].errorMessage
      )
    else:
      if events[i].errorMessage == "qpack_blocked":
        qpackBlocked = true
    inc i

  if qpackBlocked:
    session.qpackBlockedRequestStreams[streamId] = true
  elif pending.sawHeaders and streamId in session.qpackBlockedRequestStreams:
    session.qpackBlockedRequestStreams.del(streamId)

  var shouldDispatch = false
  if pending.sawHeaders and not pending.responseDispatched:
    shouldDispatch = pending.masqueTunnel or pending.webTransportTunnel or streamEnded

  if shouldDispatch:
    let req =
      try:
        buildRequest(streamId, pending.headers, pending.body)
      except Http3ProtocolViolation:
        if streamId in session.pendingRequests:
          session.pendingRequests.del(streamId)
        if streamId in session.qpackBlockedRequestStreams:
          session.qpackBlockedRequestStreams.del(streamId)
        session.conn.clearRequestStreamState(streamId)
        session.conn.clearMasqueSessionState(streamId)
        session.conn.clearWebTransportSessionState(streamId)
        raise
      except CatchableError:
        if streamId in session.pendingRequests:
          session.pendingRequests.del(streamId)
        if streamId in session.qpackBlockedRequestStreams:
          session.qpackBlockedRequestStreams.del(streamId)
        session.conn.clearRequestStreamState(streamId)
        session.conn.clearMasqueSessionState(streamId)
        session.conn.clearWebTransportSessionState(streamId)
        raiseProtocolViolation(
          H3ErrMessageError,
          "HTTP/3 request build failure: " &
            (if getCurrentExceptionMsg().len > 0:
               getCurrentExceptionMsg()
             else:
               "failed to build HTTP/3 request")
        )

    let resp =
      try:
        await session.handler(req)
      except CatchableError:
        if streamId in session.pendingRequests:
          session.pendingRequests.del(streamId)
        if streamId in session.qpackBlockedRequestStreams:
          session.qpackBlockedRequestStreams.del(streamId)
        session.conn.clearRequestStreamState(streamId)
        session.conn.clearMasqueSessionState(streamId)
        session.conn.clearWebTransportSessionState(streamId)
        raise newException(
          ValueError,
          "HTTP/3 handler failure: " &
            (if getCurrentExceptionMsg().len > 0:
               getCurrentExceptionMsg()
             else:
               "HTTP/3 handler failure")
        )
    let encoded =
      try:
        session.buildResponseFrames(resp)
      except Http3ProtocolViolation:
        raise
      except CatchableError:
        raise newException(
          ValueError,
          "HTTP/3 response encode failure: " &
            (if getCurrentExceptionMsg().len > 0:
               getCurrentExceptionMsg()
             else:
               "failed to encode response frames")
        )
    pending.responseDispatched = true
    if (pending.masqueTunnel or pending.webTransportTunnel) and not streamEnded:
      session.pendingRequests[streamId] = pending
      if streamId in session.qpackBlockedRequestStreams:
        session.qpackBlockedRequestStreams.del(streamId)
      return encoded
    if streamId in session.pendingRequests:
      session.pendingRequests.del(streamId)
    if streamId in session.qpackBlockedRequestStreams:
      session.qpackBlockedRequestStreams.del(streamId)
    session.conn.clearRequestStreamState(streamId)
    session.conn.clearMasqueSessionState(streamId)
    session.conn.clearWebTransportSessionState(streamId)
    return encoded

  session.pendingRequests[streamId] = pending
  if not streamEnded:
    return @[]
  if (pending.masqueTunnel or pending.webTransportTunnel) and pending.responseDispatched:
    session.pendingRequests.del(streamId)
    if streamId in session.qpackBlockedRequestStreams:
      session.qpackBlockedRequestStreams.del(streamId)
    session.conn.clearRequestStreamState(streamId)
    session.conn.clearMasqueSessionState(streamId)
    session.conn.clearWebTransportSessionState(streamId)
    return @[]
  if not pending.sawHeaders:
    if qpackBlocked:
      # Request stream already ended but HEADERS decode is blocked on QPACK
      # dynamic table state from peer unidirectional streams.
      return @[]
    session.pendingRequests.del(streamId)
    if streamId in session.qpackBlockedRequestStreams:
      session.qpackBlockedRequestStreams.del(streamId)
    session.conn.clearRequestStreamState(streamId)
    session.conn.clearMasqueSessionState(streamId)
    session.conn.clearWebTransportSessionState(streamId)
    raiseProtocolViolation(H3ErrMessageError, "HTTP/3 request has no HEADERS frame")
  return @[]

proc createPushPromise*(session: Http3ServerSession,
                        streamId: uint64,
                        pushId: uint64,
                        headers: seq[QpackHeaderField]): seq[byte] =
  ## Build PUSH_PROMISE for a request stream.
  if (streamId and 0x03'u64) != 0'u64:
    raiseProtocolViolation(
      H3ErrStreamCreation,
      "invalid HTTP/3 request stream id for PUSH_PROMISE: " & $streamId
    )
  if streamId > uint64(high(uint32)):
    raiseProtocolViolation(
      H3ErrStreamCreation,
      "HTTP/3 PUSH_PROMISE stream id exceeds supported range: " & $streamId
    )
  if streamId in session.rejectedRequestStreams:
    raiseProtocolViolation(
      H3ErrRequestRejected,
      "HTTP/3 PUSH_PROMISE cannot target a rejected request stream: " & $streamId
    )
  if streamId notin session.pendingRequests:
    raiseProtocolViolation(
      H3ErrFrameUnexpected,
      "HTTP/3 PUSH_PROMISE requires an active request stream context: " & $streamId
    )
  if not session.pendingRequests[streamId].sawHeaders:
    raiseProtocolViolation(
      H3ErrFrameUnexpected,
      "HTTP/3 PUSH_PROMISE requires request HEADERS on stream: " & $streamId
    )
  let promise = session.conn.createPushPromise(pushId, headers)
  result = @[]
  result.add promise

proc cancelPush*(session: Http3ServerSession, pushId: uint64): seq[byte] =
  session.conn.cancelPush(pushId)

proc pendingRequestStreamIds*(session: Http3ServerSession): seq[uint64] =
  for streamId in session.pendingRequests.keys:
    result.add streamId

proc hasPendingRequestStream*(session: Http3ServerSession, streamId: uint64): bool =
  streamId in session.pendingRequests

proc qpackBlockedRequestStreamIds*(session: Http3ServerSession): seq[uint64] =
  for streamId in session.qpackBlockedRequestStreams.keys:
    result.add streamId

proc isQpackBlockedRequestStream*(session: Http3ServerSession, streamId: uint64): bool =
  streamId in session.qpackBlockedRequestStreams

proc routeH3Datagram*(session: Http3ServerSession,
                      payload: openArray[byte]): tuple[consumed: bool, outgoing: seq[seq[byte]]] =
  if session.isNil or session.conn.isNil or payload.len == 0:
    return (consumed: false, outgoing: @[])
  if not session.conn.canSendH3Datagrams():
    return (consumed: false, outgoing: @[])
  let consumed = session.conn.ingestH3Datagram(payload)
  if not consumed:
    return (consumed: false, outgoing: @[])
  result.consumed = true
  result.outgoing = session.conn.popWebTransportOutgoingDatagrams()
  let masque = session.conn.popMasqueOutgoingDatagrams()
  if masque.len > 0:
    result.outgoing.add masque

proc drainMasqueOutgoingCapsulesByStream*(session: Http3ServerSession): seq[tuple[streamId: uint64, capsules: seq[MasqueCapsule]]] =
  if session.isNil:
    return @[]
  session.conn.popMasqueOutgoingCapsulesByStream()
