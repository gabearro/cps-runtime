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

block testRouterPathParamDecoding:
  resetTestHistoryState()
  setTestLocationPath("/users/alice%20smith/projects/a%2Fb")

  let router = createRouter(@[
    route(
      "/users/:name/projects/:project",
      proc(params: RouteParams): VNode =
        text(params.getOrDefault("name", "") & "|" & params.getOrDefault("project", ""))
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "alice smith|a/b"

  setTestLocationPath("/users/a+b/projects/c%2B%2B")
  nimui_route_changed()
  runPendingFlush()
  assert firstText(currentTree()) == "a+b|c++"

  unmount()

echo "PASS: router decodes path params while preserving literal '+' in paths"
