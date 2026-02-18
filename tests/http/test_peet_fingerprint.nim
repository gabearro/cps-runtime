## Test TLS/HTTP/2 fingerprint against tls.peet.ws
##
## Makes HTTPS requests to tls.peet.ws/api/all which returns the
## observed TLS and HTTP/2 fingerprint of the client connection.
##
## Usage:
##   # With OpenSSL (partial fingerprint):
##   nim c -r tests/test_peet_fingerprint.nim
##
##   # With BoringSSL (full fingerprint):
##   nim c -r -d:useBoringSSL tests/test_peet_fingerprint.nim

import std/[strutils, json]
import cps
import cps/io
import cps/tls/client as tls
import cps/http/shared/http2
import cps/http/shared/hpack
import cps/http/client/client
import cps/tls/fingerprint
import cps/http/shared/compression

proc testDefaultFingerprint(): CpsVoidFuture {.cps.} =
  echo "=== Test 1: Default fingerprint (no profile) ==="
  let client = newHttpsClient()
  let resp = await client.get("https://tls.peet.ws/api/all")
  echo "Status: ", resp.statusCode
  if resp.statusCode == 200:
    let j = parseJson(resp.body)
    echo "TLS:"
    if j.hasKey("tls"):
      let tls = j["tls"]
      if tls.hasKey("ja4"):
        echo "  JA4: ", tls["ja4"].getStr()
      if tls.hasKey("ja3"):
        echo "  JA3: ", tls["ja3"].getStr()
      if tls.hasKey("ja3_hash"):
        echo "  JA3 hash: ", tls["ja3_hash"].getStr()
      if tls.hasKey("akamai_hash"):
        echo "  Akamai hash: ", tls["akamai_hash"].getStr()
    echo "HTTP/2:"
    if j.hasKey("http2"):
      let h2 = j["http2"]
      if h2.hasKey("akamai_fingerprint"):
        echo "  Akamai FP: ", h2["akamai_fingerprint"].getStr()
      if h2.hasKey("akamai_fingerprint_hash"):
        echo "  Akamai FP hash: ", h2["akamai_fingerprint_hash"].getStr()
    echo "User-Agent: ", resp.getHeader("user-agent")
    # Print raw JSON for inspection
    echo "\nFull response (truncated):"
    let body = resp.body
    if body.len > 2000:
      echo body[0 ..< 2000], "..."
    else:
      echo body
  else:
    echo "Request failed: ", resp.body
  client.close()

proc testChromeFingerprint(): CpsVoidFuture {.cps.} =
  echo "\n=== Test 2: Chrome fingerprint profile ==="
  let profile = chromeProfile()
  let client = newHttpsClient(fingerprint = profile)
  let resp = await client.get("https://tls.peet.ws/api/all")
  echo "Status: ", resp.statusCode
  if resp.statusCode == 200:
    let j = parseJson(resp.body)
    echo "TLS:"
    if j.hasKey("tls"):
      let tls = j["tls"]
      if tls.hasKey("ja4"):
        echo "  JA4: ", tls["ja4"].getStr()
      if tls.hasKey("ja3"):
        echo "  JA3: ", tls["ja3"].getStr()
      if tls.hasKey("ja3_hash"):
        echo "  JA3 hash: ", tls["ja3_hash"].getStr()
      if tls.hasKey("akamai_hash"):
        echo "  Akamai hash: ", tls["akamai_hash"].getStr()
    echo "HTTP/2:"
    if j.hasKey("http2"):
      let h2 = j["http2"]
      if h2.hasKey("akamai_fingerprint"):
        echo "  Akamai FP: ", h2["akamai_fingerprint"].getStr()
      if h2.hasKey("akamai_fingerprint_hash"):
        echo "  Akamai FP hash: ", h2["akamai_fingerprint_hash"].getStr()
    echo "\nFull response (truncated):"
    let body = resp.body
    if body.len > 2000:
      echo body[0 ..< 2000], "..."
    else:
      echo body
  else:
    echo "Request failed: ", resp.body
  client.close()

proc testFirefoxFingerprint(): CpsVoidFuture {.cps.} =
  echo "\n=== Test 3: Firefox fingerprint profile ==="
  let profile = firefoxProfile()
  let client = newHttpsClient(fingerprint = profile)
  let resp = await client.get("https://tls.peet.ws/api/all")
  echo "Status: ", resp.statusCode
  if resp.statusCode == 200:
    let j = parseJson(resp.body)
    echo "TLS:"
    if j.hasKey("tls"):
      let tls = j["tls"]
      if tls.hasKey("ja4"):
        echo "  JA4: ", tls["ja4"].getStr()
      if tls.hasKey("ja3"):
        echo "  JA3: ", tls["ja3"].getStr()
      if tls.hasKey("ja3_hash"):
        echo "  JA3 hash: ", tls["ja3_hash"].getStr()
    echo "HTTP/2:"
    if j.hasKey("http2"):
      let h2 = j["http2"]
      if h2.hasKey("akamai_fingerprint"):
        echo "  Akamai FP: ", h2["akamai_fingerprint"].getStr()
      if h2.hasKey("akamai_fingerprint_hash"):
        echo "  Akamai FP hash: ", h2["akamai_fingerprint_hash"].getStr()
    echo "\nFull response (truncated):"
    let body = resp.body
    if body.len > 2000:
      echo body[0 ..< 2000], "..."
    else:
      echo body
  else:
    echo "Request failed: ", resp.body
  client.close()

proc main(): CpsVoidFuture {.cps.} =
  await testDefaultFingerprint()
  await testChromeFingerprint()
  await testFirefoxFingerprint()
  echo "\n=== All fingerprint tests complete ==="
  let loop = getEventLoop()
  loop.shutdownGracefully()

block:
  runCps(main())
