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

block testRouterLoaderAndNavigationState:
  setTestLocationPath("/dashboard")

  let router = createRouter(@[
    route("/dashboard", proc(params: RouteParams): VNode =
      let nav = useNavigationState()
      let data = useRouteData[DataBox]()
      text($nav.kind & ":" & data.value)
    , loader = proc(params: RouteParams): ref RootObj =
      inc loaderCalls
      DataBox(value: "ok")
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "nskIdle:ok"
  assert loaderCalls == 1

  requestFlush()
  runPendingFlush()
  assert loaderCalls == 1

  let link = Link("/dashboard", text("go"), prefetch = true)
  assert link.events.len >= 3

  unmount()

echo "PASS: router loader/useRouteData/useNavigationState and prefetchable Link behavior"
