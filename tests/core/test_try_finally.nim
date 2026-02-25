## Tests for CPS try/finally support with await

import cps/runtime
import cps/eventloop
import cps/transform

proc failNow(msg: string): CpsVoidFuture {.cps.} =
  raise newException(ValueError, msg)

block testTryFinallySuccessPath:
  proc main(): CpsFuture[seq[string]] {.cps.} =
    var log: seq[string] = @[]
    try:
      log.add("try-start")
      await cpsYield()
      log.add("try-end")
    finally:
      log.add("finally")
    return log

  let log = runCps(main())
  assert log == @["try-start", "try-end", "finally"], "Unexpected try/finally success log: " & $log
  echo "PASS: try/finally runs finally on success"

block testTryFinallyExceptionPath:
  var log: seq[string] = @[]

  proc failingMain(): CpsVoidFuture {.cps.} =
    try:
      log.add("try")
      await failNow("boom")
      log.add("after-fail")
    finally:
      log.add("finally")

  proc runner(): CpsFuture[bool] {.cps.} =
    try:
      await failingMain()
      return false
    except ValueError:
      return true

  let caught = runCps(runner())
  assert caught, "ValueError should propagate through try/finally and be catchable by caller"
  assert log == @["try", "finally"], "finally should run before propagation; got: " & $log
  echo "PASS: try/finally runs finally on exception propagation path"

block testAwaitInFinally:
  proc main(): CpsFuture[seq[string]] {.cps.} =
    var log: seq[string] = @[]
    try:
      log.add("try")
      await cpsYield()
    finally:
      log.add("finally-before-await")
      await cpsYield()
      log.add("finally-after-await")
    return log

  let log = runCps(main())
  assert log == @["try", "finally-before-await", "finally-after-await"],
    "Unexpected await-in-finally log: " & $log
  echo "PASS: await in finally is supported"

block testTryExceptFinally:
  proc main(raiseInTry: bool): CpsFuture[seq[string]] {.cps.} =
    var log: seq[string] = @[]
    try:
      log.add("try")
      await cpsYield()
      if raiseInTry:
        raise newException(ValueError, "boom")
      log.add("try-end")
    except ValueError:
      log.add("except")
    finally:
      log.add("finally")
      await cpsYield()
    return log

  let okLog = runCps(main(false))
  assert okLog == @["try", "try-end", "finally"],
    "Unexpected try/except/finally success log: " & $okLog

  let errLog = runCps(main(true))
  assert errLog == @["try", "except", "finally"],
    "Unexpected try/except/finally exception log: " & $errLog
  echo "PASS: try/except/finally executes in CPS"

static:
  let badReturnFinally = compiles:
    proc invalidReturnFinally(): CpsVoidFuture {.cps.} =
      try:
        await cpsYield()
      finally:
        return

  let badBreakFinally = compiles:
    proc invalidBreakFinally(): CpsVoidFuture {.cps.} =
      while true:
        try:
          await cpsYield()
        finally:
          break

  let badContinueFinally = compiles:
    proc invalidContinueFinally(): CpsVoidFuture {.cps.} =
      while true:
        try:
          await cpsYield()
        finally:
          continue

  let goodExceptFinally = compiles:
    proc validExceptFinally(): CpsVoidFuture {.cps.} =
      try:
        await cpsYield()
      except ValueError:
        discard
      finally:
        discard

  doAssert not badReturnFinally, "return inside finally should be rejected at compile time"
  doAssert not badBreakFinally, "break inside finally should be rejected at compile time"
  doAssert not badContinueFinally, "continue inside finally should be rejected at compile time"
  doAssert goodExceptFinally, "try/except/finally form should compile in CPS"

echo "All try/finally tests passed!"
