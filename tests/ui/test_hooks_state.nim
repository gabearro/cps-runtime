import cps/ui

var
  renderCount = 0
  setCountProc: proc(next: int) {.closure.}

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let t = firstText(child)
    if t.len > 0:
      return t
  ""

proc app(): VNode =
  inc renderCount
  let (count, setCount) = useState(0)
  setCountProc = setCount
  element("span", children = @[text($count)])

block testUseStateAndBatching:
  mount("#app", app)
  assert renderCount == 1
  assert firstText(currentTree()) == "0"

  setCountProc(1)
  setCountProc(2)
  assert isFlushPending()
  assert renderCount == 1

  runPendingFlush()
  assert renderCount == 2
  assert firstText(currentTree()) == "2"

  unmount()

echo "PASS: useState updates are batched and flushed once"
