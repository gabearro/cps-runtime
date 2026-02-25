import cps/runtime
import cps/eventloop
import cps/transform

proc invalidBreakFinally(): CpsVoidFuture {.cps.} =
  while true:
    try:
      await cpsYield()
    finally:
      break
