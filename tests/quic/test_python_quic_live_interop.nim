## Live Python QUIC interop tests.
##
## Runs an aioquic client in a venv against the Nim QUIC server endpoint to
## validate that encrypted runtime handshake paths are exercised end-to-end.

when defined(useBoringSSL):
  import std/[os, osproc, streams as stdstreams, strutils, times]
  import cps/runtime
  import cps/transform
  import cps/eventloop
  import cps/quic
  import ./interop_helpers

  proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
    ## Prevent indefinite blocking in loop.tick() during interop polling loops.
    discard loop.registerTimer(maxBlockMs, proc() = discard)
    loop.tick()

  proc waitProcessExit(loop: EventLoop,
                       p: Process,
                       timeoutMs: int): int =
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while epochTime() < deadline:
      let code = peekExitCode(p)
      if code != -1:
        return p.waitForExit(100)
      loop.tickBounded()
      sleep(2)
    -1

  proc stringToBytes(s: string): seq[byte] =
    result = newSeq[byte](s.len)
    for i in 0 ..< s.len:
      result[i] = byte(ord(s[i]) and 0xFF)

  proc isHexString(s: string): bool =
    if s.len == 0:
      return false
    for ch in s:
      if not ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')):
        return false
    true

  proc isLikelyNssKeyLogLine(line: string): bool =
    let parts = line.splitWhitespace()
    if parts.len != 3:
      return false
    if parts[1].len != 64:
      return false
    if not isHexString(parts[1]):
      return false
    if not isHexString(parts[2]):
      return false
    true

  block testPythonClientToNimServerLiveHandshake:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()

    var sawOneRtt = false
    var sawStreamReadable = false
    var sentStreamEcho = false
    var keyLogLines: seq[string] = @[]
    var endpoint: QuicEndpoint = nil
    proc onHandshakeState(conn: QuicConnection,
                          state: QuicHandshakeState): CpsVoidFuture {.cps.} =
      discard conn
      if state == qhsOneRtt:
        sawOneRtt = true

    proc onStreamReadable(conn: QuicConnection,
                          streamId: uint64): CpsVoidFuture {.cps.} =
      if endpoint.isNil:
        return
      let streamObj = conn.getOrCreateStream(streamId)
      let recv = streamObj.popRecvData(high(int))
      if recv.len == 0:
        return
      sawStreamReadable = true
      var payload = stringToBytes("nim-echo:")
      payload.add recv
      let fin = streamObj.recvState == qrsDataRecvd
      await endpoint.sendStreamData(conn, streamId, payload, fin = fin)
      sentStreamEcho = true

    var cfg = defaultQuicEndpointConfig()
    cfg.tlsCertFile = certFile
    cfg.tlsKeyFile = keyFile
    cfg.quicUseRetry = false
    cfg.alpn = @["h3"]
    cfg.tlsKeyLogCallback = proc(line: string) =
      keyLogLines.add(line)
    if existsEnv("CPS_QUIC_DEBUG"):
      cfg.qlogSink = proc(event: string) =
        echo "[cps-quic-live] ", event

    endpoint = newQuicServerEndpoint(
      bindHost = "127.0.0.1",
      bindPort = 0,
      config = cfg,
      onHandshakeState = onHandshakeState,
      onStreamReadable = onStreamReadable
    )
    endpoint.start()

    let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)
    let pyFile = pythonFixturePath("quic_live_client_handshake.py")
    let pyProcess = startProcess(
      venvPython,
      args = [pyFile, "127.0.0.1", $serverPort],
      options = {poStdErrToStdOut}
    )

    var pyExit = -1
    let loop = getEventLoop()
    let deadline = epochTime() + 15.0
    while epochTime() < deadline:
      loop.tickBounded()
      pyExit = waitProcessExit(loop, pyProcess, 50)
      if pyExit != -1:
        break

    if pyExit == -1:
      terminate(pyProcess)
      discard pyProcess.waitForExit(2_000)

    # Drain trailing endpoint callbacks before validation.
    let settleDeadline = epochTime() + 1.0
    while epochTime() < settleDeadline:
      loop.tickBounded()
      sleep(2)

    let pyOutput = stdstreams.readAll(pyProcess.outputStream)
    pyProcess.close()
    endpoint.shutdown(closeSocket = true)

    doAssert pyExit == 0,
      "Python aioquic live client failed (exit " & $pyExit & "): " & pyOutput
    doAssert "PYTHON_QUIC_LIVE_CLIENT_OK" in pyOutput,
      "Missing live interop success marker: " & pyOutput
    doAssert "PYTHON_QUIC_LIVE_STREAM_ECHO_OK" in pyOutput,
      "Missing QUIC stream-echo success marker: " & pyOutput
    doAssert sawOneRtt, "Nim QUIC server never reached 1-RTT during live interop"
    doAssert sawStreamReadable, "Nim QUIC server did not receive Python stream data during live interop"
    doAssert sentStreamEcho, "Nim QUIC server did not send stream echo reply during live interop"
    doAssert keyLogLines.len > 0, "Expected TLS keylog callback to emit lines during QUIC handshake"
    var sawNssTrafficSecret = false
    for line in keyLogLines:
      if isLikelyNssKeyLogLine(line) and
          ("TRAFFIC_SECRET" in line or line.startsWith("EXPORTER_SECRET")):
        sawNssTrafficSecret = true
        break
    doAssert sawNssTrafficSecret,
      "Expected NSS-style TLS keylog traffic-secret lines, got:\n" & keyLogLines.join("\n")

    echo "PASS: Python aioquic live handshake + stream echo -> Nim QUIC server"

  block testPythonClientToNimServerLiveHandshakeWithRetry:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()

    var sawOneRtt = false
    var sawStreamReadable = false
    var sentStreamEcho = false
    var endpoint: QuicEndpoint = nil
    proc onHandshakeState(conn: QuicConnection,
                          state: QuicHandshakeState): CpsVoidFuture {.cps.} =
      discard conn
      if state == qhsOneRtt:
        sawOneRtt = true

    proc onStreamReadable(conn: QuicConnection,
                          streamId: uint64): CpsVoidFuture {.cps.} =
      if endpoint.isNil:
        return
      let streamObj = conn.getOrCreateStream(streamId)
      let recv = streamObj.popRecvData(high(int))
      if recv.len == 0:
        return
      sawStreamReadable = true
      var payload = stringToBytes("nim-echo:")
      payload.add recv
      let fin = streamObj.recvState == qrsDataRecvd
      await endpoint.sendStreamData(conn, streamId, payload, fin = fin)
      sentStreamEcho = true

    var cfg = defaultQuicEndpointConfig()
    cfg.tlsCertFile = certFile
    cfg.tlsKeyFile = keyFile
    cfg.quicUseRetry = true
    cfg.alpn = @["h3"]
    if existsEnv("CPS_QUIC_DEBUG"):
      cfg.qlogSink = proc(event: string) =
        echo "[cps-quic-live-retry] ", event

    endpoint = newQuicServerEndpoint(
      bindHost = "127.0.0.1",
      bindPort = 0,
      config = cfg,
      onHandshakeState = onHandshakeState,
      onStreamReadable = onStreamReadable
    )
    endpoint.start()

    let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)
    let pyFile = pythonFixturePath("quic_live_client_handshake.py")
    let pyProcess = startProcess(
      venvPython,
      args = [pyFile, "127.0.0.1", $serverPort],
      options = {poStdErrToStdOut}
    )

    var pyExit = -1
    let loop = getEventLoop()
    let deadline = epochTime() + 20.0
    while epochTime() < deadline:
      loop.tickBounded()
      pyExit = waitProcessExit(loop, pyProcess, 50)
      if pyExit != -1:
        break

    if pyExit == -1:
      terminate(pyProcess)
      discard pyProcess.waitForExit(2_000)

    let settleDeadline = epochTime() + 1.0
    while epochTime() < settleDeadline:
      loop.tickBounded()
      sleep(2)

    let pyOutput = stdstreams.readAll(pyProcess.outputStream)
    pyProcess.close()
    endpoint.shutdown(closeSocket = true)

    doAssert pyExit == 0,
      "Python aioquic live client (Retry) failed (exit " & $pyExit & "): " & pyOutput
    doAssert "PYTHON_QUIC_LIVE_CLIENT_OK" in pyOutput,
      "Missing Retry live interop success marker: " & pyOutput
    doAssert "PYTHON_QUIC_LIVE_STREAM_ECHO_OK" in pyOutput,
      "Missing Retry stream-echo success marker: " & pyOutput
    doAssert sawOneRtt, "Nim QUIC server (Retry) never reached 1-RTT during live interop"
    doAssert sawStreamReadable, "Nim QUIC server (Retry) did not receive Python stream data during live interop"
    doAssert sentStreamEcho, "Nim QUIC server (Retry) did not send stream echo reply during live interop"

    echo "PASS: Python aioquic live handshake + stream echo with Retry -> Nim QUIC server"

  echo "All live Python QUIC interop tests passed"
else:
  echo "SKIP: Live Python QUIC interop requires -d:useBoringSSL"
