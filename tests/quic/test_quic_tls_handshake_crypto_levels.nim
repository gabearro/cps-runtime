## QUIC CRYPTO stream buffering and handshake-level frame handling tests.

import cps/quic

proc asBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(ord(c) and 0xFF)

proc sizedBytes(n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(i and 0xFF)

proc bytesEq(a, b: openArray[byte]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

block testCryptoReceiveReassemblyByLevel:
  let conn = newQuicConnection(qcrServer, @[0x01'u8], @[0x02'u8], "127.0.0.1", 4433)
  conn.applyReceivedFrame(
    QuicFrame(kind: qfkCrypto, cryptoOffset: 5'u64, cryptoData: asBytes("world")),
    qpnsInitial
  )
  doAssert conn.takeCryptoData(qelInitial).len == 0

  conn.applyReceivedFrame(
    QuicFrame(kind: qfkCrypto, cryptoOffset: 0'u64, cryptoData: asBytes("hello")),
    qpnsInitial
  )
  let merged = conn.takeCryptoData(qelInitial)
  doAssert bytesEq(merged, asBytes("helloworld"))
  doAssert conn.takeCryptoData(qelInitial).len == 0
  echo "PASS: QUIC CRYPTO receive reassembly by encryption level"

block testCryptoSendChunkingAndOffsets:
  let conn = newQuicConnection(qcrClient, @[0x11'u8], @[0x22'u8], "127.0.0.1", 4433)
  conn.queueCryptoData(qelHandshake, asBytes("abcdefghi"))
  let frames = conn.drainCryptoFrames(qelHandshake, maxFrameData = 4)
  doAssert frames.len == 3
  doAssert frames[0].kind == qfkCrypto and frames[0].cryptoOffset == 0'u64
  doAssert frames[1].kind == qfkCrypto and frames[1].cryptoOffset == 4'u64
  doAssert frames[2].kind == qfkCrypto and frames[2].cryptoOffset == 8'u64
  doAssert bytesEq(frames[0].cryptoData, asBytes("abcd"))
  doAssert bytesEq(frames[1].cryptoData, asBytes("efgh"))
  doAssert bytesEq(frames[2].cryptoData, asBytes("i"))
  doAssert conn.drainCryptoFrames(qelHandshake, maxFrameData = 4).len == 0
  echo "PASS: QUIC CRYPTO send chunking preserves offsets"

block testTransportFrameLifecycleHooks:
  let conn = newQuicConnection(qcrClient, @[0xAA'u8], @[0xBB'u8], "127.0.0.1", 4433)

  conn.applyReceivedFrame(QuicFrame(kind: qfkNewToken, newToken: asBytes("token-1")), qpnsApplication)
  let tokens = conn.popPeerTokens()
  doAssert tokens.len == 1
  doAssert bytesEq(tokens[0], asBytes("token-1"))
  doAssert conn.popPeerTokens().len == 0

  var resetToken: array[16, byte]
  for i in 0 ..< 16:
    resetToken[i] = byte(i)
  let newCid = @[0x10'u8, 0x20, 0x30, 0x40]
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkNewConnectionId,
      ncidSequence: 7'u64,
      ncidRetirePriorTo: 0'u64,
      ncidConnectionId: newCid,
      ncidResetToken: resetToken
    ),
    qpnsApplication
  )
  doAssert bytesEq(conn.peerConnectionIdForSequence(7'u64), newCid)
  doAssert bytesEq(conn.peerConnId, newCid)

  conn.applyReceivedFrame(QuicFrame(kind: qfkRetireConnectionId, retireCidSequence: 7'u64), qpnsApplication)
  doAssert conn.isPeerConnectionIdRetired(7'u64)

  conn.state = qcsHandshaking
  conn.applyReceivedFrame(QuicFrame(kind: qfkHandshakeDone), qpnsApplication)
  doAssert conn.state == qcsActive
  doAssert conn.handshakeState == qhsOneRtt
  echo "PASS: QUIC NEW_TOKEN/NEW_CONNECTION_ID/RETIRE/HANDSHAKE_DONE frame handling"

block testNewTokenDirectionAndSpaceValidation:
  let server = newQuicConnection(qcrServer, @[0xAB'u8], @[0xBC'u8], "127.0.0.1", 4433)
  server.applyReceivedFrame(QuicFrame(kind: qfkNewToken, newToken: asBytes("bad")), qpnsApplication)
  doAssert server.state == qcsDraining
  doAssert server.closeErrorCode == 0x0A'u64
  doAssert server.popPeerTokens().len == 0

  let client = newQuicConnection(qcrClient, @[0xAD'u8], @[0xBE'u8], "127.0.0.1", 4433)
  client.applyReceivedFrame(QuicFrame(kind: qfkNewToken, newToken: asBytes("bad")), qpnsHandshake)
  doAssert client.state == qcsDraining
  doAssert client.closeErrorCode == 0x0A'u64
  doAssert client.popPeerTokens().len == 0
  echo "PASS: QUIC NEW_TOKEN enforces direction and packet-space legality"

block testHandshakeDoneDirectionAndSpaceValidation:
  let server = newQuicConnection(qcrServer, @[0xAF'u8], @[0xC0'u8], "127.0.0.1", 4433)
  server.applyReceivedFrame(QuicFrame(kind: qfkHandshakeDone), qpnsApplication)
  doAssert server.state == qcsDraining
  doAssert server.closeErrorCode == 0x0A'u64

  let client = newQuicConnection(qcrClient, @[0xB1'u8], @[0xC2'u8], "127.0.0.1", 4433)
  client.applyReceivedFrame(QuicFrame(kind: qfkHandshakeDone), qpnsHandshake)
  doAssert client.state == qcsDraining
  doAssert client.closeErrorCode == 0x0A'u64
  echo "PASS: QUIC HANDSHAKE_DONE enforces direction and packet-space legality"

block testOneRttOnlyFramesRejectedOutsideApplicationSpace:
  let conn = newQuicConnection(qcrClient, @[0xB2'u8], @[0xC3'u8], "127.0.0.1", 4433)
  let beforeMaxData = conn.localTransportParameters.initialMaxData
  conn.applyReceivedFrame(
    QuicFrame(kind: qfkMaxData, maxData: beforeMaxData + 100'u64),
    qpnsHandshake
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  doAssert conn.localTransportParameters.initialMaxData == beforeMaxData

  let conn2 = newQuicConnection(qcrClient, @[0xB4'u8], @[0xC5'u8], "127.0.0.1", 4433)
  var resetToken: array[16, byte]
  conn2.applyReceivedFrame(
    QuicFrame(
      kind: qfkNewConnectionId,
      ncidSequence: 1'u64,
      ncidRetirePriorTo: 0'u64,
      ncidConnectionId: @[0xAA'u8],
      ncidResetToken: resetToken
    ),
    qpnsInitial
  )
  doAssert conn2.state == qcsDraining
  doAssert conn2.closeErrorCode == 0x0A'u64
  doAssert conn2.peerConnectionIdForSequence(1'u64).len == 0
  echo "PASS: QUIC 1-RTT-only frames rejected outside application packet space"

block testCryptoFrameRejectedInApplicationSpace:
  let conn = newQuicConnection(qcrClient, @[0xB3'u8], @[0xC4'u8], "127.0.0.1", 4433)
  conn.applyReceivedFrame(
    QuicFrame(kind: qfkCrypto, cryptoOffset: 0'u64, cryptoData: asBytes("x")),
    qpnsApplication
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  doAssert conn.takeCryptoData(qelApplication).len == 0
  echo "PASS: QUIC rejects CRYPTO frames in application packet space"

block testApplicationConnectionCloseRejectedOutsideApplicationSpace:
  let conn = newQuicConnection(qcrServer, @[0xB5'u8], @[0xC6'u8], "127.0.0.1", 4433)
  conn.onPacketReceived(
    QuicPacket(
      header: QuicPacketHeader(packetType: qptInitial),
      packetNumber: 1'u64,
      frames: @[
        QuicFrame(
          kind: qfkConnectionClose,
          isApplicationClose: true,
          errorCode: 42'u64,
          frameType: 0'u64,
          reason: "bad"
        )
      ]
    )
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  echo "PASS: QUIC rejects application CONNECTION_CLOSE outside application packet space"

block testCryptoBufferLimitTriggersClose:
  let conn = newQuicConnection(qcrServer, @[0xC1'u8], @[0xD1'u8], "127.0.0.1", 4433)
  let oversize = sizedBytes(QuicMaxCryptoBufferPerLevelBytes + 1024)
  conn.applyReceivedFrame(
    QuicFrame(kind: qfkCrypto, cryptoOffset: 0'u64, cryptoData: oversize),
    qpnsInitial
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0D'u64
  doAssert conn.closeReason.len > 0
  doAssert conn.takeCryptoData(qelInitial).len == 0
  echo "PASS: QUIC CRYPTO buffer limit triggers CRYPTO_BUFFER_EXCEEDED close"

echo "All QUIC TLS/CRYPTO level tests passed"
