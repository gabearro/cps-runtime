## QUIC full frame codec coverage.

import cps/quic

proc samplePathData(v: byte): array[8, byte] =
  for i in 0 ..< 8:
    result[i] = v + byte(i)

block testFrameRoundTripAllKinds:
  var token16: array[16, byte]
  for i in 0 ..< 16:
    token16[i] = byte(i)

  let frames = @[
    QuicFrame(kind: qfkPadding),
    QuicFrame(kind: qfkPing),
    QuicFrame(kind: qfkAck, largestAcked: 10, ackDelay: 1, firstAckRange: 0, extraRanges: @[]),
    QuicFrame(kind: qfkResetStream, resetStreamId: 4, resetErrorCode: 1, resetFinalSize: 100),
    QuicFrame(kind: qfkStopSending, stopSendingStreamId: 4, stopSendingErrorCode: 2),
    QuicFrame(kind: qfkCrypto, cryptoOffset: 0, cryptoData: @[1'u8, 2, 3]),
    QuicFrame(kind: qfkNewToken, newToken: @[5'u8, 6, 7]),
    QuicFrame(kind: qfkStream, streamId: 8, streamOffset: 0, streamFin: true, streamData: @[9'u8, 10]),
    QuicFrame(kind: qfkMaxData, maxData: 4096),
    QuicFrame(kind: qfkMaxStreamData, maxStreamDataStreamId: 8, maxStreamData: 8192),
    QuicFrame(kind: qfkMaxStreams, maxStreamsBidi: true, maxStreams: 128),
    QuicFrame(kind: qfkDataBlocked, dataBlockedLimit: 12345),
    QuicFrame(kind: qfkStreamDataBlocked, streamDataBlockedStreamId: 8, streamDataBlockedLimit: 54321),
    QuicFrame(kind: qfkStreamsBlocked, streamsBlockedBidi: false, streamsBlockedLimit: 64),
    QuicFrame(kind: qfkNewConnectionId, ncidSequence: 1, ncidRetirePriorTo: 0, ncidConnectionId: @[11'u8, 12, 13], ncidResetToken: token16),
    QuicFrame(kind: qfkRetireConnectionId, retireCidSequence: 1),
    QuicFrame(kind: qfkPathChallenge, pathData: samplePathData(0x20)),
    QuicFrame(kind: qfkPathResponse, pathData: samplePathData(0x30)),
    QuicFrame(kind: qfkConnectionClose, isApplicationClose: false, errorCode: 0x0a, frameType: 0x08, reason: "close"),
    QuicFrame(kind: qfkConnectionClose, isApplicationClose: true, errorCode: 0x0b, frameType: 0, reason: "app-close"),
    QuicFrame(kind: qfkHandshakeDone),
    QuicFrame(kind: qfkDatagram, datagramData: @[0xAA'u8, 0xBB])
  ]

  for f in frames:
    let enc = encodeFrame(f)
    var off = 0
    let dec = parseFrame(enc, off)
    doAssert off == enc.len
    doAssert dec.kind == f.kind

  echo "PASS: QUIC full frame codec round-trip"

echo "All QUIC frame codec tests passed"
