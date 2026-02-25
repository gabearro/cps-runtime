import cps/ui

var
  childSetter: proc(next: int) {.closure.}
  childRenderCount = 0

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

proc child(): VNode =
  inc childRenderCount
  let (count, setCount) = useState(0)
  childSetter = setCount
  element("span", children = @[text("child:" & $count)])

proc app(): VNode =
  element("div", children = @[component(child, key = "child", typeName = "Child")])

block testNestedComponentHooks:
  mount("#app", app)
  assert childRenderCount == 1
  assert firstText(currentTree()) == "child:0"

  childSetter(4)
  assert isFlushPending()
  runPendingFlush()

  assert childRenderCount == 2
  assert firstText(currentTree()) == "child:4"

  unmount()

echo "PASS: nested component hooks render and update correctly"
