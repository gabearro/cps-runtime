import cps/runtime
import cps/eventloop
import cps/transform

proc invalidExceptFinally(): CpsVoidFuture {.cps.} =
  try:
    await cpsYield()
  except ValueError:
    discard
  finally:
    discard
