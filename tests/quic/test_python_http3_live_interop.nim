## Live Python HTTP/3 request interop tests.
##
## Validates real request / response behavior in both directions:
## - Python aioquic client -> Nim HTTP/3 server
## - Nim HTTP/3 client -> Python aioquic server

when defined(useBoringSSL):
  import std/[os, osproc, streams as stdstreams, strutils, times]
  import cps/runtime
  import cps/transform
  import cps/eventloop
  import cps/httpserver
  import cps/httpclient
  import ./interop_helpers

  proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
    ## Prevent indefinite blocking in loop.tick() during interop polling loops.
    discard loop.registerTimer(maxBlockMs, proc() = discard)
    loop.tick()

  proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 50_000) =
    let loop = getEventLoop()
    var ticks = 0
    while not f.finished and ticks < maxTicks:
      loop.tickBounded()
      inc ticks
    doAssert f.finished, "Timed out waiting for CPS future to finish"

  proc runLoopUntilFinished(f: CpsVoidFuture, maxTicks: int = 50_000) =
    let loop = getEventLoop()
    var ticks = 0
    while not f.finished and ticks < maxTicks:
      loop.tickBounded()
      inc ticks
    doAssert f.finished, "Timed out waiting for CPS void future to finish"

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

  proc liveInteropHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    if req.meth == "GET" and req.path == "/":
      return newResponse(200, "nim-live-get-ok", @[("content-type", "text/plain")])
    if req.meth == "POST" and req.path == "/":
      return newResponse(200, "echo:" & req.body, @[("content-type", "text/plain")])
    return newResponse(404, "not-found", @[("content-type", "text/plain")])

  block testPythonClientToNimHttp3ServerLiveRequests:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()

    let server = newHttpServer(
      liveInteropHandler,
      host = "127.0.0.1",
      port = 0,
      useTls = true,
      certFile = certFile,
      keyFile = keyFile,
      enableHttp2 = false,
      enableHttp3 = true,
      quicUseRetry = false
    )
    server.bindAndListen()
    let serverFuture = server.start()
    # Let the server task run enough ticks to start QUIC listener before client launch.
    let startupLoop = getEventLoop()
    for _ in 0 ..< 200:
      startupLoop.tickBounded(2)

    let pyFile = pythonFixturePath("http3_live_client.py")
    let loop = getEventLoop()
    for attempt in 0 ..< 2:
      let pyProcess = startProcess(
        venvPython,
        args = [pyFile, "127.0.0.1", $server.getPort()],
        options = {poStdErrToStdOut}
      )

      var pyExit = -1
      let deadline = epochTime() + 60.0
      while epochTime() < deadline and pyExit == -1:
        loop.tickBounded(10)
        if serverFuture.finished and serverFuture.hasError():
          terminate(pyProcess)
          discard pyProcess.waitForExit(1_000)
          let pyOutput = stdstreams.readAll(pyProcess.outputStream)
          pyProcess.close()
          doAssert false, "Nim HTTP/3 server loop failed: " & serverFuture.getError().msg &
            "\nPython output:\n" & pyOutput
        pyExit = waitProcessExit(loop, pyProcess, 50)
      if pyExit == -1:
        terminate(pyProcess)
        pyExit = pyProcess.waitForExit(5_000)

      let pyOutput = stdstreams.readAll(pyProcess.outputStream)
      pyProcess.close()

      doAssert pyExit == 0,
        "Python HTTP/3 live client failed attempt " & $attempt & " (exit " & $pyExit & "):\n" & pyOutput
      doAssert "PYTHON_H3_LIVE_CLIENT_OK" in pyOutput,
        "Missing live HTTP/3 success marker from Python client attempt " & $attempt & ":\n" & pyOutput
      doAssert "LIVE_GET_STATUS:200" in pyOutput
      doAssert "LIVE_POST_STATUS:200" in pyOutput
      doAssert "LIVE_GET_BODY:nim-live-get-ok" in pyOutput
      doAssert "LIVE_POST_BODY_LEN:4123" in pyOutput
      doAssert "LIVE_POST_BODY_SHA256:" in pyOutput

    let shutdownFut = shutdown(server, drainTimeoutMs = 1_000)
    runLoopUntilFinished(shutdownFut)

    echo "PASS: Python aioquic client -> Nim HTTP/3 server (GET/POST live interop)"

  block testPythonClientToNimHttp3ServerLiveRequestsWithRetry:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()

    let server = newHttpServer(
      liveInteropHandler,
      host = "127.0.0.1",
      port = 0,
      useTls = true,
      certFile = certFile,
      keyFile = keyFile,
      enableHttp2 = false,
      enableHttp3 = true,
      quicUseRetry = true
    )
    server.bindAndListen()
    let serverFuture = server.start()
    let startupLoop = getEventLoop()
    for _ in 0 ..< 200:
      startupLoop.tickBounded(2)

    let pyFile = pythonFixturePath("http3_live_client.py")
    let pyProcess = startProcess(
      venvPython,
      args = [pyFile, "127.0.0.1", $server.getPort()],
      options = {poStdErrToStdOut}
    )

    let loop = getEventLoop()
    var pyExit = -1
    let deadline = epochTime() + 60.0
    while epochTime() < deadline and pyExit == -1:
      loop.tickBounded(10)
      if serverFuture.finished and serverFuture.hasError():
        terminate(pyProcess)
        discard pyProcess.waitForExit(1_000)
        let pyOutput = stdstreams.readAll(pyProcess.outputStream)
        pyProcess.close()
        doAssert false, "Nim HTTP/3 server loop (Retry) failed: " & serverFuture.getError().msg &
          "\nPython output:\n" & pyOutput
      pyExit = waitProcessExit(loop, pyProcess, 50)
    if pyExit == -1:
      terminate(pyProcess)
      pyExit = pyProcess.waitForExit(5_000)

    let pyOutput = stdstreams.readAll(pyProcess.outputStream)
    pyProcess.close()

    doAssert pyExit == 0,
      "Python HTTP/3 live client with Retry failed (exit " & $pyExit & "):\n" & pyOutput
    doAssert "PYTHON_H3_LIVE_CLIENT_OK" in pyOutput,
      "Missing live HTTP/3 success marker from Python client with Retry:\n" & pyOutput
    doAssert "LIVE_GET_STATUS:200" in pyOutput
    doAssert "LIVE_POST_STATUS:200" in pyOutput
    doAssert "LIVE_GET_BODY:nim-live-get-ok" in pyOutput
    doAssert "LIVE_POST_BODY_LEN:4123" in pyOutput
    doAssert "LIVE_POST_BODY_SHA256:" in pyOutput

    let shutdownFut = shutdown(server, drainTimeoutMs = 1_000)
    runLoopUntilFinished(shutdownFut)

    echo "PASS: Python aioquic client -> Nim HTTP/3 server with Retry (GET/POST live interop)"

  block testNimHttp3ClientToPythonServerLiveRequests:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()
    let pyFile = pythonFixturePath("http3_live_server.py")
    let portFile = getTempDir() / ("cps_http3_live_port_" & $int64(epochTime() * 1_000_000.0) & ".txt")
    if fileExists(portFile):
      removeFile(portFile)

    let pyProcess = startProcess(
      venvPython,
      args = [pyFile, certFile, keyFile, portFile],
      options = {poStdErrToStdOut}
    )

    let portLine = waitForFileLine(portFile, timeoutMs = 15_000)
    let port = parseInt(portLine)
    doAssert port > 0, "Python aioquic server returned invalid UDP port: " & portLine

    let postPayload = "nim-live-post-body:" & repeat("z", 4096)
    proc nimClientTask(targetPort: int): CpsFuture[(HttpsResponse, HttpsResponse)] {.cps.} =
      let client = newHttpsClient(
        preferHttp3 = true,
        forceHttp3 = true,
        http3FallbackToHttp2 = false,
        http3EnableDatagram = true,
        http3Enable0Rtt = true,
        http3VerifyPeer = true,
        http3CaFile = certFile,
        userAgent = "",
        autoDecompress = false
      )
      let baseUrl = "https://127.0.0.1:" & $targetPort
      let getResp = await client.get(baseUrl & "/")
      let postResp = await client.post(baseUrl & "/", postPayload)
      client.close()
      return (getResp, postResp)

    proc nimClientConcurrentTask(targetPort: int): CpsFuture[(HttpsResponse, HttpsResponse)] {.cps.} =
      let client = newHttpsClient(
        preferHttp3 = true,
        forceHttp3 = true,
        http3FallbackToHttp2 = false,
        http3EnableDatagram = true,
        http3Enable0Rtt = true,
        http3VerifyPeer = true,
        http3CaFile = certFile,
        userAgent = "",
        autoDecompress = false
      )
      let baseUrl = "https://127.0.0.1:" & $targetPort
      let getFuture = client.get(baseUrl & "/")
      let postFuture = client.post(baseUrl & "/", postPayload)
      let getResp = await getFuture
      let postResp = await postFuture
      client.close()
      return (getResp, postResp)

    let cf = nimClientTask(port)
    runLoopUntilFinished(cf)
    let cfConcurrent = nimClientConcurrentTask(port)
    runLoopUntilFinished(cfConcurrent)

    var pyOutput = ""
    if peekExitCode(pyProcess) == -1:
      terminate(pyProcess)
      discard pyProcess.waitForExit(2_000)
    pyOutput = stdstreams.readAll(pyProcess.outputStream)
    pyProcess.close()
    if fileExists(portFile):
      removeFile(portFile)

    doAssert not cf.hasError(),
      "Nim HTTP/3 client live interop failed: " & (if cf.hasError(): cf.getError().msg else: "") &
      "\nPython output:\n" & pyOutput

    doAssert not cfConcurrent.hasError(),
      "Nim HTTP/3 concurrent live interop failed: " &
      (if cfConcurrent.hasError(): cfConcurrent.getError().msg else: "") &
      "\nPython output:\n" & pyOutput

    let (getResp, postResp) = cf.read()
    doAssert getResp.statusCode == 200
    doAssert getResp.body == "python-live-get-ok"
    doAssert getResp.httpVersion == hvHttp3
    doAssert postResp.statusCode == 200
    doAssert postResp.body == "echo:" & postPayload
    doAssert postResp.httpVersion == hvHttp3

    let (concurrentGetResp, concurrentPostResp) = cfConcurrent.read()
    doAssert concurrentGetResp.statusCode == 200
    doAssert concurrentGetResp.body == "python-live-get-ok"
    doAssert concurrentGetResp.httpVersion == hvHttp3
    doAssert concurrentPostResp.statusCode == 200
    doAssert concurrentPostResp.body == "echo:" & postPayload
    doAssert concurrentPostResp.httpVersion == hvHttp3

    echo "PASS: Nim HTTP/3 client -> Python aioquic server (GET/POST live interop)"

  block testNimHttp3ClientRejectsUntrustedPythonServerCert:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()
    let pyFile = pythonFixturePath("http3_live_server.py")
    let portFile = getTempDir() / ("cps_http3_live_untrusted_port_" & $int64(epochTime() * 1_000_000.0) & ".txt")
    if fileExists(portFile):
      removeFile(portFile)

    let pyProcess = startProcess(
      venvPython,
      args = [pyFile, certFile, keyFile, portFile],
      options = {poStdErrToStdOut}
    )

    let portLine = waitForFileLine(portFile, timeoutMs = 15_000)
    let port = parseInt(portLine)
    doAssert port > 0, "Python aioquic server returned invalid UDP port: " & portLine

    proc nimClientTask(targetPort: int): CpsFuture[HttpsResponse] {.cps.} =
      let client = newHttpsClient(
        preferHttp3 = true,
        forceHttp3 = true,
        http3FallbackToHttp2 = false,
        http3EnableDatagram = true,
        http3Enable0Rtt = true,
        http3VerifyPeer = true,
        # Intentionally do not trust the self-signed test cert.
        http3CaFile = "",
        userAgent = "",
        autoDecompress = false
      )
      let baseUrl = "https://127.0.0.1:" & $targetPort
      let resp = await client.get(baseUrl & "/")
      client.close()
      return resp

    let cf = nimClientTask(port)
    var bootstrapErr = ""
    try:
      runLoopUntilFinished(cf)
    except CatchableError as e:
      bootstrapErr = e.msg

    var pyOutput = ""
    if peekExitCode(pyProcess) == -1:
      terminate(pyProcess)
      discard pyProcess.waitForExit(2_000)
    pyOutput = stdstreams.readAll(pyProcess.outputStream)
    pyProcess.close()
    if fileExists(portFile):
      removeFile(portFile)

    doAssert cf.hasError() or bootstrapErr.len > 0,
      "Expected HTTP/3 client to reject untrusted certificate, but request succeeded.\nPython output:\n" & pyOutput

    let errMsg =
      if cf.finished and cf.hasError():
        cf.getError().msg
      else:
        bootstrapErr
    doAssert errMsg.len > 0

    echo "PASS: Nim HTTP/3 client rejects untrusted Python aioquic server certificate"

  block testNimHttp3ClientToPythonServerLiveRequestsWithRetry:
    let venvPython = ensureAioquicVenv()
    let (certFile, keyFile) = generateTestCert()
    let pyFile = pythonFixturePath("http3_live_server.py")
    let portFile = getTempDir() / ("cps_http3_live_retry_port_" & $int64(epochTime() * 1_000_000.0) & ".txt")
    if fileExists(portFile):
      removeFile(portFile)

    let pyProcess = startProcess(
      venvPython,
      args = [pyFile, certFile, keyFile, portFile, "--retry"],
      options = {poStdErrToStdOut}
    )

    let portLine = waitForFileLine(portFile, timeoutMs = 15_000)
    let port = parseInt(portLine)
    doAssert port > 0, "Python aioquic Retry server returned invalid UDP port: " & portLine

    let postPayload = "nim-live-post-retry-body:" & repeat("r", 2048)
    proc nimClientTask(targetPort: int): CpsFuture[(HttpsResponse, HttpsResponse)] {.cps.} =
      let client = newHttpsClient(
        preferHttp3 = true,
        forceHttp3 = true,
        http3FallbackToHttp2 = false,
        http3EnableDatagram = true,
        http3Enable0Rtt = true,
        http3VerifyPeer = true,
        http3CaFile = certFile,
        userAgent = "",
        autoDecompress = false
      )
      let baseUrl = "https://127.0.0.1:" & $targetPort
      let getResp = await client.get(baseUrl & "/")
      let postResp = await client.post(baseUrl & "/", postPayload)
      client.close()
      return (getResp, postResp)

    let cf = nimClientTask(port)
    runLoopUntilFinished(cf)

    var pyOutput = ""
    if peekExitCode(pyProcess) == -1:
      terminate(pyProcess)
      discard pyProcess.waitForExit(2_000)
    pyOutput = stdstreams.readAll(pyProcess.outputStream)
    pyProcess.close()
    if fileExists(portFile):
      removeFile(portFile)

    doAssert not cf.hasError(),
      "Nim HTTP/3 client live interop with Retry failed: " &
      (if cf.hasError(): cf.getError().msg else: "") &
      "\nPython output:\n" & pyOutput

    let (getResp, postResp) = cf.read()
    doAssert getResp.statusCode == 200
    doAssert getResp.body == "python-live-get-ok"
    doAssert getResp.httpVersion == hvHttp3
    doAssert postResp.statusCode == 200
    doAssert postResp.body == "echo:" & postPayload
    doAssert postResp.httpVersion == hvHttp3

    echo "PASS: Nim HTTP/3 client -> Python aioquic server with Retry (GET/POST live interop)"

  echo "All live Python HTTP/3 interop tests passed"
else:
  echo "SKIP: Live Python HTTP/3 interop requires -d:useBoringSSL"
