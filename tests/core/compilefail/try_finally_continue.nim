import cps/runtime
import cps/eventloop
import cps/transform

proc invalidContinueFinally(): CpsVoidFuture {.cps.} =
  while true:
    try:
      await cpsYield()
    finally:
      continue
