import cps/ui

type
  Action = enum
    actInc,
    actDec,
    actAddFive

var
  dispatchProc: proc(action: Action) {.closure.}
  renderCount = 0

proc reducer(state: int, action: Action): int =
  case action
  of actInc: state + 1
  of actDec: state - 1
  of actAddFive: state + 5

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
  let (state, dispatch) = useReducer[ int, Action ](
    proc(prev: int, action: Action): int = reducer(prev, action),
    0
  )
  dispatchProc = dispatch
  element("span", children = @[text($state)])

block testUseReducer:
  mount("#app", app)
  assert renderCount == 1
  assert firstText(currentTree()) == "0"

  dispatchProc(actInc)
  dispatchProc(actInc)
  dispatchProc(actAddFive)
  assert isFlushPending()
  runPendingFlush()

  assert renderCount == 2
  assert firstText(currentTree()) == "7"

  dispatchProc(actDec)
  runPendingFlush()
  assert renderCount == 3
  assert firstText(currentTree()) == "6"

  unmount()

echo "PASS: useReducer dispatches are batched and deterministic"
