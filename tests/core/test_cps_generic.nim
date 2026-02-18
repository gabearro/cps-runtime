## Tests for generic CPS procs

import cps/runtime
import cps/transform
import cps/eventloop

# Helper: create a pre-completed future
proc makeValue[T](x: T): CpsFuture[T] =
  let f = newCpsFuture[T]()
  f.complete(x)
  return f

# Helper: create a deferred future (completes on next event loop tick)
proc deferredValue[T](x: T): CpsFuture[T] =
  let f = newCpsFuture[T]()
  proc factory(val: T, fut: CpsFuture[T]): proc() =
    return proc() = fut.complete(val)
  scheduleCallback(factory(x, f))
  return f

# Test 1: Simple generic identity (no await)
proc identity[T](x: T): CpsFuture[T] {.cps.} =
  return x

block testGenericIdentity:
  let intFut = identity[int](42)
  assert intFut.finished
  assert intFut.read() == 42

  let strFut = identity[string]("hello")
  assert strFut.finished
  assert strFut.read() == "hello"

  let floatFut = identity[float](3.14)
  assert floatFut.finished
  assert floatFut.read() == 3.14

  echo "PASS: Generic identity (no await)"

# Test 2: Generic with await (pre-completed)
proc awaitIdentity[T](x: T): CpsFuture[T] {.cps.} =
  let val: T = await makeValue[T](x)
  return val

block testGenericAwait:
  let intFut = awaitIdentity[int](99)
  assert intFut.finished
  assert intFut.read() == 99

  let strFut = awaitIdentity[string]("world")
  assert strFut.finished
  assert strFut.read() == "world"

  echo "PASS: Generic with await (pre-completed)"

# Test 3: Generic with deferred await
proc deferredIdentity[T](x: T): CpsFuture[T] {.cps.} =
  let val: T = await deferredValue[T](x)
  return val

block testGenericDeferredAwait:
  let intFut = deferredIdentity[int](77)
  assert not intFut.finished
  let intResult = runCps(intFut)
  assert intResult == 77

  let strFut = deferredIdentity[string]("deferred")
  assert not strFut.finished
  let strResult = runCps(strFut)
  assert strResult == "deferred"

  echo "PASS: Generic with deferred await"

# Test 4: Generic with type constraint
proc addValues[T: SomeNumber](a: T, b: T): CpsFuture[T] {.cps.} =
  return a + b

block testGenericConstraint:
  let intFut = addValues[int](3, 4)
  assert intFut.finished
  assert intFut.read() == 7

  let floatFut = addValues[float](1.5, 2.5)
  assert floatFut.finished
  assert floatFut.read() == 4.0

  echo "PASS: Generic with type constraint"

# Test 5: Generic with multiple type params
proc makePair[A, B](a: A, b: B): CpsFuture[(A, B)] {.cps.} =
  return (a, b)

block testGenericMultipleParams:
  let fut = makePair[int, string](42, "hello")
  assert fut.finished
  let pair = fut.read()
  assert pair[0] == 42
  assert pair[1] == "hello"

  let fut2 = makePair[string, float]("pi", 3.14)
  assert fut2.finished
  let pair2 = fut2.read()
  assert pair2[0] == "pi"
  assert pair2[1] == 3.14

  echo "PASS: Generic with multiple type params"

# Test 6: Generic void proc
var genericSideEffect = 0

proc setGenericValue[T](x: T): CpsVoidFuture {.cps.} =
  genericSideEffect = 1

block testGenericVoid:
  genericSideEffect = 0
  let fut = setGenericValue[int](42)
  assert fut.finished
  assert genericSideEffect == 1

  echo "PASS: Generic void proc"

# Test 7: Generic with multiple sequential awaits
proc doubleAwait[T](a: T, b: T): CpsFuture[T] {.cps.} =
  let x: T = await makeValue[T](a)
  let y: T = await makeValue[T](b)
  return x

block testGenericMultipleAwaits:
  let fut = doubleAwait[int](10, 20)
  assert fut.finished
  assert fut.read() == 10

  let fut2 = doubleAwait[string]("first", "second")
  assert fut2.finished
  assert fut2.read() == "first"

  echo "PASS: Generic with multiple sequential awaits"

# Test 8: Generic with if/else (no await in branches)
proc genericMax[T: SomeNumber](a: T, b: T): CpsFuture[T] {.cps.} =
  if a > b:
    return a
  else:
    return b

block testGenericIfElse:
  let fut = genericMax[int](10, 20)
  assert fut.finished
  assert fut.read() == 20

  let fut2 = genericMax[float](3.14, 2.71)
  assert fut2.finished
  assert fut2.read() == 3.14

  echo "PASS: Generic with if/else"

echo "All generic CPS tests passed!"
