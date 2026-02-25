import cps/runtime
import cps/eventloop
import cps/transform

proc invalidReturnFinally(): CpsVoidFuture {.cps.} =
  try:
    await cpsYield()
  finally:
    return
