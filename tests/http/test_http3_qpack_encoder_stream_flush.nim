## HTTP/3 should emit RFC QPACK encoder-stream updates for dynamic inserts.

import cps/http/shared/http3_connection
import cps/http/shared/qpack
import cps/http/shared/http3

proc hasProtocolError(events: seq[Http3Event]): bool =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return true
  false

block testDrainQpackEncoderStreamDataAfterHeaderEncoding:
  let sender = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  let receiver = newHttp3Connection(isClient = false, useRfcQpackWire = true)

  # Establish peer QPACK encoder stream type for receiver.
  let preface = sender.encodeQpackEncoderStreamPreface()
  let prefaceEvents = receiver.ingestUniStreamData(6'u64, preface)
  doAssert not hasProtocolError(prefaceEvents)

  discard sender.encodeHeadersFrame(@[("x-qpack", "1")])
  let updates = sender.drainQpackEncoderStreamData()
  doAssert updates.len > 0, "Expected pending QPACK encoder-stream updates after literal header encoding"
  doAssert sender.drainQpackEncoderStreamData().len == 0, "Drain should clear queued QPACK updates"

  let events = receiver.ingestUniStreamData(6'u64, updates)
  doAssert not hasProtocolError(events)
  doAssert receiver.qpackDecoder.knownInsertCount >= 1'u64
  doAssert receiver.qpackDecoder.dynamicTable.len > 0
  doAssert receiver.qpackDecoder.dynamicTable[0] == ("x-qpack", "1")
  echo "PASS: HTTP/3 drains and applies QPACK encoder-stream updates for RFC wire mode"

block testQpackDecoderFeedbackUpdatesPeerEncoderState:
  let decoderSide = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  let encoderSide = newHttp3Connection(isClient = true, useRfcQpackWire = true)

  let encPreface = decoderSide.encodeQpackEncoderStreamPreface()
  discard decoderSide.ingestUniStreamData(7'u64, encPreface)
  let insertInst = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertLiteral,
    name: "x-feedback",
    value: "ok"
  ))
  discard decoderSide.ingestUniStreamData(7'u64, insertInst)
  let decFeedback = decoderSide.drainQpackDecoderStreamData()
  doAssert decFeedback.len > 0, "Expected decoder-side insert-count feedback after encoder inserts"

  var peerDecoderStreamPayload = encoderSide.encodeQpackDecoderStreamPreface()
  peerDecoderStreamPayload.add decFeedback
  let feedbackEvents = encoderSide.ingestUniStreamData(11'u64, peerDecoderStreamPayload)
  doAssert not hasProtocolError(feedbackEvents)
  doAssert encoderSide.qpackEncoder.requiredInsertCount >= 1'u64
  echo "PASS: HTTP/3 decoder-stream feedback advances peer encoder required insert count"

block testPushPromiseQueuesQpackEncoderUpdates:
  let client = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  let server = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  var controlPayload = client.encodeControlStreamPreface()
  controlPayload.add client.advertiseMaxPushId(4'u64)
  discard server.ingestUniStreamData(2'u64, controlPayload)
  discard server.createPushPromise(0'u64, @[
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/asset")
  ])
  let updates = server.drainQpackEncoderStreamData()
  doAssert updates.len > 0, "Expected PUSH_PROMISE header encoding to queue QPACK encoder updates"
  echo "PASS: HTTP/3 PUSH_PROMISE queues QPACK encoder-stream updates"

block testQpackSectionAckQueuedAfterDynamicHeaderDecode:
  let encoderSide = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  let decoderSide = newHttp3Connection(isClient = false, useRfcQpackWire = true)

  # Establish peer QPACK encoder stream at the decoder side.
  let encPreface = encoderSide.encodeQpackEncoderStreamPreface()
  discard decoderSide.ingestUniStreamData(6'u64, encPreface)

  # First header encoding emits a dynamic insert instruction.
  discard encoderSide.encodeHeadersFrame(@[("x-ack", "v1")])
  let encoderUpdates = encoderSide.drainQpackEncoderStreamData()
  doAssert encoderUpdates.len > 0
  discard decoderSide.ingestUniStreamData(6'u64, encoderUpdates)

  # Decoder-side feedback advances encoder's required insert count.
  let decoderFeedback = decoderSide.drainQpackDecoderStreamData()
  doAssert decoderFeedback.len > 0
  var feedbackPayload = encoderSide.encodeQpackDecoderStreamPreface()
  feedbackPayload.add decoderFeedback
  discard encoderSide.ingestUniStreamData(11'u64, feedbackPayload)

  # With insert-count acknowledgment applied, this headers frame should use a
  # dynamic reference and trigger a Section Ack on decode.
  let requestHeadersFrame = encoderSide.encodeHeadersFrame(@[("x-ack", "v1")])
  let requestEvents = decoderSide.processRequestStreamData(0'u64, requestHeadersFrame)
  doAssert not hasProtocolError(requestEvents)
  doAssert requestEvents.len > 0
  doAssert requestEvents[0].kind == h3evHeaders

  let sectionAckBytes = decoderSide.drainQpackDecoderStreamData()
  doAssert sectionAckBytes.len > 0, "Expected decoder to queue QPACK Section Ack after dynamic header decode"

  var off = 0
  let ackInst = decodeDecoderInstructionPrefix(sectionAckBytes, off)
  doAssert ackInst.kind == qdikSectionAck
  doAssert ackInst.streamId == 0'u64

  # Applying Section Ack should clear one blocked-stream slot on the encoder.
  encoderSide.qpackEncoder.blockedStreams = 1
  discard encoderSide.ingestUniStreamData(11'u64, sectionAckBytes)
  doAssert encoderSide.qpackEncoder.blockedStreams == 0
  echo "PASS: HTTP/3 queues and applies QPACK Section Ack for dynamic header sections"

block testQpackStreamCancelQueuedWhenBlockedStreamCleared:
  let conn = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  let streamId = 0'u64
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  let blockedHeadersFrame = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let events = conn.processRequestStreamData(streamId, blockedHeadersFrame)
  doAssert events.len > 0
  doAssert events[0].kind == h3evNone
  doAssert events[0].errorMessage == "qpack_blocked"

  conn.clearRequestStreamState(streamId)
  let decoderUpdates = conn.drainQpackDecoderStreamData()
  doAssert decoderUpdates.len > 0, "Expected stream cancellation instruction when blocked request stream is cleared"

  var off = 0
  let inst = decodeDecoderInstructionPrefix(decoderUpdates, off)
  doAssert inst.kind == qdikStreamCancel
  doAssert inst.cancelStreamId == streamId
  echo "PASS: HTTP/3 queues QPACK Stream Cancellation for cleared blocked request streams"

echo "All HTTP/3 QPACK encoder-stream flush tests passed"
