import cps/http/shared/http3_connection
import cps/http/shared/http3
import cps/quic/varint

proc hasProtocolError(events: seq[Http3Event]): bool =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return true
  false

let server = newHttp3Connection(isClient = false)
let client = newHttp3Connection(isClient = true)

discard client.advertiseMaxPushId(8'u64)

var payload: seq[byte] = @[]
payload.appendQuicVarInt(H3UniPushStream)
payload.appendQuicVarInt(1'u64)
payload.add server.encodeHeadersFrame(@[("content-type", "text/plain")])

let evs = client.ingestUniStreamData(11'u64, payload)
echo "has_protocol_error=", hasProtocolError(evs)
for ev in evs:
  echo "kind=", ev.kind, " msg=", ev.errorMessage, " code=", ev.errorCode
