import cps/ui

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

proc extrasBlob(pairs: openArray[(string, string)]): string =
  for (k, v) in pairs:
    if k.len == 0:
      continue
    result.add(k)
    result.add('\0')
    result.add(v)
    result.add('\0')

proc dispatchClick(
  nodeId: int32,
  button: int32 = 0,
  ctrl = false,
  alt = false,
  shift = false,
  meta = false,
  extras: openArray[(string, string)] = []
): int32 =
  let blob = extrasBlob(extras)
  let blobPtr =
    if blob.len > 0:
      cast[pointer](unsafeAddr blob[0])
    else:
      nil

  nimui_dispatch_event(
    eventTypeCode(etClick),
    nodeId,
    nodeId,
    nil, 0,
    nil, 0,
    0,
    if ctrl: 1 else: 0,
    if alt: 1 else: 0,
    if shift: 1 else: 0,
    if meta: 1 else: 0,
    0,
    0,
    button,
    0,
    blobPtr,
    blob.len.int32
  )

block testLinkModifierAndTargetSemantics:
  resetTestHistoryState()
  setTestLocationPath("/")

  let router = createRouter(@[
    route(
      "/",
      proc(params: RouteParams): VNode =
        element("div", children = @[Link("/about", text("go-about"))])
    ),
    route("/about", proc(params: RouteParams): VNode = text("about-page"))
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)

  let anchorId = findElementDomId(currentTree(), "a")
  assert anchorId > 0

  let ctrlFlags = dispatchClick(anchorId, ctrl = true)
  assert ctrlFlags == 0
  if isFlushPending():
    runPendingFlush()
  assert useRoute().path == "/"

  let middleFlags = dispatchClick(anchorId, button = 1)
  assert middleFlags == 0
  if isFlushPending():
    runPendingFlush()
  assert useRoute().path == "/"

  let targetFlags = dispatchClick(anchorId, extras = @[("currentTargetTarget", "_blank")])
  assert targetFlags == 0
  if isFlushPending():
    runPendingFlush()
  assert useRoute().path == "/"

  let downloadFlags = dispatchClick(anchorId, extras = @[("currentTargetDownload", "file.txt")])
  assert downloadFlags == 0
  if isFlushPending():
    runPendingFlush()
  assert useRoute().path == "/"

  let normalFlags = dispatchClick(anchorId)
  assert normalFlags == 1
  runPendingFlush()
  assert useRoute().path == "/about"
  assert allText(currentTree()) == "about-page"

  unmount()

echo "PASS: Link respects modifier/target/download semantics and only intercepts safe SPA clicks"
