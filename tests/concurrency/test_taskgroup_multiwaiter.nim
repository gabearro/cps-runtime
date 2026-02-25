## TaskGroup multi-waiter regression tests.

import cps/runtime
import cps/eventloop
import cps/transform
import cps/concurrency/taskgroup

proc shortTask(): CpsVoidFuture {.cps.} =
  await cpsSleep(20)

proc failTask(msg: string): CpsVoidFuture {.cps.} =
  await cpsYield()
  raise newException(ValueError, msg)

block testTwoConcurrentWaiters:
  let group = newTaskGroup()
  group.spawn(shortTask())
  group.spawn(shortTask())

  let w1 = group.wait()
  let w2 = group.wait()

  runCps(waitAll(w1, w2))
  assert w1.finished and not w1.hasError()
  assert w2.finished and not w2.hasError()
  echo "PASS: Multiple concurrent wait() callers all resolve"

block testWaitAndWaitAllTogether:
  let group = newTaskGroup(epCollectAll)
  group.spawn(failTask("boom"))

  let waitFut = group.wait()
  let allFut = group.waitAll()

  runCps(waitFut)
  let errs = runCps(allFut)

  assert waitFut.finished and waitFut.hasError(), "wait() should reflect group failure"
  assert errs.len == 1 and errs[0].msg == "boom",
    "waitAll() should still resolve with collected errors"
  echo "PASS: wait() and waitAll() can observe completion concurrently"


echo "All TaskGroup multi-waiter tests passed!"
