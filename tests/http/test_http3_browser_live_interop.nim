## Live browser HTTP/3 interop against a local CPS endpoint.
##
## Starts a Nim HTTP/3 server, runs the Playwright browser fixture against it,
## and asserts negotiated h3 plus live GET/POST fetch results.

when defined(useBoringSSL):
  import std/[os, osproc, streams as stdstreams, strutils, times]
  import cps/runtime
  import cps/transform
  import cps/eventloop
  import cps/httpserver
  import cps/httpclient
  import ../quic/interop_helpers

  proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
    discard loop.registerTimer(maxBlockMs, proc() = discard)
    loop.tick()

  proc runLoopUntilFinished(f: CpsVoidFuture, maxTicks: int = 60_000) =
    let loop = getEventLoop()
    var ticks = 0
    while not f.finished and ticks < maxTicks:
      loop.tickBounded()
      inc ticks
    doAssert f.finished, "Timed out waiting for CPS future to finish"

  proc waitProcessExit(loop: EventLoop, p: Process, timeoutMs: int): int =
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while epochTime() < deadline:
      let code = peekExitCode(p)
      if code != -1:
        return p.waitForExit(100)
      loop.tickBounded()
      sleep(2)
    -1

  proc browserInteropHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    if req.meth == "GET" and req.path == "/live-get":
      return newResponse(200, "nim-browser-live-get-ok", @[("content-type", "text/plain")])
    if req.meth == "POST" and req.path == "/live-post":
      return newResponse(200, "echo:" & req.body, @[("content-type", "text/plain")])
    return newResponse(404, "not-found", @[("content-type", "text/plain")])

  proc certSpkiPin(certFile: string): string =
    let sh = "openssl x509 -in " & quoteShell(certFile) & " -pubkey -noout | " &
      "openssl pkey -pubin -outform DER | " &
      "openssl dgst -sha256 -binary | openssl enc -base64"
    result = execProcess("bash -lc " & quoteShell(sh)).strip()
    doAssert result.len > 0, "Failed to derive cert SPKI pin for browser interop"

  block testBrowserToNimHttp3ServerLiveRequests:
    let (certFile, keyFile) = generateTestCert()
    let certPin = certSpkiPin(certFile)

    let server = newHttpServer(
      browserInteropHandler,
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
    let startupLoop = getEventLoop()
    for _ in 0 ..< 200:
      startupLoop.tickBounded(2)

    proc probeServerHttp3(port: int): CpsVoidFuture {.cps.} =
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
      let probeResp = await client.get("https://127.0.0.1:" & $port & "/live-get")
      client.close()
      doAssert probeResp.statusCode == 200
      doAssert probeResp.body == "nim-browser-live-get-ok"
      doAssert probeResp.httpVersion == hvHttp3

    let probeFuture = probeServerHttp3(server.getPort())
    runLoopUntilFinished(probeFuture)
    doAssert not probeFuture.hasError(),
      "Local HTTP/3 readiness probe failed: " &
      (if probeFuture.hasError(): probeFuture.getError().msg else: "")

    let script = getCurrentDir() / "tests" / "http" / "browser" / "run_playwright_http3.sh"
    doAssert fileExists(script), "Missing browser interop script: " & script

    let postPayload = "browser-live-post-body-1234567890"
    let cmd = "cd tests/http/browser && " &
      "CPS_HTTP3_INTEROP_URL=https://127.0.0.1:" & $server.getPort() & "/live-get " &
      "CPS_HTTP3_EXPECTED_PROTOCOL=h3 " &
      "CPS_HTTP3_REQUIRE_TARGET=1 " &
      "CPS_HTTP3_REQUIRE_WEBTRANSPORT=1 " &
      "CPS_HTTP3_ALLOW_INSECURE_CERTS=1 " &
      "CPS_HTTP3_IGNORE_CERT_SPKI=" & certPin & " " &
      "CPS_HTTP3_LIVE_MODE=1 " &
      "CPS_HTTP3_LIVE_GET_PATH=/live-get " &
      "CPS_HTTP3_LIVE_POST_PATH=/live-post " &
      "CPS_HTTP3_LIVE_POST_BODY=" & postPayload & " " &
      "CPS_HTTP3_LIVE_EXPECT_GET_BODY=nim-browser-live-get-ok " &
      "CPS_HTTP3_LIVE_EXPECT_POST_BODY=echo:" & postPayload & " " &
      "bash run_playwright_http3.sh"

    let browserProcess = startProcess(
      "bash",
      args = ["-lc", cmd],
      options = {poStdErrToStdOut, poUsePath}
    )

    let loop = getEventLoop()
    var browserExit = -1
    let deadline = epochTime() + 300.0
    while epochTime() < deadline and browserExit == -1:
      loop.tickBounded(10)
      if serverFuture.finished and serverFuture.hasError():
        terminate(browserProcess)
        discard browserProcess.waitForExit(1_000)
        let browserOutput = stdstreams.readAll(browserProcess.outputStream)
        browserProcess.close()
        doAssert false, "Nim HTTP/3 server loop failed: " & serverFuture.getError().msg &
          "\nBrowser output:\n" & browserOutput
      browserExit = waitProcessExit(loop, browserProcess, 50)
    if browserExit == -1:
      terminate(browserProcess)
      browserExit = browserProcess.waitForExit(10_000)

    let browserOutput = stdstreams.readAll(browserProcess.outputStream)
    browserProcess.close()

    doAssert browserExit == 0,
      "Browser HTTP/3 live interop failed (exit " & $browserExit & "):\n" & browserOutput
    doAssert "PASS: Browser negotiated h3" in browserOutput, browserOutput
    doAssert "LIVE_GET_STATUS:200" in browserOutput, browserOutput
    doAssert "LIVE_POST_STATUS:200" in browserOutput, browserOutput
    doAssert "LIVE_GET_BODY:nim-browser-live-get-ok" in browserOutput, browserOutput
    doAssert ("LIVE_POST_BODY:echo:" & postPayload) in browserOutput, browserOutput
    doAssert "PASS: Browser live HTTP/3 fetch GET/POST checks" in browserOutput, browserOutput

    let shutdownFut = shutdown(server, drainTimeoutMs = 1_000)
    runLoopUntilFinished(shutdownFut)

    echo "PASS: Browser Chromium -> Nim HTTP/3 server (GET/POST live interop)"

  echo "All browser live HTTP/3 interop tests passed"
else:
  echo "SKIP: Browser live HTTP/3 interop requires -d:useBoringSSL"
