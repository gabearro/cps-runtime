## MASQUE capsule/datagram protocol tests.

import std/tables
import cps
import cps/http/client/masque as masque_client
import cps/http/client/http3 as h3_client
import cps/http/server/http3 as h3_server
import cps/http/server/types
import cps/http/shared/masque as masque_shared
import cps/http/shared/http3_connection
import cps/quic/varint

proc negotiateH3DatagramForClient(session: h3_client.Http3ClientSession) =
  let peer = newHttp3Connection(isClient = false)
  let preface = peer.encodeControlStreamPreface()
  discard session.conn.ingestUniStreamData(3'u64, preface)

proc negotiateH3DatagramForServer(session: h3_server.Http3ServerSession) =
  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  discard session.conn.ingestUniStreamData(2'u64, preface)

block testCapsuleSendRecv:
  let session = runCps(masque_client.connectUdp("proxy.example", "8.8.8.8:53"))
  masque_client.sendCapsule(session, 0x00'u64, @[0xAA'u8, 0xBB, 0xCC])
  doAssert session.outgoingCapsules.len == 1

  masque_shared.ingestCapsule(session, 0x01'u64, @[0x10'u8, 0x20])
  let capsule = masque_client.recvCapsule(session)
  doAssert capsule.capsuleType == 0x01'u64
  doAssert capsule.payload == @[0x10'u8, 0x20]
  echo "PASS: MASQUE capsule send/recv"

block testDatagramContextMapping:
  let session = runCps(masque_client.connectUdp("proxy.example", "8.8.4.4:53"))
  let ctx = masque_client.openDatagramContext(session, "dns-alt")
  masque_shared.ingestDatagram(session, ctx, @[0xDE'u8, 0xAD, 0xBE, 0xEF])
  let dg = masque_client.recvDatagram(session)
  doAssert dg.contextId == ctx
  doAssert dg.payload == @[0xDE'u8, 0xAD, 0xBE, 0xEF]
  echo "PASS: MASQUE datagram context receive"

block testUnknownDatagramContextDoesNotAutoRegister:
  let session = runCps(masque_client.connectUdp("proxy.example", "8.8.4.4:53"))
  var unknownBefore = false
  try:
    masque_client.sendDatagram(session, 77'u64, @[0x01'u8])
  except ValueError:
    unknownBefore = true
  doAssert unknownBefore

  masque_shared.ingestDatagram(session, 77'u64, @[0xAA'u8])
  doAssert masque_shared.queuedIncomingDatagrams(session) == 0

  var unknownAfter = false
  try:
    masque_client.sendDatagram(session, 77'u64, @[0x02'u8])
  except ValueError:
    unknownAfter = true
  doAssert unknownAfter
  echo "PASS: MASQUE unknown datagram contexts are dropped without auto-registration"

block testDatagramContextAllocationRejectsExhaustedVarints:
  let session = runCps(masque_client.connectUdp("proxy.example", "8.8.4.4:53"))
  session.nextContextId = QuicVarIntMax8
  doAssert masque_client.openDatagramContext(session, "last") == QuicVarIntMax8
  var exhausted = false
  try:
    discard masque_client.openDatagramContext(session, "overflow")
  except ValueError:
    exhausted = true
  doAssert exhausted
  echo "PASS: MASQUE datagram context allocation rejects exhausted QUIC-varint IDs"

block testCapsuleAndDatagramWireCodec:
  let capWire = masque_client.encodeCapsuleWire(0x27'u64, @[0x01'u8, 0x02])
  var off = 0
  let parsedCap = masque_shared.decodeCapsuleWire(capWire, off)
  doAssert off == capWire.len
  doAssert parsedCap.capsuleType == 0x27'u64
  doAssert parsedCap.payload == @[0x01'u8, 0x02]

  let dgWire = masque_shared.encodeMasqueDatagramWire(9'u64, @[0xFE'u8, 0xED])
  let parsedDg = masque_client.decodeMasqueDatagramWire(dgWire)
  doAssert parsedDg.contextId == 9'u64
  doAssert parsedDg.payload == @[0xFE'u8, 0xED]

  let session = runCps(masque_client.connectUdp("proxy.example", "9.9.9.9:53"))
  let c = masque_client.openDatagramContext(session, "dns")
  masque_client.sendDatagram(session, c, @[0x11'u8, 0x22])
  doAssert masque_shared.popOutgoingDatagrams(session).len == 1
  echo "PASS: MASQUE capsule/datagram wire codec and queue draining"

block testHttp3DatagramRoutingForMasque:
  let h3 = newHttp3Connection(isClient = false)
  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  discard h3.ingestUniStreamData(2'u64, preface)
  let session = h3.registerMasqueUdpSession(33'u64, "proxy.example", "8.8.8.8:53")
  let ctx = masque_client.openDatagramContext(session, "dns")
  let wire = h3.encodeH3DatagramForMasque(33'u64, ctx, @[0xFA'u8, 0xCE])
  doAssert h3.ingestH3Datagram(wire)
  let recv = masque_client.recvDatagram(session)
  doAssert recv.contextId == ctx
  doAssert recv.payload == @[0xFA'u8, 0xCE]
  echo "PASS: HTTP/3 datagram routing into MASQUE session"

block testHttp3ClientSessionDatagramHelpersForMasque:
  let sender = h3_client.newHttp3ClientSession()
  let receiver = h3_client.newHttp3ClientSession()
  negotiateH3DatagramForClient(sender)
  negotiateH3DatagramForClient(receiver)
  let senderSession = sender.conn.registerMasqueUdpSession(44'u64, "proxy.example", "1.1.1.1:53")
  let receiverSession = receiver.conn.registerMasqueUdpSession(44'u64, "proxy.example", "1.1.1.1:53")
  let ctx = masque_client.openDatagramContext(senderSession, "dns")
  discard masque_client.openDatagramContext(receiverSession, "dns")
  masque_client.sendDatagram(senderSession, ctx, @[0xBE'u8, 0xEF])
  let outgoing = h3_client.drainApplicationDatagrams(sender)
  doAssert outgoing.len == 1
  doAssert h3_client.ingestApplicationDatagram(receiver, outgoing[0])
  let recv = masque_client.recvDatagram(receiverSession)
  doAssert recv.contextId == ctx
  doAssert recv.payload == @[0xBE'u8, 0xEF]
  echo "PASS: HTTP/3 client session drains/ingests MASQUE datagrams"

block testHttp3ServerSessionDatagramRoutingForMasque:
  let serverSession = h3_server.newHttp3ServerSession(@[0x02'u8], nil)
  negotiateH3DatagramForServer(serverSession)
  let masque = serverSession.conn.registerMasqueUdpSession(66'u64, "proxy.example", "8.8.8.8:53")
  let ctx = masque_client.openDatagramContext(masque, "dns")
  let incoming = serverSession.conn.encodeH3DatagramForMasque(66'u64, ctx, @[0xCA'u8, 0xFE])
  let routed = h3_server.routeH3Datagram(serverSession, incoming)
  doAssert routed.consumed
  let recv = masque_client.recvDatagram(masque)
  doAssert recv.contextId == ctx
  doAssert recv.payload == @[0xCA'u8, 0xFE]
  echo "PASS: HTTP/3 server session routes MASQUE datagrams"

block testHttp3MasqueCapsuleFragmentBuffering:
  let h3 = newHttp3Connection(isClient = false)
  let session = h3.registerMasqueUdpSession(77'u64, "proxy.example", "8.8.8.8:53")
  let capsuleWire = masque_shared.encodeCapsuleWire(0x2A'u64, @[0xAA'u8, 0xBB, 0xCC])
  doAssert capsuleWire.len > 2
  discard h3.ingestMasqueCapsuleData(77'u64, capsuleWire[0 .. 1])
  let noneYet = masque_client.recvCapsule(session)
  doAssert noneYet.payload.len == 0
  discard h3.ingestMasqueCapsuleData(77'u64, capsuleWire[2 .. ^1])
  let parsed = masque_client.recvCapsule(session)
  doAssert parsed.capsuleType == 0x2A'u64
  doAssert parsed.payload == @[0xAA'u8, 0xBB, 0xCC]
  echo "PASS: HTTP/3 MASQUE capsule buffering handles fragmented payloads"

block testHttp3MasqueCapsuleEgressByStream:
  let h3 = newHttp3Connection(isClient = false)
  let s1 = h3.registerMasqueUdpSession(81'u64, "proxy.example", "8.8.8.8:53")
  let s2 = h3.registerMasqueUdpSession(85'u64, "proxy.example", "1.1.1.1:53")
  masque_client.sendCapsule(s1, 0x10'u64, @[0x01'u8])
  masque_client.sendCapsule(s2, 0x11'u64, @[0x02'u8, 0x03])
  let queued = h3.popMasqueOutgoingCapsulesByStream()
  doAssert queued.len == 2
  var saw81 = false
  var saw85 = false
  for item in queued:
    doAssert item.capsules.len == 1
    if item.streamId == 81'u64:
      saw81 = true
      doAssert item.capsules[0].capsuleType == 0x10'u64
      doAssert item.capsules[0].payload == @[0x01'u8]
    elif item.streamId == 85'u64:
      saw85 = true
      doAssert item.capsules[0].capsuleType == 0x11'u64
      doAssert item.capsules[0].payload == @[0x02'u8, 0x03]
  doAssert saw81 and saw85
  echo "PASS: HTTP/3 MASQUE capsule egress preserves stream mapping"

block testMasqueIncomingQueueLimits:
  let session = runCps(masque_client.connectUdp("proxy.example", "8.8.8.8:53"))
  session.maxIncomingCapsules = 2
  session.maxIncomingCapsuleBytes = 5
  masque_shared.ingestCapsule(session, 1'u64, @[0x01'u8, 0x01])
  masque_shared.ingestCapsule(session, 2'u64, @[0x02'u8, 0x02])
  masque_shared.ingestCapsule(session, 3'u64, @[0x03'u8, 0x03])
  doAssert masque_shared.queuedIncomingCapsules(session) <= 2
  doAssert masque_shared.queuedIncomingCapsuleBytes(session) <= 5
  let c1 = masque_client.recvCapsule(session)
  let c2 = masque_client.recvCapsule(session)
  doAssert c1.capsuleType == 2'u64
  doAssert c2.capsuleType == 3'u64

  session.maxIncomingDatagrams = 2
  session.maxIncomingDatagramBytes = 4
  let ctx = masque_client.openDatagramContext(session, "dns")
  masque_shared.ingestDatagram(session, ctx, @[0x10'u8, 0x11])
  masque_shared.ingestDatagram(session, ctx, @[0x20'u8, 0x21])
  masque_shared.ingestDatagram(session, ctx, @[0x30'u8, 0x31])
  doAssert masque_shared.queuedIncomingDatagrams(session) <= 2
  doAssert masque_shared.queuedIncomingDatagramBytes(session) <= 4
  let d1 = masque_client.recvDatagram(session)
  let d2 = masque_client.recvDatagram(session)
  doAssert d1.payload == @[0x20'u8, 0x21]
  doAssert d2.payload == @[0x30'u8, 0x31]
  echo "PASS: MASQUE incoming queues are bounded"

block testMasqueCapsulePartialBufferLimit:
  let h3 = newHttp3Connection(isClient = false, maxMasqueCapsuleBufferBytes = 4)
  discard h3.registerMasqueUdpSession(93'u64, "proxy.example", "8.8.8.8:53")
  let capWire = masque_shared.encodeCapsuleWire(0x2A'u64, @[0xAA'u8, 0xBB, 0xCC])
  doAssert capWire.len > 4
  var overflowed = false
  try:
    discard h3.ingestMasqueCapsuleData(93'u64, capWire[0 .. 2])
    discard h3.ingestMasqueCapsuleData(93'u64, capWire[3 .. ^1])
  except ValueError:
    overflowed = true
  doAssert overflowed
  echo "PASS: MASQUE capsule partial-buffer growth is bounded"

block testMasqueConnectStreamRespondsBeforeFinAndRoutesCapsules:
  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "connected", @[("content-type", "text/plain")])

  let serverSession = h3_server.newHttp3ServerSession(@[0x03'u8], handler)
  let streamId = 4'u64
  let connectHeaders = masque_client.buildConnectUdpHeaders("proxy.example", "8.8.8.8:53")
  let connectFrames = serverSession.conn.submitRequest(connectHeaders, @[])
  let preFinResponse = runCps(serverSession.handleHttp3RequestFrames(
    streamId,
    connectFrames,
    streamEnded = false
  ))
  doAssert preFinResponse.len > 0
  doAssert serverSession.hasPendingRequestStream(streamId)
  doAssert serverSession.conn.hasMasqueSession(streamId)

  let capsuleFrame = encodeDataFrame(masque_shared.encodeCapsuleWire(0x44'u64, @[0xAB'u8]))
  let noExtraResponse = runCps(serverSession.handleHttp3RequestFrames(
    streamId,
    capsuleFrame,
    streamEnded = false
  ))
  doAssert noExtraResponse.len == 0
  let tunnelSession = serverSession.conn.masqueSessions[streamId]
  let capsule = masque_client.recvCapsule(tunnelSession)
  doAssert capsule.capsuleType == 0x44'u64
  doAssert capsule.payload == @[0xAB'u8]

  let closeFrames = runCps(serverSession.handleHttp3RequestFrames(
    streamId,
    @[],
    streamEnded = true
  ))
  doAssert closeFrames.len == 0
  doAssert not serverSession.hasPendingRequestStream(streamId)
  doAssert not serverSession.conn.hasMasqueSession(streamId)
  echo "PASS: MASQUE CONNECT responds before FIN and keeps stream open for capsules"

echo "All MASQUE capsule protocol tests passed"
