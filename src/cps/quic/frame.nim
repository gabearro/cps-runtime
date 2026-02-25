## QUIC frame codec.

import std/strutils
import ./varint
import ./types

const
  FramePadding* = 0x00'u8
  FramePing* = 0x01'u8
  FrameAck* = 0x02'u8
  FrameAckEcn* = 0x03'u8
  FrameResetStream* = 0x04'u8
  FrameStopSending* = 0x05'u8
  FrameCrypto* = 0x06'u8
  FrameNewToken* = 0x07'u8
  FrameStreamBase* = 0x08'u8
  FrameMaxData* = 0x10'u8
  FrameMaxStreamData* = 0x11'u8
  FrameMaxStreamsBidi* = 0x12'u8
  FrameMaxStreamsUni* = 0x13'u8
  FrameDataBlocked* = 0x14'u8
  FrameStreamDataBlocked* = 0x15'u8
  FrameStreamsBlockedBidi* = 0x16'u8
  FrameStreamsBlockedUni* = 0x17'u8
  FrameNewConnectionId* = 0x18'u8
  FrameRetireConnectionId* = 0x19'u8
  FramePathChallenge* = 0x1A'u8
  FramePathResponse* = 0x1B'u8
  FrameConnectionCloseTransport* = 0x1C'u8
  FrameConnectionCloseApplication* = 0x1D'u8
  FrameHandshakeDone* = 0x1E'u8
  FrameDatagramBase* = 0x30'u8

proc appendBytes(dst: var seq[byte], src: openArray[byte]) {.inline.} =
  if src.len > 0:
    dst.add src

proc sliceToSeq(data: openArray[byte], startIdx, endIdxExclusive: int): seq[byte] =
  let n = endIdxExclusive - startIdx
  if n <= 0:
    return @[]
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = data[startIdx + i]

proc parseReason(data: openArray[byte]): string =
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(data[i])

proc parsePathData(data: openArray[byte], offset: var int): array[8, byte] =
  if offset + 8 > data.len:
    raise newException(ValueError, "PATH frame truncated")
  for i in 0 ..< 8:
    result[i] = data[offset + i]
  offset += 8

proc parseFrame*(data: openArray[byte], offset: var int): QuicFrame =
  if offset >= data.len:
    raise newException(ValueError, "frame decode: truncated input")

  let t = data[offset]
  inc offset

  if t == FramePadding:
    while offset < data.len and data[offset] == FramePadding:
      inc offset
    return QuicFrame(kind: qfkPadding)

  if t == FramePing:
    return QuicFrame(kind: qfkPing)

  if t == FrameAck or t == FrameAckEcn:
    let largest = decodeQuicVarInt(data, offset)
    let ackDelay = decodeQuicVarInt(data, offset)
    let rangeCount = decodeQuicVarInt(data, offset)
    let firstRange = decodeQuicVarInt(data, offset)

    var ranges: seq[QuicAckRange]
    for _ in 0 ..< int(rangeCount):
      let gap = decodeQuicVarInt(data, offset)
      let rangeLen = decodeQuicVarInt(data, offset)
      ranges.add QuicAckRange(gap: gap, rangeLen: rangeLen)

    if t == FrameAckEcn:
      discard decodeQuicVarInt(data, offset)
      discard decodeQuicVarInt(data, offset)
      discard decodeQuicVarInt(data, offset)

    return QuicFrame(
      kind: qfkAck,
      largestAcked: largest,
      ackDelay: ackDelay,
      firstAckRange: firstRange,
      extraRanges: ranges
    )

  if t == FrameResetStream:
    return QuicFrame(
      kind: qfkResetStream,
      resetStreamId: decodeQuicVarInt(data, offset),
      resetErrorCode: decodeQuicVarInt(data, offset),
      resetFinalSize: decodeQuicVarInt(data, offset)
    )

  if t == FrameStopSending:
    return QuicFrame(
      kind: qfkStopSending,
      stopSendingStreamId: decodeQuicVarInt(data, offset),
      stopSendingErrorCode: decodeQuicVarInt(data, offset)
    )

  if t == FrameCrypto:
    let cryptoOffset = decodeQuicVarInt(data, offset)
    let cryptoLen = decodeQuicVarInt(data, offset)
    if offset + int(cryptoLen) > data.len:
      raise newException(ValueError, "CRYPTO frame truncated")
    let payload = sliceToSeq(data, offset, offset + int(cryptoLen))
    offset += int(cryptoLen)
    return QuicFrame(kind: qfkCrypto, cryptoOffset: cryptoOffset, cryptoData: payload)

  if t == FrameNewToken:
    let tokenLen = decodeQuicVarInt(data, offset)
    if offset + int(tokenLen) > data.len:
      raise newException(ValueError, "NEW_TOKEN frame truncated")
    let token = sliceToSeq(data, offset, offset + int(tokenLen))
    offset += int(tokenLen)
    return QuicFrame(kind: qfkNewToken, newToken: token)

  if (t and 0xF8'u8) == FrameStreamBase:
    let hasOff = (t and 0x04'u8) != 0
    let hasLen = (t and 0x02'u8) != 0
    let fin = (t and 0x01'u8) != 0

    let streamId = decodeQuicVarInt(data, offset)
    let streamOffset = if hasOff: decodeQuicVarInt(data, offset) else: 0'u64

    let payloadLen =
      if hasLen:
        let l = decodeQuicVarInt(data, offset)
        if offset + int(l) > data.len:
          raise newException(ValueError, "STREAM frame truncated")
        int(l)
      else:
        data.len - offset

    let payload = sliceToSeq(data, offset, offset + payloadLen)
    offset += payloadLen

    return QuicFrame(
      kind: qfkStream,
      streamId: streamId,
      streamOffset: streamOffset,
      streamFin: fin,
      streamData: payload
    )

  if t == FrameMaxData:
    return QuicFrame(kind: qfkMaxData, maxData: decodeQuicVarInt(data, offset))

  if t == FrameMaxStreamData:
    return QuicFrame(
      kind: qfkMaxStreamData,
      maxStreamDataStreamId: decodeQuicVarInt(data, offset),
      maxStreamData: decodeQuicVarInt(data, offset)
    )

  if t == FrameMaxStreamsBidi or t == FrameMaxStreamsUni:
    return QuicFrame(
      kind: qfkMaxStreams,
      maxStreamsBidi: t == FrameMaxStreamsBidi,
      maxStreams: decodeQuicVarInt(data, offset)
    )

  if t == FrameDataBlocked:
    return QuicFrame(kind: qfkDataBlocked, dataBlockedLimit: decodeQuicVarInt(data, offset))

  if t == FrameStreamDataBlocked:
    return QuicFrame(
      kind: qfkStreamDataBlocked,
      streamDataBlockedStreamId: decodeQuicVarInt(data, offset),
      streamDataBlockedLimit: decodeQuicVarInt(data, offset)
    )

  if t == FrameStreamsBlockedBidi or t == FrameStreamsBlockedUni:
    return QuicFrame(
      kind: qfkStreamsBlocked,
      streamsBlockedBidi: t == FrameStreamsBlockedBidi,
      streamsBlockedLimit: decodeQuicVarInt(data, offset)
    )

  if t == FrameNewConnectionId:
    let seqNum = decodeQuicVarInt(data, offset)
    let retirePriorTo = decodeQuicVarInt(data, offset)
    if offset >= data.len:
      raise newException(ValueError, "NEW_CONNECTION_ID frame missing CID length")
    let cidLen = int(data[offset])
    inc offset
    if cidLen < 1 or cidLen > 20:
      raise newException(ValueError, "NEW_CONNECTION_ID frame has invalid CID length")
    if offset + cidLen + 16 > data.len:
      raise newException(ValueError, "NEW_CONNECTION_ID frame truncated")
    let cid = sliceToSeq(data, offset, offset + cidLen)
    offset += cidLen
    var resetToken: array[16, byte]
    for i in 0 ..< 16:
      resetToken[i] = data[offset + i]
    offset += 16
    return QuicFrame(
      kind: qfkNewConnectionId,
      ncidSequence: seqNum,
      ncidRetirePriorTo: retirePriorTo,
      ncidConnectionId: cid,
      ncidResetToken: resetToken
    )

  if t == FrameRetireConnectionId:
    return QuicFrame(kind: qfkRetireConnectionId, retireCidSequence: decodeQuicVarInt(data, offset))

  if t == FramePathChallenge:
    return QuicFrame(kind: qfkPathChallenge, pathData: parsePathData(data, offset))

  if t == FramePathResponse:
    return QuicFrame(kind: qfkPathResponse, pathData: parsePathData(data, offset))

  if t == FrameConnectionCloseTransport or t == FrameConnectionCloseApplication:
    let errCode = decodeQuicVarInt(data, offset)
    let isApp = t == FrameConnectionCloseApplication
    let frameType = if isApp: 0'u64 else: decodeQuicVarInt(data, offset)
    let reasonLen = decodeQuicVarInt(data, offset)
    if offset + int(reasonLen) > data.len:
      raise newException(ValueError, "CONNECTION_CLOSE frame truncated")
    let reason = parseReason(sliceToSeq(data, offset, offset + int(reasonLen)))
    offset += int(reasonLen)
    return QuicFrame(
      kind: qfkConnectionClose,
      isApplicationClose: isApp,
      errorCode: errCode,
      frameType: frameType,
      reason: reason
    )

  if t == FrameHandshakeDone:
    return QuicFrame(kind: qfkHandshakeDone)

  if (t and 0xFE'u8) == FrameDatagramBase:
    let hasLen = (t and 0x01'u8) != 0
    let payloadLen =
      if hasLen:
        let l = decodeQuicVarInt(data, offset)
        if offset + int(l) > data.len:
          raise newException(ValueError, "DATAGRAM frame truncated")
        int(l)
      else:
        data.len - offset
    let payload = sliceToSeq(data, offset, offset + payloadLen)
    offset += payloadLen
    return QuicFrame(kind: qfkDatagram, datagramData: payload)

  raise newException(ValueError, "unsupported QUIC frame type: 0x" & toHex(t.int, 2))

proc encodeFrame*(frame: QuicFrame): seq[byte] =
  result = @[]
  case frame.kind
  of qfkPadding:
    result.add FramePadding
  of qfkPing:
    result.add FramePing
  of qfkAck:
    result.add FrameAck
    result.appendQuicVarInt(frame.largestAcked)
    result.appendQuicVarInt(frame.ackDelay)
    result.appendQuicVarInt(uint64(frame.extraRanges.len))
    result.appendQuicVarInt(frame.firstAckRange)
    for r in frame.extraRanges:
      result.appendQuicVarInt(r.gap)
      result.appendQuicVarInt(r.rangeLen)
  of qfkResetStream:
    result.add FrameResetStream
    result.appendQuicVarInt(frame.resetStreamId)
    result.appendQuicVarInt(frame.resetErrorCode)
    result.appendQuicVarInt(frame.resetFinalSize)
  of qfkStopSending:
    result.add FrameStopSending
    result.appendQuicVarInt(frame.stopSendingStreamId)
    result.appendQuicVarInt(frame.stopSendingErrorCode)
  of qfkCrypto:
    result.add FrameCrypto
    result.appendQuicVarInt(frame.cryptoOffset)
    result.appendQuicVarInt(uint64(frame.cryptoData.len))
    result.appendBytes(frame.cryptoData)
  of qfkNewToken:
    result.add FrameNewToken
    result.appendQuicVarInt(uint64(frame.newToken.len))
    result.appendBytes(frame.newToken)
  of qfkStream:
    var typ = FrameStreamBase
    if frame.streamOffset > 0:
      typ = typ or 0x04'u8
    typ = typ or 0x02'u8 # deterministic length encoding
    if frame.streamFin:
      typ = typ or 0x01'u8
    result.add typ
    result.appendQuicVarInt(frame.streamId)
    if frame.streamOffset > 0:
      result.appendQuicVarInt(frame.streamOffset)
    result.appendQuicVarInt(uint64(frame.streamData.len))
    result.appendBytes(frame.streamData)
  of qfkMaxData:
    result.add FrameMaxData
    result.appendQuicVarInt(frame.maxData)
  of qfkMaxStreamData:
    result.add FrameMaxStreamData
    result.appendQuicVarInt(frame.maxStreamDataStreamId)
    result.appendQuicVarInt(frame.maxStreamData)
  of qfkMaxStreams:
    result.add if frame.maxStreamsBidi: FrameMaxStreamsBidi else: FrameMaxStreamsUni
    result.appendQuicVarInt(frame.maxStreams)
  of qfkDataBlocked:
    result.add FrameDataBlocked
    result.appendQuicVarInt(frame.dataBlockedLimit)
  of qfkStreamDataBlocked:
    result.add FrameStreamDataBlocked
    result.appendQuicVarInt(frame.streamDataBlockedStreamId)
    result.appendQuicVarInt(frame.streamDataBlockedLimit)
  of qfkStreamsBlocked:
    result.add if frame.streamsBlockedBidi: FrameStreamsBlockedBidi else: FrameStreamsBlockedUni
    result.appendQuicVarInt(frame.streamsBlockedLimit)
  of qfkNewConnectionId:
    if frame.ncidConnectionId.len < 1 or frame.ncidConnectionId.len > 20:
      raise newException(ValueError, "NEW_CONNECTION_ID requires CID length in 1..20")
    result.add FrameNewConnectionId
    result.appendQuicVarInt(frame.ncidSequence)
    result.appendQuicVarInt(frame.ncidRetirePriorTo)
    result.add byte(frame.ncidConnectionId.len)
    result.appendBytes(frame.ncidConnectionId)
    for i in 0 ..< 16:
      result.add frame.ncidResetToken[i]
  of qfkRetireConnectionId:
    result.add FrameRetireConnectionId
    result.appendQuicVarInt(frame.retireCidSequence)
  of qfkPathChallenge:
    result.add FramePathChallenge
    for i in 0 ..< 8:
      result.add frame.pathData[i]
  of qfkPathResponse:
    result.add FramePathResponse
    for i in 0 ..< 8:
      result.add frame.pathData[i]
  of qfkConnectionClose:
    result.add if frame.isApplicationClose: FrameConnectionCloseApplication else: FrameConnectionCloseTransport
    result.appendQuicVarInt(frame.errorCode)
    if not frame.isApplicationClose:
      result.appendQuicVarInt(frame.frameType)
    result.appendQuicVarInt(uint64(frame.reason.len))
    for c in frame.reason:
      result.add byte(c)
  of qfkHandshakeDone:
    result.add FrameHandshakeDone
  of qfkDatagram:
    result.add (FrameDatagramBase or 0x01'u8)
    result.appendQuicVarInt(uint64(frame.datagramData.len))
    result.appendBytes(frame.datagramData)
