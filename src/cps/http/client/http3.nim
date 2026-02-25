## HTTP/3 client adapter.

import std/[strutils, os, tables, times]
import ../../runtime
import ../../transform
import ../../eventloop
import ../shared/http3
import ../shared/qpack
import ../shared/http3_connection
import ../shared/masque as masque_shared
import ../../quic/endpoint
import ../../quic/connection
import ../../quic/streams
import ../../quic/types

type
  Http3ProtocolError* = object of ValueError
    errorCode*: uint64
    streamId*: uint64

  Http3ClientResponse* = object
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string

  Http3ClientSession* = ref object
    conn*: Http3Connection

  Http3PendingResponseState = object
    statusCode: int
    headers: seq[(string, string)]
    body: seq[byte]
    requestMethod: string
    sawHeaders: bool
    sawTrailers: bool
    hasExpectedContentLength: bool
    expectedContentLength: uint64
    qpackBlocked: bool
    streamEnded: bool
    error: string
    errorCode: uint64
    errorStreamId: uint64

  Http3ClientTransport* = ref object
    endpoint*: QuicEndpoint
    conn*: QuicConnection
    session*: Http3ClientSession
    host*: string
    port*: int
    pendingResponses: Table[uint64, Http3PendingResponseState]
    abandonedResponseStreams: Table[uint64, bool]
    pollActive: bool
    connectionError: string
    connectionErrorCode: uint64
    connectionErrorStreamId: uint64

const headerTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                          '_', '`', '|', '~'} + Digits + Letters

proc raiseHttp3ProtocolError(msg: string, errorCode: uint64, streamId: uint64) {.noreturn.} =
  var err = newException(Http3ProtocolError, msg)
  err.errorCode = errorCode
  err.streamId = streamId
  raise err

proc newHttp3ClientSession*(enableDatagram: bool = true): Http3ClientSession =
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  if not enableDatagram:
    conn.setLocalSettingValue(H3SettingH3Datagram, 0'u64)
  Http3ClientSession(conn: conn)

proc drainApplicationDatagrams*(session: Http3ClientSession): seq[seq[byte]] =
  if session.isNil or session.conn.isNil:
    return @[]
  result = session.conn.popWebTransportOutgoingDatagrams()
  let masque = session.conn.popMasqueOutgoingDatagrams()
  if masque.len > 0:
    result.add masque

proc ingestApplicationDatagram*(session: Http3ClientSession,
                                payload: openArray[byte]): bool =
  if session.isNil or session.conn.isNil:
    return false
  if not session.conn.canSendH3Datagrams():
    return false
  session.conn.ingestH3Datagram(payload)

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(ord(s[i]) and 0xFF)

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(data[i])

proc isValidHeaderName(name: string): bool =
  if name.len == 0:
    return false
  for c in name:
    if c notin headerTokenChars:
      return false
  true

proc isValidHeaderValue(value: string): bool =
  for c in value:
    if c == '\r' or c == '\n':
      return false
    if c == '\0':
      return false
    if ord(c) < 0x20 and c != '\t':
      return false
    if ord(c) == 0x7F:
      return false
  true

proc fieldSectionSize(headers: openArray[QpackHeaderField]): uint64 =
  for (name, value) in headers:
    let entry = uint64(name.len + value.len + 32)
    if high(uint64) - result < entry:
      return high(uint64)
    result += entry

proc validatePeerFieldSectionSize(conn: Http3Connection,
                                  headers: openArray[QpackHeaderField]) =
  if conn.isNil:
    return
  let peerLimit = conn.peerSettingValue(H3SettingMaxFieldSectionSize, high(uint64))
  if fieldSectionSize(headers) > peerLimit:
    raise newException(
      ValueError,
      "HTTP/3 request headers exceed peer SETTINGS_MAX_FIELD_SECTION_SIZE"
    )

proc parseContentLengthValue(value: string, streamId: uint64): uint64 =
  if value.len == 0:
    raiseHttp3ProtocolError(
      "HTTP/3 response has invalid content-length value",
      H3ErrMessageError,
      streamId
    )
  for ch in value:
    if ch notin Digits:
      raiseHttp3ProtocolError(
        "HTTP/3 response has invalid content-length value",
        H3ErrMessageError,
        streamId
      )
  let parsed =
    try:
      parseInt(value)
    except ValueError:
      raiseHttp3ProtocolError(
        "HTTP/3 response has invalid content-length value",
        H3ErrMessageError,
        streamId
      )
  if parsed < 0:
    raiseHttp3ProtocolError(
      "HTTP/3 response has invalid content-length value",
      H3ErrMessageError,
      streamId
    )
  uint64(parsed)

proc isHeadRequestMethod(requestMethod: string): bool =
  requestMethod.len == 4 and cmpIgnoreCase(requestMethod, "HEAD") == 0

proc enforceResponseBodyLengthAtEnd(streamId: uint64,
                                    bodyLen: int,
                                    hasExpectedContentLength: bool,
                                    expectedContentLength: uint64,
                                    requestMethod: string = "") =
  if isHeadRequestMethod(requestMethod):
    return
  if not hasExpectedContentLength:
    return
  if uint64(max(0, bodyLen)) != expectedContentLength:
    raiseHttp3ProtocolError(
      "HTTP/3 response body length does not match content-length",
      H3ErrMessageError,
      streamId
    )

proc applyResponseEvents(events: openArray[Http3Event],
                         statusCode: var int,
                         headers: var seq[(string, string)],
                         body: var seq[byte],
                         sawHeaders: var bool,
                         sawTrailers: var bool,
                         hasExpectedContentLength: var bool,
                         expectedContentLength: var uint64,
                         requestMethod: string = ""): bool =
  ## Apply parsed request-stream events to an HTTP/3 response accumulator.
  ## Returns true when header decode remains blocked on QPACK dynamic state.
  var qpackBlocked = false
  for ev in events:
    case ev.kind
    of h3evHeaders:
      let isFinalHeadersSeen = sawHeaders
      if isFinalHeadersSeen and sawTrailers:
        raiseHttp3ProtocolError(
          "HTTP/3 response has duplicate trailing HEADERS frame",
          H3ErrFrameUnexpected,
          ev.streamId
        )
      var seenRegular = false
      var sawStatus = false
      var parsedStatus = 0
      var sectionHeaders: seq[(string, string)] = @[]
      var sectionHasContentLength = false
      var sectionContentLength = 0'u64
      for (k, v) in ev.headers:
        if k.startsWith(":"):
          if seenRegular:
            raiseHttp3ProtocolError(
              "HTTP/3 response pseudo-headers must appear before regular headers",
              H3ErrMessageError,
              ev.streamId
            )
          if isFinalHeadersSeen:
            raiseHttp3ProtocolError(
              "HTTP/3 response trailers must not contain pseudo-headers",
              H3ErrMessageError,
              ev.streamId
            )
          if k != ":status":
            raiseHttp3ProtocolError(
              "HTTP/3 response contains unsupported pseudo-header: " & k,
              H3ErrMessageError,
              ev.streamId
            )
          if sawStatus:
            raiseHttp3ProtocolError(
              "HTTP/3 response has duplicate :status pseudo-header",
              H3ErrMessageError,
              ev.streamId
            )
          if v.len != 3:
            raiseHttp3ProtocolError(
              "HTTP/3 response has invalid :status pseudo-header",
              H3ErrMessageError,
              ev.streamId
            )
          for ch in v:
            if ch notin Digits:
              raiseHttp3ProtocolError(
                "HTTP/3 response has invalid :status pseudo-header",
                H3ErrMessageError,
                ev.streamId
              )
          sawStatus = true
          parsedStatus =
            try:
              parseInt(v)
            except ValueError:
              raiseHttp3ProtocolError(
                "HTTP/3 response has invalid :status pseudo-header",
                H3ErrMessageError,
                ev.streamId
              )
          if parsedStatus < 100 or parsedStatus > 999:
            raiseHttp3ProtocolError(
              "HTTP/3 response has out-of-range :status pseudo-header",
                H3ErrMessageError,
                ev.streamId
              )
        else:
          let lower = k.toLowerAscii
          if k != lower:
            raiseHttp3ProtocolError(
              "HTTP/3 response header names must be lowercase",
              H3ErrMessageError,
              ev.streamId
            )
          if not isValidHeaderName(k) or not isValidHeaderValue(v):
            raiseHttp3ProtocolError(
              "HTTP/3 response contains invalid header field",
              H3ErrMessageError,
              ev.streamId
            )
          case lower
          of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te":
            raiseHttp3ProtocolError(
              "HTTP/3 response contains forbidden connection-specific header: " & lower,
              H3ErrMessageError,
              ev.streamId
            )
          of "content-length":
            if isFinalHeadersSeen:
              raiseHttp3ProtocolError(
                "HTTP/3 response trailers must not contain content-length",
                H3ErrMessageError,
                ev.streamId
              )
            let parsedContentLength = parseContentLengthValue(v, ev.streamId)
            if sectionHasContentLength and parsedContentLength != sectionContentLength:
              raiseHttp3ProtocolError(
                "HTTP/3 response has conflicting content-length values",
                H3ErrMessageError,
                ev.streamId
              )
            sectionHasContentLength = true
            sectionContentLength = parsedContentLength
          else:
            discard
          seenRegular = true
          sectionHeaders.add (lower, v)

      if not isFinalHeadersSeen and not sawStatus:
        raiseHttp3ProtocolError(
          "HTTP/3 response missing required :status pseudo-header",
          H3ErrMessageError,
          ev.streamId
        )

      if sawStatus and parsedStatus >= 100 and parsedStatus < 200:
        if parsedStatus == 101:
          raiseHttp3ProtocolError(
            "HTTP/3 response uses unsupported 101 status code",
            H3ErrMessageError,
            ev.streamId
          )
        if isFinalHeadersSeen:
          raiseHttp3ProtocolError(
            "HTTP/3 informational response received after final response headers",
            H3ErrMessageError,
            ev.streamId
          )
        # Informational response header sections are valid but do not complete
        # the final response state exposed by this client API.
        continue

      if not isFinalHeadersSeen:
        if sectionHasContentLength:
          if hasExpectedContentLength and expectedContentLength != sectionContentLength:
            raiseHttp3ProtocolError(
              "HTTP/3 response has conflicting content-length values",
              H3ErrMessageError,
              ev.streamId
            )
          hasExpectedContentLength = true
          expectedContentLength = sectionContentLength
        statusCode = parsedStatus
        headers = sectionHeaders
        sawHeaders = true
      else:
        headers.add sectionHeaders
        sawTrailers = true
    of h3evData:
      if not sawHeaders:
        raiseHttp3ProtocolError(
          "HTTP/3 response DATA before final HEADERS",
          H3ErrFrameUnexpected,
          ev.streamId
        )
      if sawTrailers:
        raiseHttp3ProtocolError(
          "HTTP/3 response DATA after trailing HEADERS",
          H3ErrFrameUnexpected,
          ev.streamId
        )
      if isHeadRequestMethod(requestMethod):
        if ev.data.len > 0:
          raiseHttp3ProtocolError(
            "HTTP/3 HEAD response must not contain DATA",
            H3ErrMessageError,
            ev.streamId
          )
        continue
      if ev.data.len > 0:
        if hasExpectedContentLength:
          let currentBodyLen = uint64(max(0, body.len))
          if currentBodyLen > expectedContentLength or
              uint64(ev.data.len) > expectedContentLength - currentBodyLen:
            raiseHttp3ProtocolError(
              "HTTP/3 response body exceeds content-length",
              H3ErrMessageError,
              ev.streamId
            )
        body.add ev.data
    of h3evProtocolError:
      let detail = if ev.errorMessage.len > 0: ev.errorMessage else: "unknown protocol error"
      let codeSuffix = if ev.errorCode != 0'u64: " (code=" & $ev.errorCode & ")" else: ""
      raiseHttp3ProtocolError(
        "HTTP/3 response protocol error" & codeSuffix & ": " & detail,
        ev.errorCode,
        ev.streamId
      )
    of h3evNone:
      if ev.errorMessage == "qpack_blocked":
        qpackBlocked = true
    else:
      discard
  qpackBlocked

proc newPendingResponseState(requestMethod: string = ""): Http3PendingResponseState =
  Http3PendingResponseState(
    statusCode: 200,
    headers: @[],
    body: @[],
    requestMethod: requestMethod,
    sawHeaders: false,
    sawTrailers: false,
    hasExpectedContentLength: false,
    expectedContentLength: 0'u64,
    qpackBlocked: false,
    streamEnded: false,
    error: "",
    errorCode: 0'u64,
    errorStreamId: 0'u64
  )

proc setTransportError(transport: Http3ClientTransport,
                       msg: string,
                       errorCode: uint64 = 0'u64,
                       streamId: uint64 = 0'u64) =
  if transport.isNil or msg.len == 0:
    return
  if transport.connectionError.len == 0:
    transport.connectionError = msg
    transport.connectionErrorCode = errorCode
    transport.connectionErrorStreamId = streamId
  for _, pending in transport.pendingResponses.mpairs:
    if pending.error.len == 0:
      pending.error = msg
      pending.errorCode = errorCode
      pending.errorStreamId = streamId

proc pollClientTransportStreams(transport: Http3ClientTransport) =
  if transport.isNil or transport.conn.isNil or transport.session.isNil or transport.session.conn.isNil:
    return
  if transport.pollActive:
    return
  if transport.connectionError.len > 0:
    return

  transport.pollActive = true
  var sawQpackUpdate = false
  try:
    for streamId, streamObj in transport.conn.streams:
      if not isBidirectionalStream(streamId):
        let chunk = streamObj.popRecvData(high(int))
        let streamEnded = streamObj.recvState == qrsDataRecvd
        if chunk.len == 0 and not streamEnded:
          continue
        var uniEvents = transport.session.conn.ingestUniStreamData(streamId, chunk)
        if streamEnded:
          let finEvents = transport.session.conn.finalizeUniStream(streamId)
          if finEvents.len > 0:
            uniEvents.add finEvents
        for ev in uniEvents:
          if ev.kind == h3evProtocolError:
            let codeSuffix = if ev.errorCode != 0'u64: " (code=" & $ev.errorCode & ")" else: ""
            transport.setTransportError(
              "HTTP/3 unidirectional stream protocol error" & codeSuffix & ": " &
              (if ev.errorMessage.len > 0: ev.errorMessage else: "unknown"),
              errorCode = ev.errorCode,
              streamId = ev.streamId
            )
            return
        if chunk.len > 0:
          sawQpackUpdate = true
        continue

      if not isClientInitiatedStream(streamId):
        discard streamObj.popRecvData(high(int))
        transport.setTransportError(
          "HTTP/3 peer opened invalid bidirectional stream: " & $streamId,
          errorCode = H3ErrStreamCreation,
          streamId = streamId
        )
        return

      if streamId notin transport.pendingResponses:
        let chunk = streamObj.popRecvData(high(int))
        let streamEnded = streamObj.recvState == qrsDataRecvd
        if streamId in transport.abandonedResponseStreams:
          if streamEnded:
            transport.abandonedResponseStreams.del(streamId)
            transport.session.conn.clearRequestStreamState(streamId)
          continue
        if transport.session.conn.hasWebTransportSession(streamId):
          # WebTransport CONNECT streams are long-lived tunnels. Ignore
          # post-establishment stream bytes on this control path.
          if streamEnded:
            transport.session.conn.clearWebTransportSessionState(streamId)
          continue
        if chunk.len > 0 and transport.session.conn.hasMasqueSession(streamId):
          try:
            discard transport.session.conn.ingestMasqueCapsuleData(streamId, chunk)
          except CatchableError:
            transport.setTransportError(
              "HTTP/3 MASQUE capsule decode failure: " &
              (if getCurrentExceptionMsg().len > 0: getCurrentExceptionMsg() else: "decode failure")
            )
            return
          if streamEnded:
            transport.session.conn.clearMasqueSessionState(streamId)
          continue
        if chunk.len > 0:
          transport.setTransportError("HTTP/3 received unexpected bidirectional stream: " & $streamId)
          return
        if streamEnded and transport.session.conn.hasMasqueSession(streamId):
          transport.session.conn.clearMasqueSessionState(streamId)
        continue

      let chunk = streamObj.popRecvData(high(int))
      let streamEnded = streamObj.recvState == qrsDataRecvd
      if chunk.len == 0 and not streamEnded:
        continue

      var pending = transport.pendingResponses[streamId]
      if pending.error.len > 0:
        continue

      if chunk.len > 0:
        if transport.session.conn.hasMasqueSession(streamId):
          try:
            discard transport.session.conn.ingestMasqueCapsuleData(streamId, chunk)
          except CatchableError:
            pending.error =
              if getCurrentExceptionMsg().len > 0:
                "HTTP/3 MASQUE capsule decode failure: " & getCurrentExceptionMsg()
              else:
                "HTTP/3 MASQUE capsule decode failed"
        else:
          try:
            let events = transport.session.conn.processRequestStreamData(
              streamId,
              chunk,
              allowInformationalHeaders = true
            )
            pending.qpackBlocked = applyResponseEvents(
              events,
              pending.statusCode,
              pending.headers,
              pending.body,
              pending.sawHeaders,
              pending.sawTrailers,
              pending.hasExpectedContentLength,
              pending.expectedContentLength,
              pending.requestMethod
            )
          except CatchableError:
            let ex = getCurrentException()
            if not ex.isNil and ex of Http3ProtocolError:
              let h3Err = cast[Http3ProtocolError](ex)
              pending.error = h3Err.msg
              pending.errorCode = h3Err.errorCode
              pending.errorStreamId = h3Err.streamId
            else:
              pending.error =
                if getCurrentExceptionMsg().len > 0:
                  getCurrentExceptionMsg()
                else:
                  "HTTP/3 response decode failed"
      if streamEnded:
        if pending.error.len == 0:
          try:
            let finEvents = transport.session.conn.finalizeRequestStream(
              streamId,
              allowInformationalHeaders = true
            )
            if finEvents.len > 0:
              pending.qpackBlocked = applyResponseEvents(
                finEvents,
                pending.statusCode,
                pending.headers,
                pending.body,
                pending.sawHeaders,
                pending.sawTrailers,
                pending.hasExpectedContentLength,
                pending.expectedContentLength,
                pending.requestMethod
              )
            if pending.error.len == 0 and not pending.qpackBlocked:
              enforceResponseBodyLengthAtEnd(
                streamId,
                pending.body.len,
                pending.hasExpectedContentLength,
                pending.expectedContentLength,
                pending.requestMethod
              )
          except CatchableError:
            let ex = getCurrentException()
            if not ex.isNil and ex of Http3ProtocolError:
              let h3Err = cast[Http3ProtocolError](ex)
              pending.error = h3Err.msg
              pending.errorCode = h3Err.errorCode
              pending.errorStreamId = h3Err.streamId
            else:
              pending.error =
                if getCurrentExceptionMsg().len > 0:
                  getCurrentExceptionMsg()
                else:
                  "HTTP/3 response finalization failed"
        pending.streamEnded = true
        if transport.session.conn.hasMasqueSession(streamId):
          transport.session.conn.clearMasqueSessionState(streamId)
      transport.pendingResponses[streamId] = pending

    if sawQpackUpdate:
      for streamId, pending in transport.pendingResponses.mpairs:
        if pending.error.len > 0 or not pending.qpackBlocked:
          continue
        try:
          let retryEvents = transport.session.conn.processRequestStreamData(
            streamId,
            @[],
            allowInformationalHeaders = true
          )
          pending.qpackBlocked = applyResponseEvents(
            retryEvents,
            pending.statusCode,
            pending.headers,
            pending.body,
            pending.sawHeaders,
            pending.sawTrailers,
            pending.hasExpectedContentLength,
            pending.expectedContentLength,
            pending.requestMethod
          )
          if pending.streamEnded and not pending.qpackBlocked:
            let finEvents = transport.session.conn.finalizeRequestStream(
              streamId,
              allowInformationalHeaders = true
            )
            if finEvents.len > 0:
              pending.qpackBlocked = applyResponseEvents(
                finEvents,
                pending.statusCode,
                pending.headers,
                pending.body,
                pending.sawHeaders,
                pending.sawTrailers,
                pending.hasExpectedContentLength,
                pending.expectedContentLength,
                pending.requestMethod
              )
            if not pending.qpackBlocked:
              enforceResponseBodyLengthAtEnd(
                streamId,
                pending.body.len,
                pending.hasExpectedContentLength,
                pending.expectedContentLength,
                pending.requestMethod
              )
        except CatchableError:
          let ex = getCurrentException()
          if not ex.isNil and ex of Http3ProtocolError:
            let h3Err = cast[Http3ProtocolError](ex)
            pending.error = h3Err.msg
            pending.errorCode = h3Err.errorCode
            pending.errorStreamId = h3Err.streamId
          else:
            pending.error =
              if getCurrentExceptionMsg().len > 0:
                getCurrentExceptionMsg()
              else:
                "HTTP/3 blocked response decode failed"

    let incomingDatagrams = transport.conn.popIncomingDatagrams()
    if incomingDatagrams.len > 0:
      for dg in incomingDatagrams:
        discard transport.session.ingestApplicationDatagram(dg)
  finally:
    transport.pollActive = false

proc buildRequestHeaders(meth: string, path: string, authority: string,
                         headers: openArray[(string, string)]): seq[QpackHeaderField] =
  if meth.len == 0:
    raise newException(ValueError, "HTTP/3 request requires non-empty method")
  if not isValidHeaderName(meth):
    raise newException(ValueError, "HTTP/3 request has invalid :method pseudo-header token")
  if authority.len == 0:
    raise newException(ValueError, "HTTP/3 request requires non-empty authority")
  if meth == "CONNECT" and path.len > 0:
    raise newException(
      ValueError,
      "HTTP/3 extended CONNECT requires :protocol pseudo-header and is not supported by this generic request API"
    )
  let plainConnect = meth == "CONNECT" and path.len == 0
  result = @[
    (":method", meth),
    (":authority", authority)
  ]
  if not plainConnect:
    if path.len == 0:
      raise newException(ValueError, "HTTP/3 request requires non-empty path")
    result.insert((":scheme", "https"), 1)
    result.add (":path", path)
  var sawHostHeader = false
  var hostValue = ""
  for (k, v) in headers:
    let lower = k.toLowerAscii
    if lower.startsWith(":"):
      raise newException(ValueError, "HTTP/3 request headers must not include pseudo-header overrides")
    if not isValidHeaderName(lower) or not isValidHeaderValue(v):
      raise newException(ValueError, "HTTP/3 request contains invalid header field")
    case lower
    of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding":
      raise newException(
        ValueError,
        "HTTP/3 request contains forbidden connection-specific header: " & lower
      )
    of "te":
      if v.toLowerAscii != "trailers":
        raise newException(ValueError, "HTTP/3 request TE header must be \"trailers\"")
    of "host":
      if sawHostHeader:
        raise newException(ValueError, "HTTP/3 request must not include duplicate host header fields")
      sawHostHeader = true
      hostValue = v
    else:
      discard
    result.add (lower, v)
  if sawHostHeader and hostValue.toLowerAscii != authority.toLowerAscii:
    raise newException(ValueError, "HTTP/3 request host header must match :authority pseudo-header")

proc parseRequestContentLengthValue(value: string): uint64 =
  if value.len == 0:
    raise newException(ValueError, "HTTP/3 request has invalid content-length value")
  for ch in value:
    if ch notin Digits:
      raise newException(ValueError, "HTTP/3 request has invalid content-length value")
  let parsed =
    try:
      parseInt(value)
    except ValueError:
      raise newException(ValueError, "HTTP/3 request has invalid content-length value")
  if parsed < 0:
    raise newException(ValueError, "HTTP/3 request has invalid content-length value")
  uint64(parsed)

proc validateRequestContentLength(headers: openArray[QpackHeaderField], bodyLen: int) =
  var hasContentLength = false
  var expectedContentLength = 0'u64
  for (k, v) in headers:
    if k != "content-length":
      continue
    let parsed = parseRequestContentLengthValue(v)
    if hasContentLength and parsed != expectedContentLength:
      raise newException(ValueError, "HTTP/3 request has conflicting content-length values")
    hasContentLength = true
    expectedContentLength = parsed
  if hasContentLength and uint64(max(0, bodyLen)) != expectedContentLength:
    raise newException(ValueError, "HTTP/3 request body length does not match content-length")

proc encodeRequestFrames*(session: Http3ClientSession,
                          meth: string,
                          path: string,
                          authority: string,
                          headers: openArray[(string, string)],
                          body: string): seq[byte] =
  let hdrs = buildRequestHeaders(meth, path, authority, headers)
  validateRequestContentLength(hdrs, body.len)
  validatePeerFieldSectionSize(session.conn, hdrs)
  let payload = if body.len > 0: stringToBytes(body) else: @[]
  result = session.conn.submitRequest(hdrs, payload)

proc decodeResponseFrames*(session: Http3ClientSession,
                           streamId: uint64,
                           payload: openArray[byte],
                           requestMethod: string = ""): Http3ClientResponse =
  if not isBidirectionalStream(streamId) or not isClientInitiatedStream(streamId):
    raiseHttp3ProtocolError(
      "HTTP/3 response stream has invalid id: " & $streamId,
      H3ErrStreamCreation,
      streamId
    )
  let events = session.conn.processRequestStreamData(
    streamId,
    payload,
    allowInformationalHeaders = true
  )
  var statusCode = 200
  var headers: seq[(string, string)] = @[]
  var body: seq[byte] = @[]
  var sawHeaders = false
  var sawTrailers = false
  var hasExpectedContentLength = false
  var expectedContentLength = 0'u64
  var blocked = false
  var clearStateOnExit = true
  try:
    blocked = applyResponseEvents(
      events,
      statusCode,
      headers,
      body,
      sawHeaders,
      sawTrailers,
      hasExpectedContentLength,
      expectedContentLength,
      requestMethod
    )
    let finEvents = session.conn.finalizeRequestStream(
      streamId,
      allowInformationalHeaders = true
    )
    if finEvents.len > 0:
      blocked = blocked or applyResponseEvents(
        finEvents,
        statusCode,
        headers,
        body,
        sawHeaders,
        sawTrailers,
        hasExpectedContentLength,
        expectedContentLength,
        requestMethod
      )
    if blocked:
      # Keep stream state for caller-driven retry after peer QPACK encoder updates.
      clearStateOnExit = false
      raise newException(ValueError, "HTTP/3 response decode blocked on QPACK dynamic table state")
    if not sawHeaders:
      raiseHttp3ProtocolError(
        "HTTP/3 response missing final HEADERS frame",
        H3ErrMessageError,
        streamId
      )
    enforceResponseBodyLengthAtEnd(
      streamId,
      body.len,
      hasExpectedContentLength,
      expectedContentLength,
      requestMethod
    )
    return Http3ClientResponse(
      statusCode: statusCode,
      headers: headers,
      body: bytesToString(body)
    )
  finally:
    if clearStateOnExit:
      session.conn.clearRequestStreamState(streamId)

proc parseAuthorityPort(authority: string): int =
  if authority.len == 0:
    return 0
  if authority[0] == '[':
    let closeIdx = authority.find(']')
    if closeIdx >= 0 and closeIdx + 1 < authority.len and authority[closeIdx + 1] == ':':
      try:
        let parsed = parseInt(authority[(closeIdx + 2) .. ^1])
        if parsed > 0 and parsed <= 65535:
          return parsed
        return 0
      except ValueError:
        return 0
    return 0
  let firstColon = authority.find(':')
  if firstColon < 0:
    return 0
  if firstColon != authority.rfind(':'):
    # Unbracketed IPv6 or ambiguous authority; ignore.
    return 0
  try:
    let parsed = parseInt(authority[(firstColon + 1) .. ^1])
    if parsed > 0 and parsed <= 65535:
      return parsed
    0
  except ValueError:
    0

proc isUsable*(transport: Http3ClientTransport): bool =
  if transport.isNil or transport.endpoint.isNil or transport.conn.isNil or transport.session.isNil:
    return false
  if not transport.endpoint.running:
    return false
  transport.conn.state notin {qcsClosed, qcsDraining}

proc close*(transport: Http3ClientTransport, closeSocket: bool = true) =
  if transport.isNil or transport.endpoint.isNil:
    return
  transport.endpoint.shutdown(closeSocket = closeSocket)

proc flushQpackControlStreams(transport: Http3ClientTransport): CpsVoidFuture {.cps.} =
  if transport.isNil or transport.endpoint.isNil or transport.conn.isNil or
      transport.session.isNil or transport.session.conn.isNil:
    return
  if transport.conn.state in {qcsClosed, qcsDraining}:
    return
  if not transport.conn.canEncodePacketType(qptShort):
    return

  let encUpdates = transport.session.conn.drainQpackEncoderStreamData()
  if encUpdates.len > 0:
    await transport.endpoint.sendStreamData(
      transport.conn,
      transport.session.conn.qpackEncoderStreamId,
      encUpdates,
      fin = false
    )

  let decUpdates = transport.session.conn.drainQpackDecoderStreamData()
  if decUpdates.len > 0:
    await transport.endpoint.sendStreamData(
      transport.conn,
      transport.session.conn.qpackDecoderStreamId,
      decUpdates,
      fin = false
    )

proc flushApplicationDatagrams(transport: Http3ClientTransport): CpsVoidFuture {.cps.} =
  if transport.isNil or transport.endpoint.isNil or transport.conn.isNil or
      transport.session.isNil or transport.session.conn.isNil:
    return
  if transport.conn.state in {qcsClosed, qcsDraining}:
    return
  if not transport.conn.canEncodePacketType(qptShort):
    return
  if not transport.session.conn.canSendH3Datagrams():
    if transport.session.conn.peerSettingsReceived:
      # Peer disabled H3 DATAGRAM support; drop queued application datagrams.
      discard transport.session.drainApplicationDatagrams()
    return

  let datagrams = transport.session.drainApplicationDatagrams()
  if datagrams.len == 0:
    return
  for dg in datagrams:
    if dg.len == 0:
      continue
    try:
      await transport.endpoint.sendDatagram(transport.conn, dg)
    except CatchableError:
      transport.setTransportError(
        if getCurrentExceptionMsg().len > 0:
          getCurrentExceptionMsg()
        else:
          "HTTP/3 application datagram send failed"
      )
      return

proc flushApplicationCapsules(transport: Http3ClientTransport): CpsVoidFuture {.cps.} =
  if transport.isNil or transport.endpoint.isNil or transport.conn.isNil or
      transport.session.isNil or transport.session.conn.isNil:
    return
  if transport.conn.state in {qcsClosed, qcsDraining}:
    return
  if not transport.conn.canEncodePacketType(qptShort):
    return

  let capsulesByStream = transport.session.conn.popMasqueOutgoingCapsulesByStream()
  if capsulesByStream.len == 0:
    return
  for batch in capsulesByStream:
    for capsule in batch.capsules:
      let capsuleWire = masque_shared.encodeCapsuleWire(capsule.capsuleType, capsule.payload)
      if capsuleWire.len == 0:
        continue
      let dataFrame = encodeDataFrame(capsuleWire)
      if dataFrame.len == 0:
        continue
      try:
        await transport.endpoint.sendStreamData(
          transport.conn,
          batch.streamId,
          dataFrame,
          fin = false
        )
      except CatchableError:
        transport.setTransportError(
          if getCurrentExceptionMsg().len > 0:
            getCurrentExceptionMsg()
          else:
            "HTTP/3 MASQUE capsule send failed"
        )
        return

proc newHttp3ClientTransport*(host: string,
                              port: int,
                              timeoutMs: int = 5_000,
                              enableDatagram: bool = true,
                              enable0Rtt: bool = true,
                              endpointConfig: QuicEndpointConfig = defaultQuicEndpointConfig()): CpsFuture[Http3ClientTransport] {.cps.} =
  if host.len == 0:
    raise newException(ValueError, "HTTP/3 transport requires non-empty host")
  if port <= 0 or port > 65535:
    raise newException(ValueError, "HTTP/3 transport requires port in range 1..65535")
  if timeoutMs <= 0:
    raise newException(ValueError, "HTTP/3 transport timeoutMs must be positive")

  var cfg = endpointConfig
  cfg.quicEnableDatagram = enableDatagram
  # Honor caller timeout for QUIC path establishment.
  cfg.quicIdleTimeoutMs = max(1, min(cfg.quicIdleTimeoutMs, timeoutMs))
  if cfg.qlogSink.isNil and existsEnv("CPS_QUIC_DEBUG"):
    cfg.qlogSink = proc(event: string) =
      echo "[cps-quic-client] ", event

  let session = newHttp3ClientSession(enableDatagram = cfg.quicEnableDatagram)
  let epRef = newQuicClientEndpoint(
    bindHost = "0.0.0.0",
    bindPort = 0,
    config = cfg
  )
  epRef.start()
  var conn: QuicConnection = nil
  let startedAt = epochTime()

  try:
    conn = await epRef.connect(host, port)
    conn.enable0Rtt(enable0Rtt)

    var remainingMs = timeoutMs - int((epochTime() - startedAt) * 1000.0)
    if remainingMs <= 0:
      remainingMs = 1
    var earlyCloseMsg = ""
    var earlyCloseCode = 0'u64
    while remainingMs > 0 and not conn.canEncodePacketType(qptShort):
      if conn.state in {qcsClosed, qcsDraining}:
        earlyCloseCode = conn.closeErrorCode
        if conn.closeReason.len > 0:
          earlyCloseMsg = conn.closeReason
        break
      let sleepMs = min(10, remainingMs)
      await cpsSleep(sleepMs)
      remainingMs -= sleepMs
    if not conn.canEncodePacketType(qptShort):
      if earlyCloseMsg.len == 0 and conn.closeReason.len > 0:
        earlyCloseCode = conn.closeErrorCode
        earlyCloseMsg = conn.closeReason
      if earlyCloseMsg.len > 0:
        let codeSuffix = if earlyCloseCode != 0'u64: " (code=" & $earlyCloseCode & ")" else: ""
        raise newException(
          ValueError,
          "HTTP/3 transport failed before QUIC 1-RTT readiness" & codeSuffix & ": " & earlyCloseMsg
        )
      raise newException(ValueError, "HTTP/3 transport timed out waiting for QUIC 1-RTT readiness")

    let controlStream = conn.openLocalUniStream()
    await epRef.sendStreamData(conn, controlStream.id, session.conn.encodeControlStreamPreface(), fin = false)
    let qpackEnc = conn.openLocalUniStream()
    await epRef.sendStreamData(conn, qpackEnc.id, session.conn.encodeQpackEncoderStreamPreface(), fin = false)
    let qpackDec = conn.openLocalUniStream()
    await epRef.sendStreamData(conn, qpackDec.id, session.conn.encodeQpackDecoderStreamPreface(), fin = false)
  except CatchableError:
    epRef.shutdown(closeSocket = true)
    raise

  return Http3ClientTransport(
    endpoint: epRef,
    conn: conn,
    session: session,
    host: host,
    port: port,
    pendingResponses: initTable[uint64, Http3PendingResponseState](),
    abandonedResponseStreams: initTable[uint64, bool](),
    pollActive: false,
    connectionError: "",
    connectionErrorCode: 0'u64,
    connectionErrorStreamId: 0'u64
  )

proc doHttp3RequestOnTransport*(transport: Http3ClientTransport,
                                meth: string,
                                path: string,
                                authority: string,
                                headers: seq[(string, string)],
                                body: string,
                                timeoutMs: int = 5_000): CpsFuture[Http3ClientResponse] {.cps.} =
  if not transport.isUsable():
    raise newException(ValueError, "HTTP/3 transport is not usable")
  if transport.connectionError.len > 0:
    if transport.connectionErrorCode != 0'u64:
      raiseHttp3ProtocolError(
        transport.connectionError,
        transport.connectionErrorCode,
        transport.connectionErrorStreamId
      )
    raise newException(ValueError, transport.connectionError)

  var resolvedAuthority = authority
  if resolvedAuthority.len == 0:
    resolvedAuthority = if transport.port == 443: transport.host else: transport.host & ":" & $transport.port

  # Validate request semantics before allocating a new QUIC request stream.
  let validatedHeaders = buildRequestHeaders(meth, path, resolvedAuthority, headers)
  validateRequestContentLength(validatedHeaders, body.len)
  validatePeerFieldSectionSize(transport.session.conn, validatedHeaders)
  let requestPayload = if body.len > 0: stringToBytes(body) else: @[]

  let responseStreamId = transport.session.conn.openRequest()
  transport.pendingResponses[responseStreamId] = newPendingResponseState(meth)

  var responseError = ""
  var responseErrorCode = 0'u64
  var responseErrorStreamId = 0'u64
  var abandonResponseStream = false
  var haveDecoded = false
  var decoded: Http3ClientResponse

  try:
    discard transport.conn.getOrCreateStream(responseStreamId)
    let reqFrames = transport.session.conn.submitRequest(validatedHeaders, requestPayload)
    await flushQpackControlStreams(transport)
    await flushApplicationDatagrams(transport)
    await flushApplicationCapsules(transport)
    await transport.endpoint.sendStreamData(transport.conn, responseStreamId, reqFrames, fin = true)

    var waited = 0
    while waited < max(1, timeoutMs):
      pollClientTransportStreams(transport)
      await flushQpackControlStreams(transport)
      await flushApplicationDatagrams(transport)
      await flushApplicationCapsules(transport)
      if transport.connectionError.len > 0:
        responseError = transport.connectionError
        responseErrorCode = transport.connectionErrorCode
        responseErrorStreamId = transport.connectionErrorStreamId
        break
      if responseStreamId in transport.pendingResponses:
        let pending = transport.pendingResponses[responseStreamId]
        if pending.error.len > 0:
          responseError = pending.error
          responseErrorCode = pending.errorCode
          responseErrorStreamId = pending.errorStreamId
          break
        if pending.streamEnded and not pending.qpackBlocked and pending.sawHeaders and
            transport.session.conn.requestStreamBufferedBytes(responseStreamId) == 0:
          decoded = Http3ClientResponse(
            statusCode: pending.statusCode,
            headers: pending.headers,
            body: bytesToString(pending.body)
          )
          haveDecoded = true
          break
      else:
        responseError = "HTTP/3 response stream state missing"
        break

      if transport.conn.state in {qcsClosed, qcsDraining}:
        responseError = "HTTP/3 connection closed before response completed"
        break
      await cpsSleep(10)
      waited += 10

    if not haveDecoded and responseError.len == 0:
      if responseStreamId in transport.pendingResponses:
        let pending = transport.pendingResponses[responseStreamId]
        if not pending.streamEnded:
          responseError = "HTTP/3 request timed out without response"
          abandonResponseStream = true
        elif transport.session.conn.requestStreamBufferedBytes(responseStreamId) > 0:
          responseError = "HTTP/3 response stream ended with incomplete frame payload"
        elif pending.qpackBlocked:
          responseError = "HTTP/3 response remained QPACK-blocked after stream end"
        elif not pending.sawHeaders:
          responseError = "HTTP/3 response missing HEADERS frame"
        else:
          responseError = "HTTP/3 response decode failed"
      else:
        responseError = "HTTP/3 response stream state missing"
  finally:
    if responseStreamId in transport.pendingResponses:
      transport.pendingResponses.del(responseStreamId)
    if abandonResponseStream:
      transport.abandonedResponseStreams[responseStreamId] = true
    if not transport.session.isNil and not transport.session.conn.isNil:
      transport.session.conn.clearRequestStreamState(responseStreamId)

  if responseError.len > 0:
    if responseErrorCode != 0'u64:
      raiseHttp3ProtocolError(responseError, responseErrorCode, responseErrorStreamId)
    raise newException(ValueError, responseError)
  return decoded

proc doHttp3Request*(host: string,
                     port: int,
                     meth: string,
                     path: string,
                     authority: string,
                     headers: seq[(string, string)],
                     body: string,
                     timeoutMs: int = 5_000,
                     enableDatagram: bool = true,
                     enable0Rtt: bool = true,
                     endpointConfig: QuicEndpointConfig = defaultQuicEndpointConfig()): CpsFuture[Http3ClientResponse] {.cps.} =
  if host.len == 0:
    raise newException(ValueError, "HTTP/3 request requires non-empty host")

  var resolvedPort = port
  if resolvedPort <= 0:
    resolvedPort = parseAuthorityPort(authority)
  if resolvedPort <= 0 or resolvedPort > 65535:
    raise newException(ValueError, "HTTP/3 request requires port in range 1..65535")

  var resolvedAuthority = authority
  if resolvedAuthority.len == 0:
    resolvedAuthority = if resolvedPort == 443: host else: host & ":" & $resolvedPort

  var transport: Http3ClientTransport = nil
  var decoded: Http3ClientResponse
  try:
    transport = await newHttp3ClientTransport(
      host = host,
      port = resolvedPort,
      timeoutMs = timeoutMs,
      enableDatagram = enableDatagram,
      enable0Rtt = enable0Rtt,
      endpointConfig = endpointConfig
    )
    decoded = await doHttp3RequestOnTransport(
      transport = transport,
      meth = meth,
      path = path,
      authority = resolvedAuthority,
      headers = headers,
      body = body,
      timeoutMs = timeoutMs
    )
  finally:
    if not transport.isNil:
      transport.close(closeSocket = true)
  return decoded
