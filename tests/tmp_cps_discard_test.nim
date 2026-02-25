import cps/runtime
import cps/transform
import cps/eventloop

var hit = false

proc foo(): CpsVoidFuture {.cps.} =
  await cpsSleep(10)
  hit = true

when isMainModule:
  discard foo()
  let loop = getEventLoop()
  for _ in 0 ..< 20:
    loop.tick()
  echo hit
