import std/strutils
import cps/ui

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

proc extractAttr(html: string, name: string): string =
  let marker = name & "=\""
  let start = html.find(marker)
  if start < 0:
    return ""
  let valueStart = start + marker.len
  let valueStop = html.find('"', valueStart)
  if valueStop < 0:
    return ""
  html[valueStart ..< valueStop]

proc app(): VNode =
  let id = useId()
  element(
    "div",
    attrs = @[attr("id", id)],
    children = @[text(id)]
  )

block testUseIdParityAcrossSsrHydrateClient:
  let html = renderToString(app)
  let ssrId = extractAttr(html, "id")
  assert ssrId.len > 0

  hydrate("#app", app)
  let hydratedId = firstText(currentTree())
  unmount()

  mount("#app", app)
  let clientId = firstText(currentTree())
  unmount()

  assert hydratedId == ssrId
  assert clientId == ssrId

echo "PASS: useId is parity-stable across SSR, hydrate, and client mount"
