import std/strutils
import cps/ui

type
  DataBox = ref object of RootObj
    value: string

var
  storeValue = "v0"
  loaderCalls = 0
  actionCalls = 0
  pendingAction: RouteLoad = nil

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

block testSubmitActionAndLoaderRevalidation:
  resetTestHistoryState()
  setTestLocationPath("/dashboard")

  let router = createRouter(@[
    route("/dashboard", proc(params: RouteParams): VNode =
      let nav = useNavigationState()
      let data = useRouteData[DataBox]()
      text($nav.kind & ":" & $nav.isRevalidating & ":" & data.value)
    , loader = proc(params: RouteParams): ref RootObj =
      inc loaderCalls
      DataBox(value: storeValue)
    , action = proc(params: RouteParams, payload: string): RouteLoad =
      inc actionCalls
      storeValue = payload
      pendingAction = loadPending()
      pendingAction
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "nskIdle:false:v0"
  assert loaderCalls == 1

  submit("/dashboard", "v1")
  runPendingFlush()
  assert firstText(currentTree()).startsWith("nskSubmitting:")
  assert actionCalls == 1

  resolveLoad(pendingAction, nil)
  var spins = 0
  while isFlushPending() and spins < 10:
    inc spins
    runPendingFlush()

  assert loaderCalls == 2
  assert firstText(currentTree()) == "nskIdle:false:v1"

  unmount()

echo "PASS: submit/use action lifecycle triggers loader revalidation"
