import cps/ui

proc allText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    result.add allText(child)

block testLoaderRedirect:
  resetTestHistoryState()
  setTestLocationPath("/old")

  let router = createRouter(@[
    route("/", proc(params: RouteParams): VNode = text("home")),
    route("/old", proc(params: RouteParams): VNode = text("old"),
      loader = proc(params: RouteParams): RouteLoad =
        loadRedirect("/new")
    ),
    route("/new", proc(params: RouteParams): VNode = text("new"))
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)

  var spins = 0
  while isFlushPending() and spins < 6:
    inc spins
    runPendingFlush()

  assert allText(currentTree()) == "new"
  assert useRoute().path == "/new"

  unmount()

echo "PASS: loader redirect navigates and re-renders matched route"
