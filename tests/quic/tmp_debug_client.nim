when defined(useBoringSSL):
  import std/[osproc, streams as stdstreams, strutils]
  import cps/runtime
  import cps/transform
  import cps/eventloop
  import cps/httpclient
  import ./interop_helpers

  proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
    discard loop.registerTimer(maxBlockMs, proc() = discard)
    loop.tick()

  proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 50_000) =
    let loop = getEventLoop()
    var ticks = 0
    while not f.finished and ticks < maxTicks:
      loop.tickBounded()
      inc ticks
    doAssert f.finished

  let venvPython = ensureAioquicVenv()
  let (certFile, keyFile) = generateTestCert()
  let pyFile = pythonFixturePath("http3_live_server.py")
  let pyProcess = startProcess(
    venvPython,
    args = [pyFile, certFile, keyFile],
    options = {poStdErrToStdOut}
  )

  let portLine = waitForLine(pyProcess, "PORT:")
  echo "portLine=", portLine
  let port = parseInt(portLine.split("PORT:")[1].strip())
  echo "port=", port

  proc nimClientTask(targetPort: int): CpsFuture[(HttpsResponse, HttpsResponse)] {.cps.} =
    let client = newHttpsClient(
      preferHttp3 = true,
      forceHttp3 = true,
      http3FallbackToHttp2 = false,
      http3EnableDatagram = true,
      http3Enable0Rtt = true,
      userAgent = "",
      autoDecompress = false
    )
    let baseUrl = "https://127.0.0.1:" & $targetPort
    echo "baseUrl=", baseUrl
    let getResp = await client.get(baseUrl & "/")
    echo "after GET baseUrl=", baseUrl
    let postResp = await client.post(baseUrl & "/", "nim-live-post-body")
    client.close()
    return (getResp, postResp)

  let cf = nimClientTask(port)
  runLoopUntilFinished(cf)
  if cf.hasError:
    echo "ERROR=", cf.getError().msg
  else:
    let (g,p) = cf.read()
    echo "GET=", g.statusCode, " ", g.body, " ", $g.httpVersion
    echo "POST=", p.statusCode, " ", p.body, " ", $p.httpVersion

  if peekExitCode(pyProcess) == -1:
    terminate(pyProcess)
    discard pyProcess.waitForExit(2000)
  echo "pyOut=\n", stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
else:
  echo "need -d:useBoringSSL"
