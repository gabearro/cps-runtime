## Tests that raceCancel on peer read/write/keepalive loops
## causes the peer to disconnect when ANY loop fails, not just readLoop.

import cps/runtime
import cps/transform
import cps/eventloop

# Simulate the peer loop pattern: three concurrent CPS tasks, raceCancel
# should complete (and cancel others) when any one fails.

var loopACompleted = false
var loopBCompleted = false
var loopCCompleted = false

proc loopA(): CpsVoidFuture {.cps.} =
  ## Simulates readLoop: runs forever (never completes on its own)
  while true:
    await cpsSleep(100000)

proc loopB(): CpsVoidFuture {.cps.} =
  ## Simulates writeLoop: fails after a short time (socket error)
  await cpsSleep(50)
  raise newException(IOError, "write socket error")

proc loopC(): CpsVoidFuture {.cps.} =
  ## Simulates keepAliveLoop: runs forever
  while true:
    await cpsSleep(100000)

block: # raceCancel propagates writeLoop failure
  var raceError = ""
  proc testRace(): CpsVoidFuture {.cps.} =
    let futA = loopA()
    let futB = loopB()
    let futC = loopC()
    try:
      await raceCancel(futA, futB, futC)
    except CatchableError as e:
      raceError = e.msg

  runCps(testRace())

  assert raceError == "write socket error",
    "raceCancel should propagate writeLoop error, got: '" & raceError & "'"
  echo "PASS: raceCancel propagates writeLoop failure"

block: # raceCancel completes when keepAliveLoop fails
  var raceError2 = ""

  proc loopKaFail(): CpsVoidFuture {.cps.} =
    await cpsSleep(50)
    raise newException(IOError, "keepalive timeout")

  proc testRace2(): CpsVoidFuture {.cps.} =
    let futA = loopA()
    let futC = loopC()
    let futKa = loopKaFail()
    try:
      await raceCancel(futA, futC, futKa)
    except CatchableError as e:
      raceError2 = e.msg

  runCps(testRace2())

  assert raceError2 == "keepalive timeout",
    "raceCancel should propagate keepalive error, got: '" & raceError2 & "'"
  echo "PASS: raceCancel propagates keepAliveLoop failure"

block: # raceCancel completes normally when readLoop ends gracefully
  proc loopReadDone(): CpsVoidFuture {.cps.} =
    await cpsSleep(50)
    # Graceful completion (peer closed connection)

  var raceError3 = ""
  var raceCompleted = false
  proc testRace3(): CpsVoidFuture {.cps.} =
    let futRead = loopReadDone()
    let futWrite = loopC()
    let futKa = loopC()
    try:
      await raceCancel(futRead, futWrite, futKa)
      raceCompleted = true
    except CatchableError as e:
      raceError3 = e.msg

  runCps(testRace3())

  assert raceCompleted, "raceCancel should complete when readLoop ends"
  assert raceError3 == "", "no error expected on graceful completion"
  echo "PASS: raceCancel completes normally on readLoop end"

echo "ALL PEER RACE LOOP TESTS PASSED"
