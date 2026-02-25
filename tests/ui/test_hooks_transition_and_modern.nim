import std/[strutils, hashes]
import cps/ui

type
  Store = ref object
    value: int
    subs: seq[proc() {.closure.}]

var
  store = Store(value: 1, subs: @[])
  setCountProc: proc(next: int) {.closure.}
  startTransitionProc: proc(work: proc() {.closure.}) {.closure.}
  firstSeenId = ""
  lastSeenId = ""

proc storeSubscribe(cb: proc() {.closure.}): proc() {.closure.} =
  if cb != nil:
    store.subs.add cb

  proc unsubscribe() =
    if cb == nil:
      return
    var kept: seq[proc() {.closure.}] = @[]
    for fn in store.subs:
      if fn != cb:
        kept.add fn
    store.subs = kept

  unsubscribe

proc storeSnapshot(): int =
  store.value

proc setStore(next: int) =
  store.value = next
  for cb in store.subs:
    if cb != nil:
      cb()

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let value = firstText(child)
    if value.len > 0:
      return value
  ""

proc app(): VNode =
  let id = useId()
  if firstSeenId.len == 0:
    firstSeenId = id
  lastSeenId = id

  let (count, setCount) = useState(0)
  setCountProc = setCount

  let deferred = useDeferredValue(count)
  let (pending, startTx) = useTransition()
  startTransitionProc = startTx

  let handleRef = useRef(0)
  useImperativeHandle[int](handleRef, proc(): int = count * 10, @[hash(count).uint64])

  let external = useSyncExternalStore[int](storeSubscribe, storeSnapshot)

  element("span", children = @[
    text($count & ":" & $deferred & ":" & $pending & ":" & $handleRef.current & ":" & $external)
  ])

block testModernHooks:
  mount("#app", app)

  assert firstSeenId.len > 0
  assert firstSeenId == lastSeenId
  assert firstText(currentTree()).startsWith("0:0:")

  startTransitionProc(proc() =
    setCountProc(5)
  )

  var spins = 0
  while isFlushPending() and spins < 8:
    inc spins
    runPendingFlush()

  assert firstText(currentTree()).startsWith("5:5:")
  assert firstText(currentTree()).contains(":50:")

  setStore(7)
  if isFlushPending():
    runPendingFlush()

  assert firstText(currentTree()).endsWith(":7")

  setCountProc(6)
  runPendingFlush()
  assert firstSeenId == lastSeenId

  unmount()

echo "PASS: transition/deferred/id/syncExternalStore/imperativeHandle hooks behave deterministically"
