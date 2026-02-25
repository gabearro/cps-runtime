import std/tables
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

block testRouterMatchPrecedence:
  resetTestHistoryState()
  setTestLocationPath("/users/new")

  let router = createRouter(@[
    route("/users/new", proc(params: RouteParams): VNode = text("static")),
    route("/users/:id", proc(params: RouteParams): VNode = text("dynamic:" & params.getOrDefault("id", ""))),
    route("/users/*", proc(params: RouteParams): VNode = text("wildcard"))
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "static"

  setTestLocationPath("/users/42")
  nimui_route_changed()
  runPendingFlush()
  assert firstText(currentTree()) == "dynamic:42"

  setTestLocationPath("/users/42/history")
  nimui_route_changed()
  runPendingFlush()
  assert firstText(currentTree()) == "wildcard"

  unmount()

echo "PASS: router precedence is static > dynamic > wildcard"
