## QUIC path rebinding/migration accounting tests.

import cps/quic
import cps/runtime
import cps/eventloop

proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
  discard loop.registerTimer(maxBlockMs, proc() = discard)
  loop.tick()

proc runLoopUntilFinished(f: CpsVoidFuture, maxTicks: int = 5_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tickBounded()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS void future to finish"

block testPerPathAmplificationAccounting:
  var pm = initPathManager("127.0.0.1", 4433)
  let idx = pm.ensurePath("127.0.0.2", 4434)
  doAssert idx >= 0
  doAssert not pm.paths[idx].addressValidated

  pm.noteDatagramReceived("127.0.0.2", 4434, 100)
  doAssert pm.canSendToPath("127.0.0.2", 4434, 300, enforceAmplification = true)
  doAssert not pm.canSendToPath("127.0.0.2", 4434, 301, enforceAmplification = true)

  discard pm.beginValidation("127.0.0.2", 4434)
  let challenge = pm.paths[idx].challengeData
  doAssert pm.onPathResponse("127.0.0.2", 4434, challenge)
  doAssert pm.paths[idx].addressValidated
  doAssert pm.canSendToPath("127.0.0.2", 4434, 8_192, enforceAmplification = true)
  echo "PASS: QUIC per-path anti-amplification and validation"

block testConnectionPathAwareReceiveAccounting:
  let conn = newQuicConnection(
    role = qcrServer,
    localConnId = @[0xAA'u8, 0xBB, 0xCC, 0xDD],
    peerConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.noteDatagramReceived(128, peerAddress = "127.0.0.9", peerPort = 9443)
  let idx = conn.pathManager.ensurePath("127.0.0.9", 9443)
  doAssert conn.pathManager.paths[idx].bytesReceived == 128'u64
  echo "PASS: QUIC connection receive accounting updates candidate path state"

block testShortPacketDoesNotAutoValidateNewPath:
  let conn = newQuicConnection(
    role = qcrServer,
    localConnId = @[0xAA'u8, 0xBB, 0xCC, 0xDD],
    peerConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.handshakeState = qhsOneRtt
  conn.state = qcsActive
  conn.pathManager.markPathValidated("127.0.0.1", 4433)

  let active = conn.pathManager.activePath()
  doAssert active.validationState == qpvsValidated

  let candidateAddress = "127.0.0.77"
  let candidatePort = 9443
  discard conn.pathManager.beginValidation(candidateAddress, candidatePort)

  let shortPacket = QuicPacket(
    header: QuicPacketHeader(packetType: qptShort),
    packetNumber: 1'u64,
    frames: @[]
  )
  conn.onPacketReceived(shortPacket, peerAddress = candidateAddress, peerPort = candidatePort)

  let candidateIdx = conn.pathManager.ensurePath(candidateAddress, candidatePort)
  doAssert conn.pathManager.paths[candidateIdx].validationState == qpvsChallenging
  doAssert not conn.pathManager.paths[candidateIdx].addressValidated
  doAssert conn.pathManager.activePath().peerAddress == active.peerAddress
  doAssert conn.pathManager.activePath().peerPort == active.peerPort
  echo "PASS: QUIC short packet does not auto-validate migration candidate path"

block testPerPathAmplificationStillAppliesAfterConnectionValidation:
  let conn = newQuicConnection(
    role = qcrServer,
    localConnId = @[0xAA'u8, 0xBB, 0xCC, 0xDD],
    peerConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.addressValidated = true
  conn.pathManager.markPathValidated("127.0.0.1", 4433)

  let candidateAddress = "127.0.0.88"
  let candidatePort = 9555
  conn.noteDatagramReceived(100, peerAddress = candidateAddress, peerPort = candidatePort)
  doAssert conn.canSendOnPath(candidateAddress, candidatePort, 300)
  doAssert not conn.canSendOnPath(candidateAddress, candidatePort, 301)
  echo "PASS: QUIC per-path amplification enforced even after connection validation"

block testUpdatePathUsesTrackedSendPipeline:
  let ep = newQuicClientEndpoint(bindHost = "127.0.0.1", bindPort = 0)
  ep.start()
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x10'u8, 0x11, 0x12, 0x13],
    peerConnId = @[0x20'u8, 0x21, 0x22, 0x23],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.setLevelWriteSecret(qelApplication, @[byte(0xA5), 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
                                             0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
                                             0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
                                             0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5])
  conn.state = qcsActive
  doAssert conn.canEncodePacketType(qptShort)
  doAssert conn.recovery.bytesInFlight == 0
  doAssert conn.sendPacketNumber[2] == 0

  let f = ep.updatePath(conn, "127.0.0.9", 9443)
  runLoopUntilFinished(f)

  doAssert conn.sendPacketNumber[2] > 0
  doAssert conn.recovery.bytesInFlight > 0
  doAssert conn.datagramsSent > 0
  ep.shutdown(closeSocket = true)
  echo "PASS: QUIC updatePath path-challenge is tracked by recovery/send accounting"

echo "All QUIC path rebinding/migration tests passed"
