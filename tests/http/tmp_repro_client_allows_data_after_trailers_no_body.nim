import cps/http/client/http3
import cps/http/shared/http3_connection
import cps/http/shared/http3

let client = newHttp3ClientSession()
let serverConn = newHttp3Connection(isClient = false, useRfcQpackWire = true)

var payload: seq[byte] = @[]
payload.add serverConn.encodeHeadersFrame(@[(":status", "200"), ("content-type", "text/plain")])
payload.add serverConn.encodeHeadersFrame(@[("x-trailer", "t")])
payload.add encodeDataFrame(@[byte('x')])

var err = ""
try:
  let resp = client.decodeResponseFrames(0'u64, payload)
  echo "status=", resp.statusCode, " headers=", resp.headers.len, " body=", resp.body
except ValueError as e:
  err = e.msg

if err.len > 0:
  echo "error=", err
