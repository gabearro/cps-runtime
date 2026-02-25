## CPS hardening regression tests:
## - non-void fallthrough must fail with CpsContractError
## - cancellation must hard-stop continuation execution

import cps/runtime
import cps/eventloop
import cps/transform

proc missingReturnFast(): CpsFuture[int] {.cps.} =
  discard 123

proc missingReturnSegmented(): CpsFuture[int] {.cps.} =
  await cpsYield()
  discard 456

proc awaitThenMutate(child: CpsVoidFuture, log: ptr seq[string]): CpsVoidFuture {.cps.} =
  await child
  log[].add("after-await-1")
  await cpsYield()
  log[].add("after-await-2")

proc awaitTypedThenMutate(child: CpsFuture[int], log: ptr seq[string]): CpsFuture[int] {.cps.} =
  let v = await child
  log[].add("typed-after-await")
  return v

block testNonVoidFallthroughFastPath:
  proc runner(): CpsFuture[bool] {.cps.} =
    try:
      discard await missingReturnFast()
      return false
    except CpsContractError as e:
      assert e.msg == "CPS contract violation: non-void CPS proc 'missingReturnFast' reached end without return"
      return true

  assert runCps(runner()), "Expected CpsContractError for no-await non-void fallthrough"
  echo "PASS: Non-void fast-path fallthrough fails with CpsContractError"

block testNonVoidFallthroughSegmentedPath:
  proc runner(): CpsFuture[bool] {.cps.} =
    try:
      discard await missingReturnSegmented()
      return false
    except CpsContractError as e:
      assert e.msg == "CPS contract violation: non-void CPS proc 'missingReturnSegmented' reached end without return"
      return true

  assert runCps(runner()), "Expected CpsContractError for segmented non-void fallthrough"
  echo "PASS: Non-void segmented fallthrough fails with CpsContractError"

block testStrictCancelHardStopVoid:
  var log: seq[string] = @[]
  let child = newCpsVoidFuture()
  let parent = awaitThenMutate(child, addr log)

  parent.cancel()
  child.complete()

  let loop = getEventLoop()
  for _ in 0 ..< 4:
    loop.tick()

  assert parent.finished
  assert parent.isCancelled()
  assert log.len == 0, "Cancelled continuation ran post-cancel user code: " & $log
  echo "PASS: Cancelled void continuation hard-stops post-await statements"

block testStrictCancelHardStopTyped:
  var log: seq[string] = @[]
  let child = newCpsFuture[int]()
  let parent = awaitTypedThenMutate(child, addr log)

  parent.cancel()
  child.complete(99)

  let loop = getEventLoop()
  for _ in 0 ..< 4:
    loop.tick()

  assert parent.finished
  assert parent.isCancelled()
  assert log.len == 0, "Cancelled typed continuation ran post-cancel user code: " & $log
  echo "PASS: Cancelled typed continuation hard-stops post-await statements"

block testImmediateSharedFutureCallbacks:
  var typedHits = 0
  let doneTyped = completedFuture[int](42)
  doneTyped.addCallback(proc() =
    inc typedHits
  )
  assert typedHits == 1, "addCallback on completedFuture[T] must fire immediately"

  var voidHits = 0
  let doneVoid = completedVoidFuture()
  doneVoid.addCallback(proc() =
    inc voidHits
  )
  assert voidHits == 1, "addCallback on completedVoidFuture must fire immediately"

  var errHits = 0
  let failedTyped = failedFuture[int](newException(ValueError, "boom"))
  failedTyped.addCallback(proc() =
    inc errHits
  )
  assert errHits == 1, "addCallback on failedFuture[T] must fire immediately"
  assert failedTyped.hasError()
  echo "PASS: Pre-completed shared futures fire callbacks immediately"


echo "All CPS hardening contract tests passed!"
