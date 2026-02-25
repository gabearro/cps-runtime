## QUIC wire-level shared types.

type
  QuicEncryptionLevel* = enum
    qelInitial
    qelHandshake
    qelApplication

  QuicPacketType* = enum
    qptVersionNegotiation
    qptInitial
    qpt0Rtt
    qptHandshake
    qptRetry
    qptShort

  QuicPacketNumberSpace* = enum
    qpnsInitial
    qpnsHandshake
    qpnsApplication

  QuicAckRange* = object
    gap*: uint64
    rangeLen*: uint64

  QuicFrameKind* = enum
    qfkPadding
    qfkPing
    qfkAck
    qfkResetStream
    qfkStopSending
    qfkCrypto
    qfkNewToken
    qfkStream
    qfkMaxData
    qfkMaxStreamData
    qfkMaxStreams
    qfkDataBlocked
    qfkStreamDataBlocked
    qfkStreamsBlocked
    qfkNewConnectionId
    qfkRetireConnectionId
    qfkPathChallenge
    qfkPathResponse
    qfkConnectionClose
    qfkHandshakeDone
    qfkDatagram

  QuicFrame* = object
    case kind*: QuicFrameKind
    of qfkPadding, qfkPing:
      discard
    of qfkAck:
      largestAcked*: uint64
      ackDelay*: uint64
      firstAckRange*: uint64
      extraRanges*: seq[QuicAckRange]
    of qfkResetStream:
      resetStreamId*: uint64
      resetErrorCode*: uint64
      resetFinalSize*: uint64
    of qfkStopSending:
      stopSendingStreamId*: uint64
      stopSendingErrorCode*: uint64
    of qfkCrypto:
      cryptoOffset*: uint64
      cryptoData*: seq[byte]
    of qfkNewToken:
      newToken*: seq[byte]
    of qfkStream:
      streamId*: uint64
      streamOffset*: uint64
      streamFin*: bool
      streamData*: seq[byte]
    of qfkMaxData:
      maxData*: uint64
    of qfkMaxStreamData:
      maxStreamDataStreamId*: uint64
      maxStreamData*: uint64
    of qfkMaxStreams:
      maxStreamsBidi*: bool
      maxStreams*: uint64
    of qfkDataBlocked:
      dataBlockedLimit*: uint64
    of qfkStreamDataBlocked:
      streamDataBlockedStreamId*: uint64
      streamDataBlockedLimit*: uint64
    of qfkStreamsBlocked:
      streamsBlockedBidi*: bool
      streamsBlockedLimit*: uint64
    of qfkNewConnectionId:
      ncidSequence*: uint64
      ncidRetirePriorTo*: uint64
      ncidConnectionId*: seq[byte]
      ncidResetToken*: array[16, byte]
    of qfkRetireConnectionId:
      retireCidSequence*: uint64
    of qfkPathChallenge, qfkPathResponse:
      pathData*: array[8, byte]
    of qfkConnectionClose:
      isApplicationClose*: bool
      errorCode*: uint64
      frameType*: uint64
      reason*: string
    of qfkHandshakeDone:
      discard
    of qfkDatagram:
      datagramData*: seq[byte]

  QuicPacketHeader* = object
    packetType*: QuicPacketType
    version*: uint32
    dstConnId*: seq[byte]
    srcConnId*: seq[byte]
    token*: seq[byte]     ## Initial/Retry only
    keyPhase*: bool       ## Short header only
    packetNumberLen*: int ## 1..4
    payloadLen*: int      ## long-header payload length (including PN); -1 if unknown

  QuicPacket* = object
    header*: QuicPacketHeader
    packetNumber*: uint64
    frames*: seq[QuicFrame]
