import std/tables
import cps/http/shared/http3_connection
import cps/http/shared/http3
import cps/http/shared/qpack
import cps/quic/varint

let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
discard conn.advertiseMaxPushId(8'u64)

let streamId = 11'u64
let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
var pushPayload: seq[byte] = @[]
pushPayload.appendQuicVarInt(H3UniPushStream)
pushPayload.appendQuicVarInt(5'u64)
pushPayload.add encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

let ev1 = conn.ingestUniStreamData(streamId, pushPayload)
echo "ev1_len=", ev1.len
for i, ev in ev1:
  echo "ev1[", i, "].kind=", ev.kind, " err=", ev.errorMessage

let fin = conn.finalizeUniStream(streamId)
echo "fin_len=", fin.len
for i, ev in fin:
  echo "fin[", i, "].kind=", ev.kind, " err=", ev.errorMessage

echo "after_fin_has_req_state=", conn.requestStates.hasKey(streamId)
echo "after_fin_req_buf=", conn.requestStreamBufferedBytes(streamId)

var encoderStreamBytes: seq[byte] = @[]
encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
  kind: qeikInsertNameRef,
  nameRefIndex: 25'u64,
  nameRefIsStatic: true,
  value: "200"
))

discard conn.ingestUniStreamData(7'u64, encoderStreamBytes)
let retryEvents = conn.processRequestStreamData(streamId, @[], streamRole = h3srPush)
echo "retry_len=", retryEvents.len
for i, ev in retryEvents:
  echo "retry[", i, "].kind=", ev.kind, " pushId=", ev.pushId, " err=", ev.errorMessage
