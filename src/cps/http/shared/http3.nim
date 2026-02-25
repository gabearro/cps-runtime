## HTTP/3 frame codec (RFC 9114) built on QUIC varints.

import std/[strutils, sets]
import ../../quic/varint

const
  H3FrameData* = 0x00'u64
  H3FrameHeaders* = 0x01'u64
  H3FrameCancelPush* = 0x03'u64
  H3FrameSettings* = 0x04'u64
  H3FramePushPromise* = 0x05'u64
  H3FrameGoaway* = 0x07'u64
  H3FrameMaxPushId* = 0x0D'u64

  H3UniControlStream* = 0x00'u64
  H3UniPushStream* = 0x01'u64
  H3UniQpackEncoderStream* = 0x02'u64
  H3UniQpackDecoderStream* = 0x03'u64

  H3SettingQpackMaxTableCapacity* = 0x01'u64
  H3SettingMaxFieldSectionSize* = 0x06'u64
  H3SettingQpackBlockedStreams* = 0x07'u64
  H3SettingEnableConnectProtocol* = 0x08'u64
  H3SettingH3Datagram* = 0x33'u64

  H3ErrNoError* = 0x0100'u64
  H3ErrGeneralProtocol* = 0x0101'u64
  H3ErrInternal* = 0x0102'u64
  H3ErrStreamCreation* = 0x0103'u64
  H3ErrClosedCriticalStream* = 0x0104'u64
  H3ErrFrameUnexpected* = 0x0105'u64
  H3ErrFrameError* = 0x0106'u64
  H3ErrExcessiveLoad* = 0x0107'u64
  H3ErrIdError* = 0x0108'u64
  H3ErrSettingsError* = 0x0109'u64
  H3ErrMissingSettings* = 0x010A'u64
  H3ErrRequestRejected* = 0x010B'u64
  H3ErrRequestCancelled* = 0x010C'u64
  H3ErrRequestIncomplete* = 0x010D'u64
  H3ErrMessageError* = 0x010E'u64
  H3ErrConnectError* = 0x010F'u64
  H3ErrVersionFallback* = 0x0110'u64

  QpackErrDecompressionFailed* = 0x0200'u64
  QpackErrEncoderStream* = 0x0201'u64
  QpackErrDecoderStream* = 0x0202'u64


type
  Http3Frame* = object
    frameType*: uint64
    payload*: seq[byte]

proc appendBytes(dst: var seq[byte], src: openArray[byte]) {.inline.} =
  if src.len > 0:
    dst.add src

proc encodeHttp3Frame*(frameType: uint64, payload: openArray[byte]): seq[byte] =
  result = @[]
  result.appendQuicVarInt(frameType)
  result.appendQuicVarInt(uint64(payload.len))
  result.appendBytes(payload)

proc encodeHttp3Frame*(frame: Http3Frame): seq[byte] =
  encodeHttp3Frame(frame.frameType, frame.payload)

proc decodeHttp3Frame*(data: openArray[byte], offset: var int): Http3Frame =
  let frameType = decodeQuicVarInt(data, offset)
  let payloadLen = decodeQuicVarInt(data, offset)
  if payloadLen > uint64(data.len - offset):
    raise newException(ValueError, "HTTP/3 frame truncated")
  let n = int(payloadLen)
  result.frameType = frameType
  result.payload = newSeq[byte](n)
  for i in 0 ..< n:
    result.payload[i] = data[offset + i]
  offset += n

proc decodeAllHttp3Frames*(data: openArray[byte]): seq[Http3Frame] =
  var off = 0
  while off < data.len:
    result.add decodeHttp3Frame(data, off)

proc encodeSettingsPayload*(settings: openArray[(uint64, uint64)]): seq[byte] =
  result = @[]
  for (k, v) in settings:
    result.appendQuicVarInt(k)
    result.appendQuicVarInt(v)

proc decodeSettingsPayload*(payload: openArray[byte]): seq[(uint64, uint64)] =
  var off = 0
  while off < payload.len:
    let k = decodeQuicVarInt(payload, off)
    let v = decodeQuicVarInt(payload, off)
    result.add (k, v)

proc decodeSettingsPayloadStrict*(payload: openArray[byte]): seq[(uint64, uint64)] =
  ## Decode SETTINGS and enforce RFC 9114 constraints:
  ## - setting identifiers MUST NOT repeat
  ## - HTTP/2-specific identifiers (0x2-0x5) are forbidden in HTTP/3
  ## - SETTINGS_ENABLE_CONNECT_PROTOCOL is boolean (0 or 1)
  ## - SETTINGS_H3_DATAGRAM is boolean (0 or 1)
  var off = 0
  var seen = initHashSet[uint64]()
  while off < payload.len:
    let k = decodeQuicVarInt(payload, off)
    let v = decodeQuicVarInt(payload, off)
    if k in seen:
      raise newException(ValueError, "duplicate SETTINGS identifier")
    seen.incl(k)
    case k
    of 0x02'u64, 0x03'u64, 0x04'u64, 0x05'u64:
      raise newException(ValueError, "forbidden HTTP/2 SETTINGS identifier")
    of H3SettingEnableConnectProtocol:
      if v > 1'u64:
        raise newException(ValueError, "SETTINGS_ENABLE_CONNECT_PROTOCOL must be 0 or 1")
    of H3SettingH3Datagram:
      if v > 1'u64:
        raise newException(ValueError, "SETTINGS_H3_DATAGRAM must be 0 or 1")
    else:
      discard
    result.add (k, v)

proc describeHttp3FrameType*(frameType: uint64): string =
  case frameType
  of H3FrameData: "DATA"
  of H3FrameHeaders: "HEADERS"
  of H3FrameCancelPush: "CANCEL_PUSH"
  of H3FrameSettings: "SETTINGS"
  of H3FramePushPromise: "PUSH_PROMISE"
  of H3FrameGoaway: "GOAWAY"
  of H3FrameMaxPushId: "MAX_PUSH_ID"
  else: "UNKNOWN(0x" & toHex(frameType.int) & ")"
