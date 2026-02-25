## HTTP/3 client decode should recover from QPACK-blocked response headers
## once encoder-stream instructions are received.

import std/strutils
import cps/http/client/http3 as client_http3
import cps/http/shared/http3
import cps/http/shared/http3_connection
import cps/http/shared/qpack
import cps/quic/varint

proc stringBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(ord(s[i]) and 0xFF)

block testBlockedResponseDecodeUnblocksAfterEncoderInstruction:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64

  # RFC9204 header-block prefix for Required Insert Count = 1, Base = 1,
  # followed by an indexed dynamic field line (index = 0).
  # Encoded RIC with default table capacity (4096 -> maxEntries=128) is 2.
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]

  var blockedPayload: seq[byte] = @[]
  blockedPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)
  blockedPayload.add encodeHttp3Frame(H3FrameData, stringBytes("ok"))

  var blockedRaised = false
  try:
    discard session.decodeResponseFrames(streamId, blockedPayload)
  except ValueError as e:
    blockedRaised = e.msg.toLowerAscii.contains("blocked")
  doAssert blockedRaised, "Expected decodeResponseFrames to report QPACK-blocked response headers"

  # Deliver peer QPACK encoder-stream preface + insert instruction that creates
  # dynamic table index 0 -> (:status, 200), then retry decode.
  var encoderStreamBytes: seq[byte] = @[]
  encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertLiteral,
    name: ":status",
    value: "200"
  ))
  let uniEvents = session.conn.ingestUniStreamData(7'u64, encoderStreamBytes)
  for ev in uniEvents:
    doAssert ev.kind != h3evProtocolError,
      "Unexpected protocol error while ingesting QPACK encoder stream: " & ev.errorMessage

  let resp = session.decodeResponseFrames(streamId, @[])
  doAssert resp.statusCode == 200
  doAssert resp.body == "ok"
  echo "PASS: HTTP/3 client recovers blocked response decode after QPACK encoder updates"

block testProtocolErrorPreservesCodeAndStream:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64

  # DATA before HEADERS on request stream is a strict HTTP/3 frame-ordering error.
  let badPayload = encodeDataFrame(@[0xFF'u8])
  var raised = false
  var errorCode = 0'u64
  var errorStream = high(uint64)
  try:
    discard session.decodeResponseFrames(streamId, badPayload)
  except client_http3.Http3ProtocolError as e:
    raised = true
    errorCode = e.errorCode
    errorStream = e.streamId
  doAssert raised, "Expected Http3ProtocolError for malformed response stream ordering"
  doAssert errorCode == H3ErrFrameUnexpected, "Unexpected HTTP/3 error code: " & $errorCode
  doAssert errorStream == streamId, "Unexpected HTTP/3 error stream id: " & $errorStream
  echo "PASS: HTTP/3 client protocol error preserves code and stream id"

echo "All HTTP/3 client blocked-QPACK decode tests passed"
