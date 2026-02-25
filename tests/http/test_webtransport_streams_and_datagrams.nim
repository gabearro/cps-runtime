## WebTransport stream/datagram behavior tests.

import cps
import cps/http/client/webtransport as wt_client
import cps/http/client/http3 as h3_client
import cps/http/server/http3 as h3_server
import cps/http/server/types
import cps/http/shared/webtransport as wt_shared
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

block testStreamOpeningSequence:
  let session = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  let b0 = wt_client.openBidiStream(session)
  let b1 = wt_client.openBidiStream(session)
  let u0 = wt_client.openUniStream(session)
  let u1 = wt_client.openUniStream(session)
  doAssert b1 == b0 + 4'u64
  doAssert u1 == u0 + 4'u64
  echo "PASS: WebTransport stream IDs advance by QUIC stream spacing"

block testStreamOpeningRejectsExhaustedIds:
  let clientSession = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  let maxClientBidi = QuicVarIntMax8 and not 0x03'u64
  clientSession.nextBidiStreamId = maxClientBidi
  doAssert wt_client.openBidiStream(clientSession) == maxClientBidi
  var bidiExhausted = false
  try:
    discard wt_client.openBidiStream(clientSession)
  except ValueError:
    bidiExhausted = true
  doAssert bidiExhausted

  let serverSession = wt_shared.acceptWebTransportSession(1'u64, "example.com", "/wt")
  serverSession.nextUniStreamId = QuicVarIntMax8
  doAssert wt_shared.openUniStream(serverSession) == QuicVarIntMax8
  var uniExhausted = false
  try:
    discard wt_shared.openUniStream(serverSession)
  except ValueError:
    uniExhausted = true
  doAssert uniExhausted
  echo "PASS: WebTransport stream opening rejects exhausted QUIC-varint IDs"

block testStreamOpeningRejectsInvalidStreamClassBits:
  let session = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  session.nextBidiStreamId = 2'u64
  var invalidBidi = false
  try:
    discard wt_client.openBidiStream(session)
  except ValueError:
    invalidBidi = true
  doAssert invalidBidi

  session.nextUniStreamId = 1'u64
  var invalidUni = false
  try:
    discard wt_client.openUniStream(session)
  except ValueError:
    invalidUni = true
  doAssert invalidUni
  echo "PASS: WebTransport stream opening rejects invalid initiator/direction bits"

block testDatagramSendRecv:
  let session = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  wt_client.sendDatagram(session, @[0x01'u8, 0x02, 0x03])
  doAssert session.outgoingDatagrams.len == 1
  wt_shared.ingestDatagram(session, @[0xAA'u8, 0xBB])
  let recv = wt_client.recvDatagram(session)
  doAssert recv == @[0xAA'u8, 0xBB]
  echo "PASS: WebTransport datagram send/recv path"

block testDatagramWireCodec:
  let wire = wt_shared.encodeWebTransportDatagram(17'u64, @[0x10'u8, 0x20, 0x30])
  let parsed = wt_shared.decodeWebTransportDatagram(wire)
  doAssert parsed.sessionId == 17'u64
  doAssert parsed.data == @[0x10'u8, 0x20, 0x30]

  let session = runCps(wt_client.openWebTransportSession("example.com", "/wt", sessionId = 17'u64))
  wt_client.sendDatagram(session, @[0xAB'u8])
  let pending = wt_shared.popOutgoingDatagrams(session)
  doAssert pending.len == 1
  doAssert pending[0] == @[0xAB'u8]
  echo "PASS: WebTransport datagram wire codec and queue draining"

block testHttp3DatagramRoutingForWebTransport:
  let h3 = newHttp3Connection(isClient = false)
  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  discard h3.ingestUniStreamData(2'u64, preface)
  let session = h3.registerWebTransportSession(21'u64, "example.com", "/wt")
  let wire = h3.encodeH3DatagramForWebTransport(21'u64, @[0x99'u8, 0x88])
  doAssert h3.ingestH3Datagram(wire)
  let recv = wt_shared.recvDatagram(session)
  doAssert recv == @[0x99'u8, 0x88]
  echo "PASS: HTTP/3 datagram routing into WebTransport session"

block testHttp3ClientSessionDatagramHelpersForWebTransport:
  let sender = h3_client.newHttp3ClientSession()
  let receiver = h3_client.newHttp3ClientSession()
  negotiateH3DatagramForClient(sender)
  negotiateH3DatagramForClient(receiver)
  let senderSession = sender.conn.registerWebTransportSession(55'u64, "example.com", "/wt")
  let receiverSession = receiver.conn.registerWebTransportSession(55'u64, "example.com", "/wt")
  wt_shared.sendDatagram(senderSession, @[0xC0'u8, 0xDE])
  let outgoing = h3_client.drainApplicationDatagrams(sender)
  doAssert outgoing.len == 1
  doAssert h3_client.ingestApplicationDatagram(receiver, outgoing[0])
  doAssert wt_shared.recvDatagram(receiverSession) == @[0xC0'u8, 0xDE]
  echo "PASS: HTTP/3 client session drains/ingests WebTransport datagrams"

block testHttp3ServerSessionDatagramRoutingForWebTransport:
  let serverSession = h3_server.newHttp3ServerSession(@[0x01'u8], nil)
  negotiateH3DatagramForServer(serverSession)
  let wt = serverSession.conn.registerWebTransportSession(77'u64, "example.com", "/wt")
  let incoming = serverSession.conn.encodeH3DatagramForWebTransport(77'u64, @[0x10'u8, 0x20])
  let routed = h3_server.routeH3Datagram(serverSession, incoming)
  doAssert routed.consumed
  doAssert wt_shared.recvDatagram(wt) == @[0x10'u8, 0x20]
  echo "PASS: HTTP/3 server session routes WebTransport datagrams"

block testWebTransportIncomingDatagramQueueLimits:
  let session = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  session.maxIncomingDatagrams = 2
  session.maxIncomingDatagramBytes = 4
  wt_shared.ingestDatagram(session, @[0x01'u8, 0x02])
  wt_shared.ingestDatagram(session, @[0x03'u8, 0x04])
  wt_shared.ingestDatagram(session, @[0x05'u8, 0x06])
  doAssert wt_shared.queuedIncomingDatagrams(session) <= 2
  doAssert wt_shared.queuedIncomingDatagramBytes(session) <= 4
  doAssert wt_client.recvDatagram(session) == @[0x03'u8, 0x04]
  doAssert wt_client.recvDatagram(session) == @[0x05'u8, 0x06]
  echo "PASS: WebTransport incoming datagram queue is bounded"

block testWebTransportConnectRespondsBeforeFinAndCleansUpOnClose:
  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "connected", @[("content-type", "text/plain")])

  let serverSession = h3_server.newHttp3ServerSession(@[0x04'u8], handler)
  let streamId = 4'u64
  let connectHeaders = wt_client.buildConnectHeaders("example.com", "/wt", origin = "https://app.example")
  let connectFrames = serverSession.conn.submitRequest(connectHeaders, @[])
  let preFinResponse = runCps(serverSession.handleHttp3RequestFrames(
    streamId,
    connectFrames,
    streamEnded = false
  ))
  doAssert preFinResponse.len > 0
  doAssert serverSession.hasPendingRequestStream(streamId)
  doAssert serverSession.conn.hasWebTransportSession(streamId)

  let closeFrames = runCps(serverSession.handleHttp3RequestFrames(
    streamId,
    @[],
    streamEnded = true
  ))
  doAssert closeFrames.len == 0
  doAssert not serverSession.hasPendingRequestStream(streamId)
  doAssert not serverSession.conn.hasWebTransportSession(streamId)
  echo "PASS: WebTransport CONNECT responds before FIN and cleans up on close"

block testWebTransportConnectRejectsDataFramesOnConnectStream:
  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return newResponse(200, "connected", @[("content-type", "text/plain")])

  let serverSession = h3_server.newHttp3ServerSession(@[0x05'u8], handler)
  let streamId = 4'u64
  let connectHeaders = wt_client.buildConnectHeaders("example.com", "/wt")
  let connectFrames = serverSession.conn.submitRequest(connectHeaders, @[])
  discard runCps(serverSession.handleHttp3RequestFrames(
    streamId,
    connectFrames,
    streamEnded = false
  ))
  doAssert serverSession.conn.hasWebTransportSession(streamId)

  var rejected = false
  try:
    let dataFrame = encodeDataFrame(@[0x01'u8])
    discard runCps(serverSession.handleHttp3RequestFrames(
      streamId,
      dataFrame,
      streamEnded = false
    ))
  except ValueError:
    rejected = true
  doAssert rejected
  doAssert not serverSession.conn.hasWebTransportSession(streamId)
  echo "PASS: WebTransport CONNECT stream rejects DATA frames"

echo "All WebTransport streams/datagrams tests passed"
