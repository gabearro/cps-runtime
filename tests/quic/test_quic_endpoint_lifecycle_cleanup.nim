## QUIC endpoint lifecycle cleanup tests.
##
## Validates idle and draining cleanup paths driven by endpoint housekeeping.

import std/[times, tables]
import cps/runtime
import cps/eventloop
import cps/quic

proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
  discard loop.registerTimer(maxBlockMs, proc() = discard)
  loop.tick()

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 50_000): T =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tickBounded()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future to finish"
  doAssert not f.hasError(), "CPS future failed: " & f.getError().msg
  f.read()

proc runLoopFor(ms: int) =
  let loop = getEventLoop()
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    loop.tickBounded()

block testIdleConnectionCleanup:
  var cfg = defaultQuicEndpointConfig()
  cfg.quicIdleTimeoutMs = 50
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
  ep.start()
  discard runLoopUntilFinished(ep.connect("127.0.0.1", 9), maxTicks = 20_000)

  doAssert ep.connectionsByCid.len > 0
  runLoopFor(1_500)
  doAssert ep.connectionsByCid.len == 0
  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC endpoint idle-timeout cleanup removes stale connection mappings"

block testDrainingConnectionCleanup:
  var cfg = defaultQuicEndpointConfig()
  cfg.quicIdleTimeoutMs = 1_500
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
  ep.start()
  let conn = runLoopUntilFinished(ep.connect("127.0.0.1", 9), maxTicks = 300_000)

  doAssert ep.connectionsByCid.len > 0
  let staleMicros = int64(epochTime() * 1_000_000.0) - 5_000_000'i64
  conn.enterDraining(staleMicros)
  runLoopFor(600)
  doAssert ep.connectionsByCid.len == 0
  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC endpoint draining-timeout cleanup removes drained connections"

block testHousekeepingTriggersPtoWithoutInboundTraffic:
  when defined(useBoringSSL):
    var cfg = defaultQuicEndpointConfig()
    cfg.quicIdleTimeoutMs = 1_500
    cfg.quicUseRetry = false
    cfg.tlsVerifyPeer = false
    let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
    ep.start()
    let conn = runLoopUntilFinished(ep.connect("127.0.0.1", 65534), maxTicks = 200_000)
    conn.recovery.congestionWindow = conn.recovery.bytesInFlight
    let ptoBefore = conn.recovery.ptoCount
    runLoopFor(1_500)
    let ptoAfter = conn.recovery.ptoCount
    doAssert ptoAfter > 0 or ptoBefore > 0,
      "expected housekeeping to trigger at least one PTO probe without inbound traffic"
    ep.shutdown(closeSocket = true)
    echo "PASS: QUIC housekeeping triggers PTO probes without inbound datagrams"
  else:
    echo "SKIP: QUIC housekeeping PTO timer test requires -d:useBoringSSL"

block testAckOnlyFlushBypassesCwndGating:
  var cfg = defaultQuicEndpointConfig()
  cfg.quicIdleTimeoutMs = 2_000
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
  ep.start()

  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x31'u8, 0x32, 0x33, 0x34],
    peerConnId = @[0x41'u8, 0x42, 0x43, 0x44],
    peerAddress = "127.0.0.1",
    peerPort = 9,
    version = QuicVersion1
  )

  conn.onPacketReceived(
    QuicPacket(
      header: QuicPacketHeader(
        packetType: qptInitial,
        version: QuicVersion1,
        dstConnId: conn.localConnId,
        srcConnId: conn.peerConnId,
        token: @[],
        keyPhase: false,
        packetNumberLen: 2,
        payloadLen: 0
      ),
      packetNumber: 1'u64,
      frames: @[QuicFrame(kind: qfkPing)]
    ),
    peerAddress = "127.0.0.1",
    peerPort = 9
  )

  conn.recovery.congestionWindow = 0
  conn.recovery.bytesInFlight = 0
  let sentBefore = conn.datagramsSent
  let flushFut = ep.flushPendingControl(conn)
  let loop = getEventLoop()
  var flushTicks = 0
  while not flushFut.finished and flushTicks < 20_000:
    loop.tickBounded()
    inc flushTicks
  doAssert flushFut.finished, "Timed out waiting for ACK-only flush under full cwnd"
  doAssert not flushFut.hasError(), "ACK-only flush failed: " & flushFut.getError().msg
  doAssert conn.datagramsSent > sentBefore, "ack-only datagram should send even when cwnd is full"
  doAssert conn.recovery.bytesInFlight == 0, "ack-only packets must not increase bytes-in-flight"
  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC ACK-only datagrams are not blocked by cwnd gating"

block testAckPriorityOverStreamWhenCwndFull:
  var cfg = defaultQuicEndpointConfig()
  cfg.quicIdleTimeoutMs = 2_000
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
  ep.start()

  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x51'u8, 0x52, 0x53, 0x54],
    peerConnId = @[0x61'u8, 0x62, 0x63, 0x64],
    peerAddress = "127.0.0.1",
    peerPort = 9,
    version = QuicVersion1
  )
  var oneRttSecret = newSeq[byte](32)
  for i in 0 ..< oneRttSecret.len:
    oneRttSecret[i] = byte(i + 1)
  conn.setLevelWriteSecret(qelApplication, oneRttSecret)
  conn.state = qcsActive

  conn.onPacketReceived(
    QuicPacket(
      header: QuicPacketHeader(
        packetType: qptShort,
        version: 0'u32,
        dstConnId: conn.localConnId,
        srcConnId: conn.peerConnId,
        token: @[],
        keyPhase: false,
        packetNumberLen: 2,
        payloadLen: 0
      ),
      packetNumber: 3'u64,
      frames: @[QuicFrame(kind: qfkPing)]
    ),
    peerAddress = "127.0.0.1",
    peerPort = 9
  )

  let s = conn.getOrCreateStream(0'u64)
  s.appendSendData(@[0xAA'u8, 0xBB, 0xCC, 0xDD])

  conn.recovery.congestionWindow = 0
  conn.recovery.bytesInFlight = 0
  let sentBefore = conn.datagramsSent
  let firstFlush = ep.flushPendingControl(conn)
  let loop = getEventLoop()
  var ticks = 0
  while not firstFlush.finished and ticks < 20_000:
    loop.tickBounded()
    inc ticks
  doAssert firstFlush.finished, "Timed out waiting for first flush"
  doAssert not firstFlush.hasError(), "First flush failed: " & firstFlush.getError().msg
  doAssert conn.datagramsSent > sentBefore, "ACK should be sent even with cwnd full and stream queued"
  doAssert conn.recovery.bytesInFlight == 0, "ACK-first send should not consume bytes-in-flight"
  doAssert conn.outgoingDatagrams.len > 0, "stream packet should remain queued while cwnd is full"

  conn.recovery.congestionWindow = max(conn.recovery.maxDatagramSize * 10, 1200)
  let sentAfterAck = conn.datagramsSent
  let secondFlush = ep.flushPendingControl(conn)
  ticks = 0
  while not secondFlush.finished and ticks < 20_000:
    loop.tickBounded()
    inc ticks
  doAssert secondFlush.finished, "Timed out waiting for second flush"
  doAssert not secondFlush.hasError(), "Second flush failed: " & secondFlush.getError().msg
  doAssert conn.datagramsSent > sentAfterAck, "deferred stream packet should send once cwnd opens"
  doAssert conn.recovery.bytesInFlight > 0, "stream send should increase bytes-in-flight"
  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC ACKs are prioritized ahead of stream traffic under cwnd saturation"

block testDeferredDatagramsPrependAheadOfConcurrentQueueing:
  var cfg = defaultQuicEndpointConfig()
  cfg.quicIdleTimeoutMs = 2_000
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
  ep.start()

  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x71'u8, 0x72, 0x73, 0x74],
    peerConnId = @[0x81'u8, 0x82, 0x83, 0x84],
    peerAddress = "127.0.0.1",
    peerPort = 9,
    version = QuicVersion1
  )
  var oneRttSecret = newSeq[byte](32)
  for i in 0 ..< oneRttSecret.len:
    oneRttSecret[i] = byte(i + 7)
  conn.setLevelReadSecret(qelApplication, oneRttSecret)
  conn.setLevelWriteSecret(qelApplication, oneRttSecret)
  conn.handshakeState = qhsOneRtt
  conn.state = qcsActive

  let firstPayload = conn.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  let secondPayload = conn.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  conn.queueDatagramForSend(firstPayload)
  conn.queueDatagramForSend(secondPayload)

  conn.recovery.congestionWindow = firstPayload.len
  conn.recovery.bytesInFlight = 0
  conn.recovery.smoothedRttMicros = 5_000_000'i64

  let loop = getEventLoop()
  discard loop.registerTimer(1, proc() =
    let concurrentPayload = conn.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
    conn.queueDatagramForSend(concurrentPayload)
  )

  let flushFut = ep.flushPendingControl(conn)
  var ticks = 0
  while not flushFut.finished and ticks < 50_000:
    loop.tickBounded()
    inc ticks
  doAssert flushFut.finished, "Timed out waiting for deferred requeue ordering flush"
  doAssert not flushFut.hasError(), "Deferred requeue ordering flush failed: " & flushFut.getError().msg

  doAssert conn.outgoingDatagrams.len >= 2,
    "expected deferred + concurrently queued datagrams to remain pending"
  let firstQueuedPn = conn.decodeProtectedPacket(conn.outgoingDatagrams[0]).packetNumber
  doAssert firstQueuedPn in conn.sentPackets[2], "first queued packet number missing from sent-packet map"
  doAssert conn.sentPackets[2][firstQueuedPn].sentAtMicros == 0'i64,
    "first queued packet should still be unsent before notePacketActuallySent"
  conn.notePacketActuallySent()
  doAssert conn.sentPackets[2][firstQueuedPn].sentAtMicros > 0'i64,
    "first queued datagram must align with first pending send record"

  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC deferred datagrams stay ordered ahead of concurrently queued packets"

block testAckPreemptsExistingBlockedBacklog:
  var cfg = defaultQuicEndpointConfig()
  cfg.quicIdleTimeoutMs = 2_000
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0, config = cfg)
  ep.start()

  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x91'u8, 0x92, 0x93, 0x94],
    peerConnId = @[0xA1'u8, 0xA2, 0xA3, 0xA4],
    peerAddress = "127.0.0.1",
    peerPort = 9,
    version = QuicVersion1
  )
  var oneRttSecret = newSeq[byte](32)
  for i in 0 ..< oneRttSecret.len:
    oneRttSecret[i] = byte(i + 21)
  conn.setLevelReadSecret(qelApplication, oneRttSecret)
  conn.setLevelWriteSecret(qelApplication, oneRttSecret)
  conn.handshakeState = qhsOneRtt
  conn.state = qcsActive

  let blockedPayload = conn.encodeProtectedPacket(qptShort, @[
    QuicFrame(
      kind: qfkStream,
      streamId: 0'u64,
      streamOffset: 0'u64,
      streamFin: false,
      streamData: @[0x11'u8, 0x22, 0x33, 0x44]
    )
  ])
  conn.queueDatagramForSend(blockedPayload)
  conn.recovery.congestionWindow = 0
  conn.recovery.bytesInFlight = 0

  conn.onPacketReceived(
    QuicPacket(
      header: QuicPacketHeader(
        packetType: qptShort,
        version: 0'u32,
        dstConnId: conn.localConnId,
        srcConnId: conn.peerConnId,
        token: @[],
        keyPhase: false,
        packetNumberLen: 2,
        payloadLen: 0
      ),
      packetNumber: 7'u64,
      frames: @[QuicFrame(kind: qfkPing)]
    ),
    peerAddress = "127.0.0.1",
    peerPort = 9
  )

  let sentBefore = conn.datagramsSent
  let flushFut = ep.flushPendingControl(conn)
  let loop = getEventLoop()
  var ticks = 0
  while not flushFut.finished and ticks < 20_000:
    loop.tickBounded()
    inc ticks
  doAssert flushFut.finished, "Timed out waiting for ACK preemption over blocked backlog"
  doAssert not flushFut.hasError(), "ACK preemption flush failed: " & flushFut.getError().msg
  doAssert conn.datagramsSent > sentBefore, "ACK should send even with pre-existing blocked backlog"
  doAssert conn.outgoingDatagrams.len > 0, "blocked backlog should remain queued"
  let queuedFirst = conn.decodeProtectedPacket(conn.outgoingDatagrams[0])
  doAssert queuedFirst.frames.len > 0 and queuedFirst.frames[0].kind == qfkStream,
    "stream backlog should remain queued after ACK preemption send"

  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC ACK preempts existing cwnd-blocked backlog"

echo "All QUIC endpoint lifecycle cleanup tests passed"
