## QUIC transport parameters codec (RFC 9000 section 18).

import std/sets
import ./varint

const
  TpOriginalDestinationConnectionId* = 0x00'u64
  TpMaxIdleTimeout* = 0x01'u64
  TpStatelessResetToken* = 0x02'u64
  TpMaxUdpPayloadSize* = 0x03'u64
  TpInitialMaxData* = 0x04'u64
  TpInitialMaxStreamDataBidiLocal* = 0x05'u64
  TpInitialMaxStreamDataBidiRemote* = 0x06'u64
  TpInitialMaxStreamDataUni* = 0x07'u64
  TpInitialMaxStreamsBidi* = 0x08'u64
  TpInitialMaxStreamsUni* = 0x09'u64
  TpAckDelayExponent* = 0x0A'u64
  TpMaxAckDelay* = 0x0B'u64
  TpDisableActiveMigration* = 0x0C'u64
  TpPreferredAddress* = 0x0D'u64
  TpActiveConnectionIdLimit* = 0x0E'u64
  TpInitialSourceConnectionId* = 0x0F'u64
  TpRetrySourceConnectionId* = 0x10'u64
  TpMaxDatagramFrameSize* = 0x20'u64
  TpGreaseQuicBit* = 0x2AB2'u64

type
  QuicTransportParameters* = object
    maxIdleTimeout*: uint64
    maxUdpPayloadSize*: uint64
    initialMaxData*: uint64
    initialMaxStreamDataBidiLocal*: uint64
    initialMaxStreamDataBidiRemote*: uint64
    initialMaxStreamDataUni*: uint64
    initialMaxStreamsBidi*: uint64
    initialMaxStreamsUni*: uint64
    ackDelayExponent*: uint64
    maxAckDelay*: uint64
    activeConnectionIdLimit*: uint64
    maxDatagramFrameSize*: uint64
    disableActiveMigration*: bool
    greaseQuicBit*: bool
    originalDestinationConnectionId*: seq[byte]
    initialSourceConnectionId*: seq[byte]
    retrySourceConnectionId*: seq[byte]
    hasStatelessResetToken*: bool
    statelessResetToken*: array[16, byte]
    unknown*: seq[(uint64, seq[byte])]

proc defaultTransportParameters*(): QuicTransportParameters =
  QuicTransportParameters(
    maxIdleTimeout: 30_000'u64,
    maxUdpPayloadSize: 1200'u64,
    initialMaxData: 1024 * 1024'u64,
    initialMaxStreamDataBidiLocal: 256 * 1024'u64,
    initialMaxStreamDataBidiRemote: 256 * 1024'u64,
    initialMaxStreamDataUni: 256 * 1024'u64,
    initialMaxStreamsBidi: 100'u64,
    initialMaxStreamsUni: 100'u64,
    ackDelayExponent: 3'u64,
    maxAckDelay: 25'u64,
    activeConnectionIdLimit: 8'u64,
    maxDatagramFrameSize: 1200'u64,
    disableActiveMigration: false,
    greaseQuicBit: false,
    originalDestinationConnectionId: @[],
    initialSourceConnectionId: @[],
    retrySourceConnectionId: @[],
    hasStatelessResetToken: false,
    unknown: @[]
  )

proc appendParam(dst: var seq[byte], id: uint64, value: openArray[byte]) =
  dst.appendQuicVarInt(id)
  dst.appendQuicVarInt(uint64(value.len))
  if value.len > 0:
    dst.add value

proc encodeVarintParam(dst: var seq[byte], id: uint64, value: uint64) =
  let enc = encodeQuicVarInt(value)
  appendParam(dst, id, enc)

proc decodeParamVarint(paramData: openArray[byte]): uint64 =
  var off = 0
  let v = decodeQuicVarInt(paramData, off)
  if off != paramData.len:
    raise newException(ValueError, "transport parameter varint has trailing data")
  v

proc encodeTransportParameters*(tp: QuicTransportParameters): seq[byte] =
  result = @[]
  encodeVarintParam(result, TpMaxIdleTimeout, tp.maxIdleTimeout)
  encodeVarintParam(result, TpMaxUdpPayloadSize, tp.maxUdpPayloadSize)
  encodeVarintParam(result, TpInitialMaxData, tp.initialMaxData)
  encodeVarintParam(result, TpInitialMaxStreamDataBidiLocal, tp.initialMaxStreamDataBidiLocal)
  encodeVarintParam(result, TpInitialMaxStreamDataBidiRemote, tp.initialMaxStreamDataBidiRemote)
  encodeVarintParam(result, TpInitialMaxStreamDataUni, tp.initialMaxStreamDataUni)
  encodeVarintParam(result, TpInitialMaxStreamsBidi, tp.initialMaxStreamsBidi)
  encodeVarintParam(result, TpInitialMaxStreamsUni, tp.initialMaxStreamsUni)
  encodeVarintParam(result, TpAckDelayExponent, tp.ackDelayExponent)
  encodeVarintParam(result, TpMaxAckDelay, tp.maxAckDelay)
  encodeVarintParam(result, TpActiveConnectionIdLimit, tp.activeConnectionIdLimit)
  encodeVarintParam(result, TpMaxDatagramFrameSize, tp.maxDatagramFrameSize)

  if tp.disableActiveMigration:
    appendParam(result, TpDisableActiveMigration, @[])
  if tp.greaseQuicBit:
    appendParam(result, TpGreaseQuicBit, @[])
  if tp.originalDestinationConnectionId.len > 0:
    appendParam(result, TpOriginalDestinationConnectionId, tp.originalDestinationConnectionId)
  if tp.initialSourceConnectionId.len > 0:
    appendParam(result, TpInitialSourceConnectionId, tp.initialSourceConnectionId)
  if tp.retrySourceConnectionId.len > 0:
    appendParam(result, TpRetrySourceConnectionId, tp.retrySourceConnectionId)
  if tp.hasStatelessResetToken:
    var token = newSeq[byte](16)
    for i in 0 ..< 16:
      token[i] = tp.statelessResetToken[i]
    appendParam(result, TpStatelessResetToken, token)

  for (id, payload) in tp.unknown:
    appendParam(result, id, payload)

proc decodeTransportParameters*(data: openArray[byte]): QuicTransportParameters =
  result = defaultTransportParameters()
  var seen = initHashSet[uint64]()
  var off = 0
  while off < data.len:
    let id = decodeQuicVarInt(data, off)
    if id in seen:
      raise newException(ValueError, "duplicate transport parameter: " & $id)
    seen.incl(id)
    let paramLen = decodeQuicVarInt(data, off)
    if off + int(paramLen) > data.len:
      raise newException(ValueError, "transport parameters truncated")
    let pStart = off
    let pEnd = off + int(paramLen)
    off = pEnd

    case id
    of TpMaxIdleTimeout:
      result.maxIdleTimeout = decodeParamVarint(data[pStart ..< pEnd])
    of TpMaxUdpPayloadSize:
      result.maxUdpPayloadSize = decodeParamVarint(data[pStart ..< pEnd])
    of TpInitialMaxData:
      result.initialMaxData = decodeParamVarint(data[pStart ..< pEnd])
    of TpInitialMaxStreamDataBidiLocal:
      result.initialMaxStreamDataBidiLocal = decodeParamVarint(data[pStart ..< pEnd])
    of TpInitialMaxStreamDataBidiRemote:
      result.initialMaxStreamDataBidiRemote = decodeParamVarint(data[pStart ..< pEnd])
    of TpInitialMaxStreamDataUni:
      result.initialMaxStreamDataUni = decodeParamVarint(data[pStart ..< pEnd])
    of TpInitialMaxStreamsBidi:
      result.initialMaxStreamsBidi = decodeParamVarint(data[pStart ..< pEnd])
    of TpInitialMaxStreamsUni:
      result.initialMaxStreamsUni = decodeParamVarint(data[pStart ..< pEnd])
    of TpAckDelayExponent:
      result.ackDelayExponent = decodeParamVarint(data[pStart ..< pEnd])
    of TpMaxAckDelay:
      result.maxAckDelay = decodeParamVarint(data[pStart ..< pEnd])
    of TpActiveConnectionIdLimit:
      result.activeConnectionIdLimit = decodeParamVarint(data[pStart ..< pEnd])
    of TpMaxDatagramFrameSize:
      result.maxDatagramFrameSize = decodeParamVarint(data[pStart ..< pEnd])
    of TpDisableActiveMigration:
      if paramLen != 0'u64:
        raise newException(ValueError, "disable_active_migration must have zero-length value")
      result.disableActiveMigration = true
    of TpGreaseQuicBit:
      if paramLen != 0'u64:
        raise newException(ValueError, "grease_quic_bit must have zero-length value")
      result.greaseQuicBit = true
    of TpOriginalDestinationConnectionId:
      result.originalDestinationConnectionId = @[]
      if paramLen > 0:
        result.originalDestinationConnectionId.add data[pStart ..< pEnd]
    of TpInitialSourceConnectionId:
      result.initialSourceConnectionId = @[]
      if paramLen > 0:
        result.initialSourceConnectionId.add data[pStart ..< pEnd]
    of TpRetrySourceConnectionId:
      result.retrySourceConnectionId = @[]
      if paramLen > 0:
        result.retrySourceConnectionId.add data[pStart ..< pEnd]
    of TpStatelessResetToken:
      if paramLen != 16'u64:
        raise newException(ValueError, "stateless_reset_token must be 16 bytes")
      result.hasStatelessResetToken = true
      for i in 0 ..< 16:
        result.statelessResetToken[i] = data[pStart + i]
    else:
      var payload: seq[byte] = @[]
      if paramLen > 0:
        payload.add data[pStart ..< pEnd]
      result.unknown.add (id, payload)
