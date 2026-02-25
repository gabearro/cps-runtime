import std/tables
import cps/ui

type
  DataBox = ref object of RootObj
    value: string

var
  loaderCalls = 0

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let value = firstText(child)
    if value.len > 0:
      return value
  ""

block testQueryAwareRouteDataCacheKey:
  resetTestHistoryState()
  setTestLocationPath("/search?q=first")

  let router = createRouter(@[
    route("/search", proc(params: RouteParams): VNode =
      let info = useRoute()
      let data = useRouteData[DataBox]()
      text(info.query.getOrDefault("q", "") & ":" & data.value)
    , loader = proc(params: RouteParams): ref RootObj =
      inc loaderCalls
      let info = useRoute()
      DataBox(value: info.query.getOrDefault("q", ""))
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "first:first"
  assert loaderCalls == 1

  setTestLocationPath("/search?q=second")
  nimui_route_changed()
  runPendingFlush()

  assert firstText(currentTree()) == "second:second"
  assert loaderCalls == 2

  unmount()

echo "PASS: router cache key includes query and avoids stale loader data"
