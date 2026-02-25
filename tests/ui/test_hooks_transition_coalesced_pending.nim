import cps/ui

var
  setCountProc: proc(next: int) {.closure.}
  startTransitionProc: proc(work: proc() {.closure.}) {.closure.}

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
  let (count, setCount) = useState(0)
  setCountProc = setCount
  let (_, startTx) = useTransition()
  startTransitionProc = startTx
  text($count)

block testCoalescedTransitionsClearPendingState:
  mount("#app", app)
  assert firstText(currentTree()) == "0"
  assert not hasPendingTransitions()

  startTransitionProc(proc() = setCountProc(1))
  startTransitionProc(proc() = setCountProc(2))

  assert hasPendingTransitions()
  assert isFlushPending()

  runPendingFlush()
  assert firstText(currentTree()) == "2"
  assert not hasPendingTransitions()

  while isFlushPending():
    runPendingFlush()
  assert not hasPendingTransitions()

  unmount()

echo "PASS: coalesced transitions clear pending state after transition commit"
