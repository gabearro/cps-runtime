when defined(useBoringSSL):
  import std/[osproc, streams as stdstreams, strutils]
  import cps/runtime
  import cps/transform
  import cps/eventloop
  import cps/http/client/http3
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
  let pyProcess = startProcess(venvPython, args = [pyFile, certFile, keyFile], options = {poStdErrToStdOut})
  let portLine = waitForLine(pyProcess, "PORT:")
  let port = parseInt(portLine.split("PORT:")[1].strip())
  echo "port=", port

  proc reqTask(p: int): CpsFuture[Http3ClientResponse] {.cps.} =
    let emptyHeaders: seq[(string, string)] = @[]
    let r = await doHttp3Request(host="127.0.0.1", port=p, meth="GET", path="/", authority="127.0.0.1:" & $p, headers=emptyHeaders, body="")
    return r

  let f = reqTask(port)
  runLoopUntilFinished(f)
  if f.hasError:
    echo "ERR=", f.getError().msg
  else:
    let r = f.read()
    echo "OK=", r.statusCode, " ", r.body

  if peekExitCode(pyProcess) == -1:
    terminate(pyProcess)
    discard pyProcess.waitForExit(2000)
  echo stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
else:
  echo "need boring"
