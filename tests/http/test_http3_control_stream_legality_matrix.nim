## HTTP/3 control stream legality matrix tests.

import std/tables
import cps/quic/varint
import cps/http/shared/http3
import cps/http/shared/qpack
import cps/http/shared/http3_connection

proc hasProtocolError(events: seq[Http3Event]): bool =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return true
  false

proc firstProtocolErrorCode(events: seq[Http3Event]): uint64 =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return ev.errorCode
  0'u64

block testSingleControlStreamInvariant:
  let conn = newHttp3Connection(isClient = false)
  let sender = newHttp3Connection(isClient = true)
  let preface = sender.encodeControlStreamPreface()
  let ev1 = conn.ingestUniStreamData(2'u64, preface)
  doAssert ev1.len == 1
  doAssert ev1[0].kind == h3evSettings

  var secondControl: seq[byte] = @[]
  secondControl.appendQuicVarInt(H3UniControlStream)
  secondControl.add encodeHttp3Frame(H3FrameSettings, @[])
  let ev2 = conn.ingestUniStreamData(6'u64, secondControl)
  doAssert hasProtocolError(ev2)
  echo "PASS: HTTP/3 duplicate control stream rejected"

block testSettingsFirstAndOnce:
  let connFirst = newHttp3Connection(isClient = false)
  var bad: seq[byte] = @[]
  bad.appendQuicVarInt(H3UniControlStream)
  bad.add encodeHttp3Frame(H3FrameGoaway, @[0x00'u8])
  let ev1 = connFirst.ingestUniStreamData(2'u64, bad)
  doAssert hasProtocolError(ev1)
  doAssert firstProtocolErrorCode(ev1) == H3ErrMissingSettings

  let connDup = newHttp3Connection(isClient = false)
  let sender = newHttp3Connection(isClient = true)
  let preface = sender.encodeControlStreamPreface()
  discard connDup.ingestUniStreamData(10'u64, preface)

  var dupSettings: seq[byte] = @[]
  dupSettings.add encodeHttp3Frame(H3FrameSettings, @[])
  let ev2 = connDup.ingestUniStreamData(10'u64, dupSettings)
  doAssert hasProtocolError(ev2)
  doAssert firstProtocolErrorCode(ev2) == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 SETTINGS first/once invariants enforced"

block testControlStreamFatalViolationIsFailClosed:
  let conn = newHttp3Connection(isClient = false)
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameGoaway, @[0x00'u8]) # invalid before SETTINGS
  payload.add encodeHttp3Frame(H3FrameSettings, @[])       # must not be applied after fatal error

  let events = conn.ingestUniStreamData(2'u64, payload)
  doAssert events.len == 1
  doAssert events[0].kind == h3evProtocolError
  doAssert events[0].errorCode == H3ErrMissingSettings
  doAssert not conn.peerSettingsReceived

  let followup = conn.ingestUniStreamData(2'u64, encodeHttp3Frame(H3FrameSettings, @[]))
  doAssert followup.len == 1
  doAssert followup[0].kind == h3evProtocolError
  doAssert followup[0].errorCode == H3ErrMissingSettings
  doAssert not conn.peerSettingsReceived
  echo "PASS: HTTP/3 control stream fatal violation prevents later SETTINGS state mutation"

block testUnknownControlFrameHandling:
  let connBeforeSettings = newHttp3Connection(isClient = false)
  var unknownBeforeSettings: seq[byte] = @[]
  unknownBeforeSettings.appendQuicVarInt(H3UniControlStream)
  unknownBeforeSettings.add encodeHttp3Frame(0xF0700'u64, @[])
  let evBefore = connBeforeSettings.ingestUniStreamData(2'u64, unknownBeforeSettings)
  doAssert hasProtocolError(evBefore)
  doAssert firstProtocolErrorCode(evBefore) == H3ErrMissingSettings

  let connAfterSettings = newHttp3Connection(isClient = false)
  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  let settingsEvents = connAfterSettings.ingestUniStreamData(10'u64, preface)
  doAssert settingsEvents.len == 1
  doAssert settingsEvents[0].kind == h3evSettings

  var unknownAfterSettings: seq[byte] = @[]
  unknownAfterSettings.add encodeHttp3Frame(0xF0700'u64, @[0xAA'u8, 0xBB'u8])
  let evAfter = connAfterSettings.ingestUniStreamData(10'u64, unknownAfterSettings)
  doAssert not hasProtocolError(evAfter)
  doAssert evAfter.len == 0
  echo "PASS: HTTP/3 unknown control frames ignored after SETTINGS"

block testKnownRequestFrameOnControlRejected:
  let conn = newHttp3Connection(isClient = false)
  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  let settingsEvents = conn.ingestUniStreamData(2'u64, preface)
  doAssert settingsEvents.len == 1
  doAssert settingsEvents[0].kind == h3evSettings

  let bad = encodeHttp3Frame(H3FrameHeaders, @[0x00'u8])
  let ev = conn.ingestUniStreamData(2'u64, bad)
  doAssert hasProtocolError(ev)
  doAssert firstProtocolErrorCode(ev) == H3ErrFrameUnexpected
  echo "PASS: HTTP/3 request-only frame rejected on control stream"

block testControlFrameFragmentBuffering:
  let receiver = newHttp3Connection(isClient = false)
  let sender = newHttp3Connection(isClient = true)
  let preface = sender.encodeControlStreamPreface()
  doAssert preface.len > 3
  let partA = preface[0 .. 1]
  let partB = preface[2 .. ^1]
  let evA = receiver.ingestUniStreamData(2'u64, partA)
  doAssert evA.len == 0
  let evB = receiver.ingestUniStreamData(2'u64, partB)
  doAssert evB.len == 1
  doAssert evB[0].kind == h3evSettings
  echo "PASS: HTTP/3 control stream frame fragmentation buffering"

block testClosedCriticalControlStream:
  let conn = newHttp3Connection(isClient = false)
  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  let settingsEvents = conn.ingestUniStreamData(2'u64, preface)
  doAssert settingsEvents.len == 1
  doAssert settingsEvents[0].kind == h3evSettings
  let finEvents = conn.finalizeUniStream(2'u64)
  doAssert hasProtocolError(finEvents)
  doAssert firstProtocolErrorCode(finEvents) == H3ErrClosedCriticalStream
  echo "PASS: HTTP/3 closed critical stream mapped to H3_CLOSED_CRITICAL_STREAM"

block testQpackEncoderStreamFatalViolationIsFailClosed:
  let conn = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  var bad: seq[byte] = @[]
  bad.appendQuicVarInt(H3UniQpackEncoderStream)
  bad.add 0x3F'u8
  for _ in 0 ..< 12:
    bad.add 0xFF'u8
  let ev1 = conn.ingestUniStreamData(6'u64, bad)
  doAssert hasProtocolError(ev1)
  doAssert firstProtocolErrorCode(ev1) == QpackErrEncoderStream

  let capacityBefore = conn.qpackDecoder.maxTableCapacity
  let good = encodeEncoderInstruction(QpackEncoderInstruction(kind: qeikSetCapacity, capacity: 0'u64))
  let ev2 = conn.ingestUniStreamData(6'u64, good)
  doAssert hasProtocolError(ev2)
  doAssert firstProtocolErrorCode(ev2) == QpackErrEncoderStream
  doAssert conn.qpackDecoder.maxTableCapacity == capacityBefore
  echo "PASS: HTTP/3 QPACK encoder stream fatal violation prevents later state mutation"

block testQpackDecoderStreamFatalViolationIsFailClosed:
  let conn = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  conn.qpackEncoder.blockedStreams = 1
  var bad: seq[byte] = @[]
  bad.appendQuicVarInt(H3UniQpackDecoderStream)
  bad.add 0x3F'u8
  for _ in 0 ..< 12:
    bad.add 0xFF'u8
  let ev1 = conn.ingestUniStreamData(10'u64, bad)
  doAssert hasProtocolError(ev1)
  doAssert firstProtocolErrorCode(ev1) == QpackErrDecoderStream

  let blockedBefore = conn.qpackEncoder.blockedStreams
  let good = encodeDecoderInstruction(QpackDecoderInstruction(kind: qdikSectionAck, streamId: 0'u64))
  let ev2 = conn.ingestUniStreamData(10'u64, good)
  doAssert hasProtocolError(ev2)
  doAssert firstProtocolErrorCode(ev2) == QpackErrDecoderStream
  doAssert conn.qpackEncoder.blockedStreams == blockedBefore
  echo "PASS: HTTP/3 QPACK decoder stream fatal violation prevents later state mutation"

block testUniStreamBufferLimit:
  let conn = newHttp3Connection(
    isClient = false,
    maxUniStreamBufferBytes = 4,
    maxTotalUniStreamBufferBytes = 8
  )
  var overLimit: seq[byte] = @[]
  overLimit.appendQuicVarInt(H3UniControlStream)
  overLimit.appendQuicVarInt(H3FrameSettings)
  overLimit.appendQuicVarInt(128'u64)
  overLimit.add 0x00'u8
  let ev = conn.ingestUniStreamData(2'u64, overLimit)
  doAssert hasProtocolError(ev)
  doAssert firstProtocolErrorCode(ev) == H3ErrExcessiveLoad
  doAssert conn.totalUniBufferedBytes() == 0

  var minimalSettings: seq[byte] = @[]
  minimalSettings.appendQuicVarInt(H3UniControlStream)
  minimalSettings.add encodeHttp3Frame(H3FrameSettings, @[])
  let followup = conn.ingestUniStreamData(2'u64, minimalSettings)
  doAssert hasProtocolError(followup)
  doAssert firstProtocolErrorCode(followup) == H3ErrExcessiveLoad
  doAssert not conn.peerSettingsReceived
  echo "PASS: HTTP/3 unidirectional stream buffering limit enforced"

block testRequestBufferTotalLimit:
  let conn = newHttp3Connection(
    isClient = false,
    maxRequestStreamBufferBytes = 32,
    maxTotalRequestStreamBufferBytes = 9
  )
  var partial: seq[byte] = @[]
  partial.appendQuicVarInt(H3FrameData)
  partial.appendQuicVarInt(1024'u64)
  partial.add @[0x00'u8, 0x01'u8]

  discard conn.processRequestStreamData(0'u64, partial)
  doAssert conn.totalRequestBufferedBytes() == partial.len

  let ev = conn.processRequestStreamData(4'u64, partial)
  doAssert hasProtocolError(ev)
  doAssert firstProtocolErrorCode(ev) == H3ErrExcessiveLoad
  doAssert conn.totalRequestBufferedBytes() == partial.len
  echo "PASS: HTTP/3 total request-stream buffering limit enforced"

block testRequestBufferPerStreamLimit:
  let conn = newHttp3Connection(
    isClient = false,
    maxRequestStreamBufferBytes = 4,
    maxTotalRequestStreamBufferBytes = 32
  )
  var partial: seq[byte] = @[]
  partial.appendQuicVarInt(H3FrameData)
  partial.appendQuicVarInt(1024'u64)
  partial.add @[0x00'u8, 0x01'u8]

  let ev = conn.processRequestStreamData(0'u64, partial)
  doAssert hasProtocolError(ev)
  doAssert firstProtocolErrorCode(ev) == H3ErrExcessiveLoad
  doAssert conn.totalRequestBufferedBytes() == 0
  echo "PASS: HTTP/3 per-request-stream buffering limit enforced"

block testEmptyUniStreamRejectedOnFinalize:
  let conn = newHttp3Connection(isClient = false)
  let finEvents = conn.finalizeUniStream(2'u64)
  doAssert hasProtocolError(finEvents)
  doAssert firstProtocolErrorCode(finEvents) == H3ErrFrameError
  doAssert not conn.uniStreamTypes.hasKey(2'u64)
  doAssert not conn.uniStreamBuffers.hasKey(2'u64)
  echo "PASS: HTTP/3 empty uni stream rejected on finalize"

block testUnknownUniStreamStateClearedOnFinalize:
  let conn = newHttp3Connection(isClient = false)
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(0x21'u64) # unknown unidirectional stream type
  payload.add @[0xAB'u8, 0xCD'u8]
  let ingestEvents = conn.ingestUniStreamData(2'u64, payload)
  doAssert ingestEvents.len == 0
  doAssert conn.uniStreamTypes.hasKey(2'u64)
  doAssert conn.uniStreamBuffers.hasKey(2'u64)

  let finEvents = conn.finalizeUniStream(2'u64)
  doAssert finEvents.len == 0
  doAssert not conn.uniStreamTypes.hasKey(2'u64), "Expected unknown uni stream role state to be cleared on finalize"
  doAssert not conn.uniStreamBuffers.hasKey(2'u64), "Expected unknown uni stream buffer state to be cleared on finalize"
  echo "PASS: HTTP/3 finalize clears unknown uni stream state"

block testPushUniStreamStateClearedOnFinalize:
  let conn = newHttp3Connection(isClient = true)
  discard conn.advertiseMaxPushId(0'u64)

  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniPushStream)
  payload.appendQuicVarInt(0'u64) # push id
  payload.add conn.encodeHeadersFrame(@[(":status", "200"), ("content-type", "text/plain")])
  payload.add encodeDataFrame(@[0x41'u8])

  let ingestEvents = conn.ingestUniStreamData(15'u64, payload)
  doAssert ingestEvents.len >= 1
  doAssert conn.uniStreamTypes.hasKey(15'u64)
  doAssert conn.uniStreamBuffers.hasKey(15'u64)

  let finEvents = conn.finalizeUniStream(15'u64)
  doAssert not hasProtocolError(finEvents)
  doAssert not conn.uniStreamTypes.hasKey(15'u64), "Expected push uni stream role state to be cleared on finalize"
  doAssert not conn.uniStreamBuffers.hasKey(15'u64), "Expected push uni stream buffer state to be cleared on finalize"
  echo "PASS: HTTP/3 finalize clears push uni stream state"

echo "All HTTP/3 control stream legality matrix tests passed"
