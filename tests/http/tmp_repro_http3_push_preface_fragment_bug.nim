import cps/http/shared/http3_connection
import cps/http/shared/http3

let client = newHttp3Connection(isClient = true)
discard client.advertiseMaxPushId(16'u64)

let ev1 = client.ingestUniStreamData(11'u64, @[0x01'u8])
echo "ev1_len=", ev1.len
echo "buffer_after_ev1=", client.totalUniBufferedBytes()

var chunk2: seq[byte] = @[]
chunk2.add @[0x05'u8]
chunk2.add client.encodeHeadersFrame(@[(":status", "200")])
let ev2 = client.ingestUniStreamData(11'u64, chunk2)

echo "ev2_len=", ev2.len
for i, ev in ev2:
  echo "ev2[", i, "].kind=", ev.kind, " pushId=", ev.pushId, " errCode=", ev.errorCode, " err=", ev.errorMessage
