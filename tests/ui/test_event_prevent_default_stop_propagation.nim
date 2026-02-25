import cps/ui

var
  clicked = false

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

proc app(): VNode =
  ui:
    button(onClick=proc(ev: var UiEvent) =
      clicked = true
      preventDefault(ev)
      stopPropagation(ev)
    ):
      text("tap")

block testPreventDefaultAndStopPropagationFlags:
  clicked = false
  mount("#app", app)

  let buttonId = findElementDomId(currentTree(), "button")
  assert buttonId > 0

  let flags = nimui_dispatch_event(
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

  assert clicked
  assert flags == 3

  unmount()

echo "PASS: preventDefault/stopPropagation are returned as event bitflags"
