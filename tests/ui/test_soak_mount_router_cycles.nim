import cps/ui

proc textNode(msg: string): VNode =
  element("span", children = @[text(msg)])

let router = createRouter(@[
  route("/", proc(params: RouteParams): VNode = textNode("home")),
  route("/a", proc(params: RouteParams): VNode = textNode("a")),
  route("/b", proc(params: RouteParams): VNode = textNode("b"))
])

proc app(): VNode =
  RouterRoot(router)

block testSoakMountUnmountAndRouteTransitions:
  resetTestHistoryState()
  for i in 0 ..< 1000:
    setTestLocationPath("/")
    mount("#app", app)

    setTestLocationPath("/a")
    nimui_route_changed()
    runPendingFlush()

    setTestLocationPath("/b")
    nimui_route_changed()
    runPendingFlush()

    unmount()

  assert boundEventCount() == 0

echo "PASS: soak mount/unmount + route transitions do not leak listeners"
