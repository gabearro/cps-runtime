## Tests for HTTPS Client
##
## Starts Python HTTP/1.1 and HTTP/2 test servers,
## then makes requests to them using our CPS client.

import std/[osproc, strutils, os, json, streams]
import cps/runtime
import cps/eventloop
import cps/io/tcp
import cps/io/streams
import cps/io/buffered
import cps/tls/client as tls
import cps/http/shared/hpack
import cps/http/client/http1
import cps/http/shared/http2
import cps/http/client/client

proc startServer(script: string, port: int): Process =
  ## Start a Python test server and wait for it to be ready.
  let p = startProcess("python3", args = [script, $port],
                       options = {poStdErrToStdOut, poUsePath})
  # Wait for READY signal
  let stream = p.outputStream
  var line: string
  var ready = false
  for i in 0 ..< 20:  # Max 20 lines / 10 seconds
    if stream.readLine(line):
      if line.startsWith("READY:"):
        echo "  Server ready on port ", port
        ready = true
        break
      elif line.startsWith("ERROR:"):
        echo "  Server error: ", line
        p.terminate()
        raise newException(system.IOError, "Server failed: " & line)
    sleep(500)
  if not ready:
    p.terminate()
    discard p.waitForExit()
    raise newException(system.IOError, "Server failed to start (no READY): " & script)
  return p

# ============================================================
# Test HPACK encoding/decoding
# ============================================================

block testHpack:
  var enc = initHpackEncoder()
  var dec = initHpackDecoder()

  let headers = @[
    (":method", "GET"),
    (":path", "/"),
    (":scheme", "https"),
    (":authority", "example.com"),
    ("user-agent", "test-client")
  ]

  let encoded = enc.encode(headers)
  let decoded = dec.decode(encoded)

  assert decoded.len == headers.len, "HPACK: header count mismatch"
  for i in 0 ..< headers.len:
    assert decoded[i][0] == headers[i][0], "HPACK: key mismatch at " & $i
    assert decoded[i][1] == headers[i][1], "HPACK: value mismatch at " & $i
  echo "PASS: HPACK encode/decode round-trip"

# ============================================================
# Test HTTP/2 frame serialization
# ============================================================

block testFrameSerialization:
  let frame = Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders or FlagEndStream,
    streamId: 1,
    payload: @[0x82'u8, 0x84]  # :method GET, :path /
  )
  let serialized = serializeFrame(frame)
  assert serialized.len == 9 + 2  # 9 byte header + 2 byte payload

  let parsed = parseFrame(serialized)
  assert parsed.frameType == FrameHeaders
  assert parsed.flags == (FlagEndHeaders or FlagEndStream)
  assert parsed.streamId == 1
  assert parsed.payload == @[0x82'u8, 0x84]
  echo "PASS: HTTP/2 frame serialization round-trip"

# ============================================================
# Test with Python HTTP/1.1 server
# ============================================================

block testHttp11:
  echo ""
  echo "--- HTTP/1.1 Test ---"
  echo "Starting HTTP/1.1 server..."

  let h11Port = 18443
  var server: Process
  try:
    server = startServer("tests/http/server_http11.py", h11Port)
  except:
    echo "SKIP: Could not start HTTP/1.1 server: ", getCurrentExceptionMsg()
    # Don't fail the test, just skip
    echo "SKIP: HTTP/1.1 tests"
    break testHttp11

  sleep(500)  # Give server time to fully start

  try:
    let client = newHttpsClient(preferHttp2 = false)

    echo "  Making GET request..."
    let resp = runCps(client.get("https://127.0.0.1:" & $h11Port & "/"))

    echo "  Status: ", resp.statusCode
    echo "  HTTP Version: ", resp.httpVersion
    echo "  Body: ", resp.body
    assert resp.statusCode == 200, "Expected 200, got " & $resp.statusCode
    assert resp.httpVersion == hvHttp11
    assert "Hello from HTTP/1.1" in resp.body

    echo "  Making GET /json request..."
    let jsonResp = runCps(client.get("https://127.0.0.1:" & $h11Port & "/json"))
    assert jsonResp.statusCode == 200
    let jsonBody = parseJson(jsonResp.body)
    assert jsonBody["message"].getStr() == "hello from http/1.1"

    echo "PASS: HTTP/1.1 GET requests"
  except:
    echo "FAIL: HTTP/1.1 test error: ", getCurrentExceptionMsg()
  finally:
    server.terminate()
    discard server.waitForExit()

# ============================================================
# Test with Python HTTP/2 server
# ============================================================

block testHttp2:
  echo ""
  echo "--- HTTP/2 Test ---"
  echo "Starting HTTP/2 server..."

  let h2Port = 18444
  var server: Process
  try:
    server = startServer("tests/http/server_http2.py", h2Port)
  except:
    echo "SKIP: Could not start HTTP/2 server: ", getCurrentExceptionMsg()
    echo "SKIP: HTTP/2 tests"
    break testHttp2

  sleep(500)

  try:
    let client = newHttpsClient(preferHttp2 = true)

    echo "  Making GET request..."
    let resp = runCps(client.get("https://127.0.0.1:" & $h2Port & "/"))

    echo "  Status: ", resp.statusCode
    echo "  HTTP Version: ", resp.httpVersion
    echo "  Body: ", resp.body
    assert resp.statusCode == 200, "Expected 200, got " & $resp.statusCode
    assert resp.httpVersion == hvHttp2
    assert "Hello from HTTP/2" in resp.body

    echo "  Making GET /json request..."
    let jsonResp = runCps(client.get("https://127.0.0.1:" & $h2Port & "/json"))
    assert jsonResp.statusCode == 200
    let jsonBody = parseJson(jsonResp.body)
    assert jsonBody["message"].getStr() == "hello from http/2"

    echo "PASS: HTTP/2 GET requests"
  except:
    echo "FAIL: HTTP/2 test error: ", getCurrentExceptionMsg()
  finally:
    server.terminate()
    discard server.waitForExit()

echo ""
echo "All HTTPS client tests completed!"
