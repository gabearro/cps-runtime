import cps/ui

type
  Store = ref object
    value: int
    subs: seq[proc() {.closure.}]

var
  storeA = Store(value: 10, subs: @[])
  storeB = Store(value: 20, subs: @[])
  setUseAProc: proc(next: bool) {.closure.}

proc subscribeStore(s: Store, cb: proc() {.closure.}): proc() {.closure.} =
  if cb != nil:
    s.subs.add cb

  proc unsubscribe() =
    var keep: seq[proc() {.closure.}] = @[]
    for fn in s.subs:
      if fn != cb:
        keep.add fn
    s.subs = keep

  unsubscribe

proc bumpStore(s: Store, next: int) =
  s.value = next
  for cb in s.subs:
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
  let (useA, setUseA) = useState(true)
  setUseAProc = setUseA

  let snapshot = useSyncExternalStore[int](
    proc(cb: proc() {.closure.}): proc() {.closure.} =
      if useA:
        subscribeStore(storeA, cb)
      else:
        subscribeStore(storeB, cb),
    proc(): int =
      if useA:
        storeA.value
      else:
        storeB.value
  )

  text((if useA: "A" else: "B") & ":" & $snapshot)

block testSyncExternalStoreResubscribe:
  mount("#app", app)

  assert firstText(currentTree()) == "A:10"

  setUseAProc(false)
  runPendingFlush()
  assert firstText(currentTree()) == "B:20"

  bumpStore(storeB, 99)
  if isFlushPending():
    runPendingFlush()
  assert firstText(currentTree()) == "B:99"

  bumpStore(storeA, 77)
  if isFlushPending():
    runPendingFlush()
  assert firstText(currentTree()) == "B:99"

  unmount()

echo "PASS: useSyncExternalStore re-subscribes when subscribe/getSnapshot change"
