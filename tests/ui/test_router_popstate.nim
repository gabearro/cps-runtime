import cps/ui

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

block testRouterPopstateScheduling:
  resetTestHistoryState()
  setTestLocationPath("/a")

  let router = createRouter(@[
    route("/a", proc(params: RouteParams): VNode = text("A")),
    route("/b", proc(params: RouteParams): VNode = text("B"))
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "A"

  setTestLocationPath("/b")
  nimui_route_changed()
  assert isFlushPending()
  runPendingFlush()
  assert firstText(currentTree()) == "B"

  setTestLocationPath("/a")
  nimui_route_changed()
  runPendingFlush()
  assert firstText(currentTree()) == "A"

  unmount()

echo "PASS: router popstate callback schedules deterministic rerenders"
