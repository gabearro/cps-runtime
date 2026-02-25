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

block testRouterQueryAndParams:
  resetTestHistoryState()
  setTestLocationPath("/search/nim?page=2&sort=desc")

  let router = createRouter(@[
    route(
      "/search/:term",
      proc(params: RouteParams): VNode =
        let info = useRoute()
        let page = info.query.getOrDefault("page", "")
        let sort = info.query.getOrDefault("sort", "")
        text(params.getOrDefault("term", "") & "|" & page & "|" & sort)
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "nim|2|desc"

  unmount()

echo "PASS: router parses params and query deterministically"
