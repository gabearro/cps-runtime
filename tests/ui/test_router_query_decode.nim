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

block testRouterQueryDecoding:
  resetTestHistoryState()
  setTestLocationPath("/search/nim?term=nim%20lang+docs&path=a%2Fb&encoded%20key=works&plus=x+y")

  let router = createRouter(@[
    route(
      "/search/:kind",
      proc(params: RouteParams): VNode =
        let info = useRoute()
        text(
          params.getOrDefault("kind", "") & "|" &
          info.query.getOrDefault("term", "") & "|" &
          info.query.getOrDefault("path", "") & "|" &
          info.query.getOrDefault("encoded key", "") & "|" &
          info.query.getOrDefault("plus", "")
        )
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "nim|nim lang docs|a/b|works|x y"

  unmount()

echo "PASS: router decodes query keys/values and '+' semantics"
