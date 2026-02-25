import cps/ui

proc allText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    result.add allText(child)

block testRouterNestedOutlet:
  resetTestHistoryState()
  setTestLocationPath("/app/dashboard")

  let router = createRouter(@[
    route(
      "/app",
      proc(params: RouteParams): VNode =
        element("div", children = @[text("layout|"), Outlet()]),
      children = @[
        route("dashboard", proc(params: RouteParams): VNode = text("dashboard"))
      ]
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert allText(currentTree()) == "layout|dashboard"

  setTestLocationPath("/app")
  nimui_route_changed()
  runPendingFlush()
  assert allText(currentTree()) == "layout|"

  unmount()

echo "PASS: nested router outlet composition is deterministic"
