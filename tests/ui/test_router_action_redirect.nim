import cps/ui

proc allText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    result.add allText(child)

block testActionRedirect:
  resetTestHistoryState()
  setTestLocationPath("/go")

  let router = createRouter(@[
    route("/go", proc(params: RouteParams): VNode = text("go"),
      action = proc(params: RouteParams, payload: string): RouteLoad =
        loadRedirect("/done")
    ),
    route("/done", proc(params: RouteParams): VNode = text("done"))
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert allText(currentTree()) == "go"

  submit("/go", "")
  var spins = 0
  while isFlushPending() and spins < 8:
    inc spins
    runPendingFlush()

  assert useRoute().path == "/done"
  assert allText(currentTree()) == "done"

  unmount()

echo "PASS: action redirect updates location and route rendering"
