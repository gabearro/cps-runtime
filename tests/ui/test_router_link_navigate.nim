import cps/ui

var
  anchorId: int32
  buttonId: int32

proc allText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    result.add allText(child)

proc findElementDomId(node: VNode, tagName: string): int32 =
  if node == nil:
    return 0
  if node.kind == vkElement and node.tag == tagName:
    return node.domId
  for child in node.children:
    let id = findElementDomId(child, tagName)
    if id > 0:
      return id
  0

block testRouterLinkAndNavigate:
  resetTestHistoryState()
  setTestLocationPath("/")

  let router = createRouter(@[
    route(
      "/",
      proc(params: RouteParams): VNode =
        let navigate = useNavigate()
        element(
          "div",
          children = @[
            Link("/about", text("go-about")),
            element(
              "button",
              events = @[
                on(etClick, proc(ev: var UiEvent) =
                  navigate("/manual")
                )
              ],
              children = @[text("go-manual")]
            )
          ]
        )
    ),
    route("/about", proc(params: RouteParams): VNode = text("about-page")),
    route("/manual", proc(params: RouteParams): VNode = text("manual-page"))
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)

  anchorId = findElementDomId(currentTree(), "a")
  buttonId = findElementDomId(currentTree(), "button")
  assert anchorId > 0
  assert buttonId > 0

  let clickFlags = nimui_dispatch_event(
    eventTypeCode(etClick),
    anchorId,
    anchorId,
    nil, 0,
    nil, 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
  )
  assert clickFlags == 1

  runPendingFlush()
  assert allText(currentTree()) == "about-page"

  setTestLocationPath("/")
  nimui_route_changed()
  runPendingFlush()

  buttonId = findElementDomId(currentTree(), "button")
  assert buttonId > 0

  discard nimui_dispatch_event(
    eventTypeCode(etClick),
    buttonId,
    buttonId,
    nil, 0,
    nil, 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
  )

  runPendingFlush()
  assert allText(currentTree()) == "manual-page"

  unmount()

echo "PASS: router Link and useNavigate integrate with history updates"
