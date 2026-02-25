## QUIC stream state and flow-control helpers.

import std/tables

type
  QuicStreamDirection* = enum
    qsdBidirectional
    qsdUnidirectional

  QuicStreamEndpointRole* = enum
    qserClient
    qserServer

  QuicSendState* = enum
    qssReady
    qssSend
    qssDataSent
    qssDataRecvd
    qssResetSent
    qssResetRecvd

  QuicRecvState* = enum
    qrsRecv
    qrsSizeKnown
    qrsDataRecvd
    qrsResetRecvd

  QuicStream* = ref object
    id*: uint64
    direction*: QuicStreamDirection
    localInitiated*: bool
    sendState*: QuicSendState
    recvState*: QuicRecvState
    sendOffset*: uint64
    sendAckedOffset*: uint64
    recvOffset*: uint64
    sendFinalSizeKnown*: bool
    sendFinalSize*: uint64
    finalSizeKnown*: bool
    finalSize*: uint64
    sendWindowLimit*: uint64
    recvWindowLimit*: uint64
    sendBuffer*: seq[byte]
    recvBuffer*: seq[byte]
    recvOutOfOrder*: Table[uint64, seq[byte]]

proc isClientInitiatedStream*(streamId: uint64): bool {.inline.} =
  (streamId and 0x1'u64) == 0'u64

proc isBidirectionalStream*(streamId: uint64): bool {.inline.} =
  (streamId and 0x2'u64) == 0'u64

proc streamDirection*(streamId: uint64): QuicStreamDirection {.inline.} =
  if isBidirectionalStream(streamId): qsdBidirectional else: qsdUnidirectional

proc newQuicStream*(streamId: uint64,
                    localRole: QuicStreamEndpointRole,
                    sendWindowLimit: uint64 = 256 * 1024'u64,
                    recvWindowLimit: uint64 = 256 * 1024'u64): QuicStream =
  let initiatedByClient = isClientInitiatedStream(streamId)
  let localInitiated =
    (localRole == qserClient and initiatedByClient) or
    (localRole == qserServer and not initiatedByClient)
  QuicStream(
    id: streamId,
    direction: streamDirection(streamId),
    localInitiated: localInitiated,
    sendState: qssReady,
    recvState: qrsRecv,
    sendOffset: 0,
    sendAckedOffset: 0,
    recvOffset: 0,
    sendFinalSizeKnown: false,
    sendFinalSize: 0,
    finalSizeKnown: false,
    finalSize: 0,
    sendWindowLimit: sendWindowLimit,
    recvWindowLimit: recvWindowLimit,
    sendBuffer: @[],
    recvBuffer: @[],
    recvOutOfOrder: initTable[uint64, seq[byte]]()
  )

proc canSend*(s: QuicStream): bool =
  if s.direction == qsdBidirectional:
    return true
  s.localInitiated

proc canReceive*(s: QuicStream): bool =
  if s.direction == qsdBidirectional:
    return true
  not s.localInitiated

proc sendCreditRemaining*(s: QuicStream): uint64 =
  if s.sendOffset >= s.sendWindowLimit:
    return 0
  s.sendWindowLimit - s.sendOffset

proc recvCreditRemaining*(s: QuicStream): uint64 =
  if s.recvOffset >= s.recvWindowLimit:
    return 0
  s.recvWindowLimit - s.recvOffset

proc appendSendData*(s: QuicStream, data: openArray[byte]) =
  if not s.canSend():
    raise newException(ValueError, "stream is receive-only for local endpoint")
  if data.len > 0:
    s.sendBuffer.add data
    if s.sendState == qssReady:
      s.sendState = qssSend

proc nextSendChunk*(s: QuicStream, maxLen: int): tuple[offset: uint64, payload: seq[byte], fin: bool] =
  if maxLen <= 0:
    return (offset: s.sendOffset, payload: @[], fin: false)
  if s.sendBuffer.len == 0:
    return (offset: s.sendOffset, payload: @[], fin: false)

  let allowedByFc = int(min(uint64(maxLen), s.sendCreditRemaining()))
  if allowedByFc <= 0:
    return (offset: s.sendOffset, payload: @[], fin: false)

  let n = min(allowedByFc, s.sendBuffer.len)
  result.offset = s.sendOffset
  result.payload = newSeq[byte](n)
  for i in 0 ..< n:
    result.payload[i] = s.sendBuffer[i]
  if n >= s.sendBuffer.len:
    s.sendBuffer.setLen(0)
  else:
    s.sendBuffer = s.sendBuffer[n .. ^1]
  s.sendOffset += uint64(n)
  result.fin = false
  if s.sendBuffer.len == 0 and s.sendFinalSizeKnown and s.sendOffset == s.sendFinalSize:
    result.fin = true
    s.sendState = qssDataSent

proc markFinPlanned*(s: QuicStream) =
  s.sendFinalSizeKnown = true
  s.sendFinalSize = s.sendOffset + uint64(s.sendBuffer.len)

proc markSendAcked*(s: QuicStream, ackedOffsetExclusive: uint64) =
  if ackedOffsetExclusive > s.sendAckedOffset:
    s.sendAckedOffset = min(ackedOffsetExclusive, s.sendOffset)
  if s.sendFinalSizeKnown and s.sendAckedOffset >= s.sendFinalSize:
    s.sendState = qssDataRecvd

proc pushRecvData*(s: QuicStream, offset: uint64, payload: openArray[byte], fin: bool) =
  if not s.canReceive():
    raise newException(ValueError, "stream is send-only for local endpoint")
  let endOffset = offset + uint64(payload.len)
  if s.finalSizeKnown:
    if offset > s.finalSize or endOffset > s.finalSize:
      raise newException(ValueError, "stream data exceeds known final size")
    if fin and endOffset != s.finalSize:
      raise newException(
        ValueError,
        "stream final size changed (pre): id=" & $s.id &
          " offset=" & $offset & " end=" & $endOffset & " known=" & $s.finalSize
      )
  if endOffset > s.recvWindowLimit:
    raise newException(ValueError, "stream flow-control window exceeded")

  if payload.len > 0:
    if offset < s.recvOffset:
      let alreadyConsumed = s.recvOffset - offset
      if alreadyConsumed < uint64(payload.len):
        let start = int(alreadyConsumed)
        s.recvBuffer.add payload[start ..< payload.len]
        s.recvOffset += uint64(payload.len - start)
    elif offset == s.recvOffset:
      s.recvBuffer.add payload
      s.recvOffset += uint64(payload.len)
    else:
      if offset notin s.recvOutOfOrder:
        s.recvOutOfOrder[offset] = @payload

  var advanced = true
  while advanced:
    advanced = false
    if s.recvOffset in s.recvOutOfOrder:
      let chunk = s.recvOutOfOrder[s.recvOffset]
      s.recvOutOfOrder.del(s.recvOffset)
      if chunk.len > 0:
        s.recvBuffer.add chunk
        s.recvOffset += uint64(chunk.len)
      advanced = true

  if fin:
    if s.finalSizeKnown and s.finalSize != endOffset:
      raise newException(
        ValueError,
        "stream final size changed (fin): id=" & $s.id &
          " offset=" & $offset & " end=" & $endOffset & " known=" & $s.finalSize
      )
    s.finalSizeKnown = true
    s.finalSize = endOffset
    if s.recvBuffer.len == 0 and s.recvOutOfOrder.len == 0 and s.recvOffset == s.finalSize:
      s.recvState = qrsDataRecvd
    else:
      s.recvState = qrsSizeKnown

proc popRecvData*(s: QuicStream, maxLen: int): seq[byte] =
  if maxLen <= 0 or s.recvBuffer.len == 0:
    return @[]
  let n = min(maxLen, s.recvBuffer.len)
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = s.recvBuffer[i]
  if n >= s.recvBuffer.len:
    s.recvBuffer.setLen(0)
  else:
    s.recvBuffer = s.recvBuffer[n .. ^1]
  if s.recvBuffer.len == 0 and s.recvOutOfOrder.len == 0 and s.finalSizeKnown and s.recvOffset == s.finalSize:
    s.recvState = qrsDataRecvd

proc updateSendWindowLimit*(s: QuicStream, newLimit: uint64) =
  s.sendWindowLimit = max(s.sendWindowLimit, newLimit)

proc clampSendWindowLimit*(s: QuicStream, newLimit: uint64) =
  ## Clamp send credit to a new absolute limit (used when peer transport
  ## parameters become known). Never shrink below already-sent bytes.
  s.sendWindowLimit = max(s.sendOffset, newLimit)

proc updateRecvWindowLimit*(s: QuicStream, newLimit: uint64) =
  s.recvWindowLimit = max(s.recvWindowLimit, newLimit)
