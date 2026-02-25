## WebTransport session primitives over HTTP/3 extended CONNECT.

import std/strutils
import ../../quic/varint
import ./qpack

const
  WebTransportProtocolToken* = "webtransport"
  WebTransportDraftVersion* = "draft-ietf-webtrans-http3-14"
  DefaultWebTransportMaxIncomingDatagrams* = 1024
  DefaultWebTransportMaxIncomingDatagramBytes* = 4 * 1024 * 1024
  WebTransportMaxStreamId = QuicVarIntMax8
  WebTransportStreamIdIncrement = 4'u64

type
  WebTransportConnectRequest* = object
    authority*: string
    path*: string
    origin*: string
    httpMethod*: string
    protocol*: string
    scheme*: string
    draftVersion*: string

  WebTransportSession* = ref object
    sessionId*: uint64
    authority*: string
    path*: string
    origin*: string
    isClient*: bool
    closed*: bool
    closeErrorCode*: uint32
    closeReason*: string
    established*: bool
    nextBidiStreamId*: uint64
    nextUniStreamId*: uint64
    outgoingDatagrams*: seq[seq[byte]]
    incomingDatagrams*: seq[seq[byte]]
    maxIncomingDatagrams*: int
    maxIncomingDatagramBytes*: int
    incomingDatagramBytes*: int

proc initSession(sessionId: uint64,
                 authority: string,
                 path: string,
                 isClient: bool,
                 origin: string = ""): WebTransportSession =
  WebTransportSession(
    sessionId: sessionId,
    authority: authority,
    path: path,
    origin: origin,
    isClient: isClient,
    closed: false,
    closeErrorCode: 0'u32,
    closeReason: "",
    established: true,
    nextBidiStreamId: if isClient: 0'u64 else: 1'u64,
    nextUniStreamId: if isClient: 2'u64 else: 3'u64,
    outgoingDatagrams: @[],
    incomingDatagrams: @[],
    maxIncomingDatagrams: DefaultWebTransportMaxIncomingDatagrams,
    maxIncomingDatagramBytes: DefaultWebTransportMaxIncomingDatagramBytes,
    incomingDatagramBytes: 0
  )

proc acceptWebTransportSession*(sessionId: uint64,
                                authority: string,
                                path: string,
                                origin: string = ""): WebTransportSession =
  initSession(sessionId, authority, path, isClient = false, origin = origin)

proc openWebTransportSession*(sessionId: uint64 = 0'u64,
                              authority: string,
                              path: string,
                              origin: string = ""): WebTransportSession =
  initSession(sessionId, authority, path, isClient = true, origin = origin)

proc buildWebTransportConnectHeaders*(authority: string,
                                      path: string,
                                      origin: string = "",
                                      draftVersion: string = WebTransportDraftVersion): seq[QpackHeaderField] =
  result = @[
    (":method", "CONNECT"),
    (":scheme", "https"),
    (":authority", authority),
    (":path", path),
    (":protocol", WebTransportProtocolToken)
  ]
  if origin.len > 0:
    result.add ("origin", origin)
  if draftVersion.len > 0:
    result.add ("sec-webtransport-http3-draft", draftVersion)

proc parseWebTransportConnectHeaders*(headers: openArray[QpackHeaderField]): WebTransportConnectRequest =
  result = WebTransportConnectRequest(
    authority: "",
    path: "",
    origin: "",
    httpMethod: "",
    protocol: "",
    scheme: "",
    draftVersion: ""
  )
  for (k, v) in headers:
    case k
    of ":authority":
      result.authority = v
    of ":path":
      result.path = v
    of ":method":
      result.httpMethod = v
    of ":protocol":
      result.protocol = v
    of ":scheme":
      result.scheme = v
    of "origin":
      result.origin = v
    of "sec-webtransport-http3-draft":
      result.draftVersion = v
    else:
      discard

proc isWebTransportConnectRequest*(headers: openArray[QpackHeaderField]): bool =
  let req = parseWebTransportConnectHeaders(headers)
  req.httpMethod == "CONNECT" and req.protocol.toLowerAscii == WebTransportProtocolToken and
    req.authority.len > 0 and req.path.len > 0

proc encodeWebTransportDatagram*(sessionId: uint64,
                                 payload: openArray[byte]): seq[byte] =
  result = @[]
  result.appendQuicVarInt(sessionId)
  if payload.len > 0:
    result.add payload

proc decodeWebTransportDatagram*(payload: openArray[byte]): tuple[sessionId: uint64, data: seq[byte]] =
  var off = 0
  result.sessionId = decodeQuicVarInt(payload, off)
  if off < payload.len:
    result.data = payload[off .. ^1]
  else:
    result.data = @[]

proc openBidiStream*(session: WebTransportSession): uint64 =
  if session.isNil or session.closed:
    raise newException(ValueError, "WebTransport session is closed")
  if session.nextBidiStreamId > WebTransportMaxStreamId:
    raise newException(ValueError, "WebTransport exhausted bidirectional stream IDs")
  let expectedLowBits = if session.isClient: 0'u64 else: 1'u64
  if (session.nextBidiStreamId and 0x03'u64) != expectedLowBits:
    raise newException(ValueError, "WebTransport next bidirectional stream ID has invalid initiator/direction bits")
  result = session.nextBidiStreamId
  if session.nextBidiStreamId > WebTransportMaxStreamId - WebTransportStreamIdIncrement:
    session.nextBidiStreamId = WebTransportMaxStreamId + 1'u64
  else:
    session.nextBidiStreamId += WebTransportStreamIdIncrement

proc openUniStream*(session: WebTransportSession): uint64 =
  if session.isNil or session.closed:
    raise newException(ValueError, "WebTransport session is closed")
  if session.nextUniStreamId > WebTransportMaxStreamId:
    raise newException(ValueError, "WebTransport exhausted unidirectional stream IDs")
  let expectedLowBits = if session.isClient: 2'u64 else: 3'u64
  if (session.nextUniStreamId and 0x03'u64) != expectedLowBits:
    raise newException(ValueError, "WebTransport next unidirectional stream ID has invalid initiator/direction bits")
  result = session.nextUniStreamId
  if session.nextUniStreamId > WebTransportMaxStreamId - WebTransportStreamIdIncrement:
    session.nextUniStreamId = WebTransportMaxStreamId + 1'u64
  else:
    session.nextUniStreamId += WebTransportStreamIdIncrement

proc sendDatagram*(session: WebTransportSession, payload: openArray[byte]) =
  if session.isNil or session.closed:
    raise newException(ValueError, "WebTransport session is closed")
  if payload.len == 0:
    return
  session.outgoingDatagrams.add @payload

proc popOutgoingDatagrams*(session: WebTransportSession): seq[seq[byte]] =
  if session.isNil:
    return @[]
  result = session.outgoingDatagrams
  session.outgoingDatagrams = @[]

proc recvDatagram*(session: WebTransportSession): seq[byte] =
  if session.isNil or session.incomingDatagrams.len == 0:
    return @[]
  result = session.incomingDatagrams[0]
  if result.len > 0:
    session.incomingDatagramBytes = max(0, session.incomingDatagramBytes - result.len)
  if session.incomingDatagrams.len == 1:
    session.incomingDatagrams.setLen(0)
  else:
    session.incomingDatagrams = session.incomingDatagrams[1 .. ^1]

proc enforceIncomingDatagramLimits(session: WebTransportSession) =
  if session.isNil:
    return
  while session.incomingDatagrams.len > 0 and
      ((session.maxIncomingDatagrams > 0 and session.incomingDatagrams.len > session.maxIncomingDatagrams) or
       (session.maxIncomingDatagramBytes > 0 and session.incomingDatagramBytes > session.maxIncomingDatagramBytes)):
    let dropped = session.incomingDatagrams[0].len
    if session.incomingDatagrams.len == 1:
      session.incomingDatagrams.setLen(0)
    else:
      session.incomingDatagrams = session.incomingDatagrams[1 .. ^1]
    if dropped > 0:
      session.incomingDatagramBytes = max(0, session.incomingDatagramBytes - dropped)

proc ingestDatagram*(session: WebTransportSession, payload: openArray[byte]) =
  if session.isNil or session.closed or payload.len == 0:
    return
  if session.maxIncomingDatagramBytes > 0 and payload.len > session.maxIncomingDatagramBytes:
    return
  session.incomingDatagrams.add @payload
  session.incomingDatagramBytes += payload.len
  session.enforceIncomingDatagramLimits()

proc closeSession*(session: WebTransportSession,
                   errorCode: uint32 = 0'u32,
                   reason: string = "") =
  if session.isNil:
    return
  session.closed = true
  session.closeErrorCode = errorCode
  session.closeReason = reason

proc queuedIncomingDatagrams*(session: WebTransportSession): int =
  if session.isNil:
    return 0
  session.incomingDatagrams.len

proc queuedIncomingDatagramBytes*(session: WebTransportSession): int =
  if session.isNil:
    return 0
  session.incomingDatagramBytes
