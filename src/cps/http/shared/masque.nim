## MASQUE session and capsule primitives.

import std/tables
import std/strutils
import ../../quic/varint
import ./qpack

const
  MasqueConnectUdpProtocol* = "connect-udp"
  MasqueConnectIpProtocol* = "connect-ip"
  MasqueConnectIpDraft* = "draft-ietf-masque-connect-ip-08"
  DefaultMasqueMaxIncomingCapsules* = 256
  DefaultMasqueMaxIncomingDatagrams* = 1024
  DefaultMasqueMaxIncomingCapsuleBytes* = 1 * 1024 * 1024
  DefaultMasqueMaxIncomingDatagramBytes* = 4 * 1024 * 1024
  MasqueMaxDatagramContextId = QuicVarIntMax8

type
  MasqueMode* = enum
    mmConnectUdp
    mmConnectIp

  MasqueConnectRequest* = object
    mode*: MasqueMode
    authority*: string
    target*: string
    httpMethod*: string
    protocol*: string
    scheme*: string
    path*: string
    draftVersion*: string

  MasqueCapsule* = object
    capsuleType*: uint64
    payload*: seq[byte]

  MasqueDatagram* = object
    contextId*: uint64
    payload*: seq[byte]

  MasqueSession* = ref object
    mode*: MasqueMode
    authority*: string
    target*: string
    closed*: bool
    nextContextId*: uint64
    contexts*: Table[uint64, string]
    outgoingCapsules*: seq[MasqueCapsule]
    incomingCapsules*: seq[MasqueCapsule]
    outgoingDatagrams*: seq[MasqueDatagram]
    incomingDatagrams*: seq[MasqueDatagram]
    maxIncomingCapsules*: int
    maxIncomingDatagrams*: int
    maxIncomingCapsuleBytes*: int
    maxIncomingDatagramBytes*: int
    incomingCapsuleBytes*: int
    incomingDatagramBytes*: int

proc newMasqueSession(mode: MasqueMode, authority: string, target: string): MasqueSession =
  MasqueSession(
    mode: mode,
    authority: authority,
    target: target,
    closed: false,
    nextContextId: 0'u64,
    contexts: initTable[uint64, string](),
    outgoingCapsules: @[],
    incomingCapsules: @[],
    outgoingDatagrams: @[],
    incomingDatagrams: @[],
    maxIncomingCapsules: DefaultMasqueMaxIncomingCapsules,
    maxIncomingDatagrams: DefaultMasqueMaxIncomingDatagrams,
    maxIncomingCapsuleBytes: DefaultMasqueMaxIncomingCapsuleBytes,
    maxIncomingDatagramBytes: DefaultMasqueMaxIncomingDatagramBytes,
    incomingCapsuleBytes: 0,
    incomingDatagramBytes: 0
  )

proc connectUdp*(authority: string, targetHostPort: string): MasqueSession =
  newMasqueSession(mmConnectUdp, authority, targetHostPort)

proc connectIp*(authority: string, targetIpPrefix: string): MasqueSession =
  newMasqueSession(mmConnectIp, authority, targetIpPrefix)

proc buildMasqueConnectUdpHeaders*(authority: string,
                                   targetHostPort: string): seq[QpackHeaderField] =
  @[
    (":method", "CONNECT"),
    (":scheme", "https"),
    (":authority", authority),
    (":path", "/.well-known/masque/udp/" & targetHostPort),
    (":protocol", MasqueConnectUdpProtocol),
    ("connect-udp-target", targetHostPort)
  ]

proc buildMasqueConnectIpHeaders*(authority: string,
                                  targetIpPrefix: string,
                                  draftVersion: string = MasqueConnectIpDraft): seq[QpackHeaderField] =
  @[
    (":method", "CONNECT"),
    (":scheme", "https"),
    (":authority", authority),
    (":path", "/.well-known/masque/ip/" & targetIpPrefix),
    (":protocol", MasqueConnectIpProtocol),
    ("connect-ip-target", targetIpPrefix),
    ("connect-ip-draft", draftVersion)
  ]

proc parseMasqueConnectRequest*(headers: openArray[QpackHeaderField]): MasqueConnectRequest =
  var protocol = ""
  var target = ""
  var authority = ""
  var httpMethod = ""
  var scheme = ""
  var path = ""
  var draftVersion = ""
  for (k, v) in headers:
    case k
    of ":protocol":
      protocol = v.toLowerAscii
    of "connect-udp-target", "connect-ip-target":
      target = v
    of ":authority":
      authority = v
    of ":method":
      httpMethod = v
    of ":scheme":
      scheme = v
    of ":path":
      path = v
    of "connect-ip-draft":
      draftVersion = v
    else:
      discard

  let mode =
    if protocol == MasqueConnectIpProtocol: mmConnectIp
    else: mmConnectUdp
  MasqueConnectRequest(
    mode: mode,
    authority: authority,
    target: target,
    httpMethod: httpMethod,
    protocol: protocol,
    scheme: scheme,
    path: path,
    draftVersion: draftVersion
  )

proc isMasqueConnectRequest*(headers: openArray[QpackHeaderField]): bool =
  let req = parseMasqueConnectRequest(headers)
  req.httpMethod == "CONNECT" and
    req.protocol in [MasqueConnectUdpProtocol, MasqueConnectIpProtocol] and
    req.target.len > 0

proc openDatagramContext*(session: MasqueSession, label: string = ""): uint64 =
  if session.isNil or session.closed:
    raise newException(ValueError, "MASQUE session is closed")
  if session.nextContextId > MasqueMaxDatagramContextId:
    raise newException(ValueError, "MASQUE exhausted datagram context identifiers")
  result = session.nextContextId
  if session.nextContextId == MasqueMaxDatagramContextId:
    session.nextContextId = MasqueMaxDatagramContextId + 1'u64
  else:
    session.nextContextId += 1
  session.contexts[result] = label

proc sendCapsule*(session: MasqueSession, capsuleType: uint64, payload: openArray[byte]) =
  if session.isNil or session.closed:
    raise newException(ValueError, "MASQUE session is closed")
  session.outgoingCapsules.add MasqueCapsule(capsuleType: capsuleType, payload: @payload)

proc recvCapsule*(session: MasqueSession): MasqueCapsule =
  if session.isNil or session.incomingCapsules.len == 0:
    return MasqueCapsule(capsuleType: 0'u64, payload: @[])
  result = session.incomingCapsules[0]
  if result.payload.len > 0:
    session.incomingCapsuleBytes = max(0, session.incomingCapsuleBytes - result.payload.len)
  if session.incomingCapsules.len == 1:
    session.incomingCapsules.setLen(0)
  else:
    session.incomingCapsules = session.incomingCapsules[1 .. ^1]

proc enforceIncomingCapsuleLimits(session: MasqueSession) =
  if session.isNil:
    return
  while session.incomingCapsules.len > 0 and
      ((session.maxIncomingCapsules > 0 and session.incomingCapsules.len > session.maxIncomingCapsules) or
       (session.maxIncomingCapsuleBytes > 0 and session.incomingCapsuleBytes > session.maxIncomingCapsuleBytes)):
    let dropped = session.incomingCapsules[0].payload.len
    if session.incomingCapsules.len == 1:
      session.incomingCapsules.setLen(0)
    else:
      session.incomingCapsules = session.incomingCapsules[1 .. ^1]
    if dropped > 0:
      session.incomingCapsuleBytes = max(0, session.incomingCapsuleBytes - dropped)

proc ingestCapsule*(session: MasqueSession, capsuleType: uint64, payload: openArray[byte]) =
  if session.isNil or session.closed:
    return
  if session.maxIncomingCapsuleBytes > 0 and payload.len > session.maxIncomingCapsuleBytes:
    return
  session.incomingCapsules.add MasqueCapsule(capsuleType: capsuleType, payload: @payload)
  if payload.len > 0:
    session.incomingCapsuleBytes += payload.len
  session.enforceIncomingCapsuleLimits()

proc sendDatagram*(session: MasqueSession, contextId: uint64, payload: openArray[byte]) =
  if session.isNil or session.closed:
    raise newException(ValueError, "MASQUE session is closed")
  if contextId notin session.contexts:
    raise newException(ValueError, "unknown MASQUE datagram context")
  session.outgoingDatagrams.add MasqueDatagram(contextId: contextId, payload: @payload)

proc recvDatagram*(session: MasqueSession): MasqueDatagram =
  if session.isNil or session.incomingDatagrams.len == 0:
    return MasqueDatagram(contextId: 0'u64, payload: @[])
  result = session.incomingDatagrams[0]
  if result.payload.len > 0:
    session.incomingDatagramBytes = max(0, session.incomingDatagramBytes - result.payload.len)
  if session.incomingDatagrams.len == 1:
    session.incomingDatagrams.setLen(0)
  else:
    session.incomingDatagrams = session.incomingDatagrams[1 .. ^1]

proc enforceIncomingDatagramLimits(session: MasqueSession) =
  if session.isNil:
    return
  while session.incomingDatagrams.len > 0 and
      ((session.maxIncomingDatagrams > 0 and session.incomingDatagrams.len > session.maxIncomingDatagrams) or
       (session.maxIncomingDatagramBytes > 0 and session.incomingDatagramBytes > session.maxIncomingDatagramBytes)):
    let dropped = session.incomingDatagrams[0].payload.len
    if session.incomingDatagrams.len == 1:
      session.incomingDatagrams.setLen(0)
    else:
      session.incomingDatagrams = session.incomingDatagrams[1 .. ^1]
    if dropped > 0:
      session.incomingDatagramBytes = max(0, session.incomingDatagramBytes - dropped)

proc ingestDatagram*(session: MasqueSession, contextId: uint64, payload: openArray[byte]) =
  if session.isNil or session.closed:
    return
  if contextId notin session.contexts:
    # Unknown contexts are not implicitly created from peer datagrams.
    return
  if session.maxIncomingDatagramBytes > 0 and payload.len > session.maxIncomingDatagramBytes:
    return
  session.incomingDatagrams.add MasqueDatagram(contextId: contextId, payload: @payload)
  if payload.len > 0:
    session.incomingDatagramBytes += payload.len
  session.enforceIncomingDatagramLimits()

proc closeSession*(session: MasqueSession) =
  if session.isNil:
    return
  session.closed = true

proc queuedIncomingCapsules*(session: MasqueSession): int =
  if session.isNil:
    return 0
  session.incomingCapsules.len

proc queuedIncomingCapsuleBytes*(session: MasqueSession): int =
  if session.isNil:
    return 0
  session.incomingCapsuleBytes

proc queuedIncomingDatagrams*(session: MasqueSession): int =
  if session.isNil:
    return 0
  session.incomingDatagrams.len

proc queuedIncomingDatagramBytes*(session: MasqueSession): int =
  if session.isNil:
    return 0
  session.incomingDatagramBytes

proc popOutgoingCapsules*(session: MasqueSession): seq[MasqueCapsule] =
  if session.isNil:
    return @[]
  result = session.outgoingCapsules
  session.outgoingCapsules = @[]

proc popOutgoingDatagrams*(session: MasqueSession): seq[MasqueDatagram] =
  if session.isNil:
    return @[]
  result = session.outgoingDatagrams
  session.outgoingDatagrams = @[]

proc encodeCapsuleWire*(capsuleType: uint64, payload: openArray[byte]): seq[byte] =
  result = @[]
  result.appendQuicVarInt(capsuleType)
  result.appendQuicVarInt(uint64(payload.len))
  if payload.len > 0:
    result.add payload

proc decodeCapsuleWire*(wire: openArray[byte], offset: var int): MasqueCapsule =
  let typ = decodeQuicVarInt(wire, offset)
  let len = decodeQuicVarInt(wire, offset)
  if offset + int(len) > wire.len:
    raise newException(ValueError, "MASQUE capsule truncated")
  result.capsuleType = typ
  result.payload = if len > 0: wire[offset ..< offset + int(len)] else: @[]
  offset += int(len)

proc encodeMasqueDatagramWire*(contextId: uint64, payload: openArray[byte]): seq[byte] =
  result = @[]
  result.appendQuicVarInt(contextId)
  if payload.len > 0:
    result.add payload

proc decodeMasqueDatagramWire*(wire: openArray[byte]): MasqueDatagram =
  var off = 0
  let contextId = decodeQuicVarInt(wire, off)
  result = MasqueDatagram(
    contextId: contextId,
    payload: if off < wire.len: wire[off .. ^1] else: @[]
  )
