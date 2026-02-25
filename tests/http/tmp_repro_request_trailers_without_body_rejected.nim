import cps/http/shared/http3_connection

let conn = newHttp3Connection(isClient = false)
var payload: seq[byte] = @[]
payload.add conn.encodeHeadersFrame(@[
  (":method", "GET"),
  (":scheme", "https"),
  (":authority", "example.com"),
  (":path", "/")
])
payload.add conn.encodeHeadersFrame(@[("x-trailer", "t")])

let events = conn.processRequestStreamData(0'u64, payload)
for ev in events:
  if ev.kind == h3evProtocolError:
    echo "protocol_error code=", ev.errorCode, " msg=", ev.errorMessage
  else:
    echo "event=", ev.kind
