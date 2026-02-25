import std/tables
import cps/ui

proc findFirstTag(node: VNode, tag: string): VNode =
  if node == nil:
    return nil
  if node.kind == vkElement and node.tag == tag:
    return node
  for child in node.children:
    let found = findFirstTag(child, tag)
    if found != nil:
      return found
  nil

proc attrValue(node: VNode, name: string): string =
  if node == nil:
    return ""
  for item in node.attrs:
    if item.name == name:
      return item.value
  ""

proc drainPendingFlushes(limit = 16) =
  var spins = 0
  while isFlushPending() and spins < limit:
    inc spins
    runPendingFlush()

block testFormOptionsMethodEnctypeAndSerialize:
  resetTestHistoryState()
  setTestLocationPath("/submit")

  var actionPayload = ""
  var actionCalls = 0
  let router = createRouter(@[
    route(
      "/submit",
      proc(params: RouteParams): VNode =
        Form(
          "/submit",
          text("submit"),
          opts = FormOptions(
            replace: false,
            `method`: "put",
            enctype: "application/json",
            serialize: proc(ev: UiEvent): string =
              eventExtra(ev, "payload", "{\"ok\":true}")
          )
        )
      ,
      action = proc(params: RouteParams, payload: string): RouteLoad =
        inc actionCalls
        actionPayload = payload
        loadReady(nil)
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  let form = findFirstTag(currentTree(), "form")
  assert form != nil
  assert attrValue(form, "method") == "put"
  assert attrValue(form, "enctype") == "application/json"

  var ev = UiEvent(
    eventType: etSubmit,
    extras: initTable[string, string]()
  )
  ev.extras["payload"] = """{"x":1}"""
  assert form.events.len == 1
  form.events[0].handler(ev)
  drainPendingFlushes()

  assert actionCalls == 1
  assert actionPayload == """{"x":1}"""
  unmount()

block testLegacyFormOverloadUsesDefaultPayloadExtraction:
  resetTestHistoryState()
  setTestLocationPath("/legacy")

  var actionPayload = ""
  var actionCalls = 0
  let router = createRouter(@[
    route(
      "/legacy",
      proc(params: RouteParams): VNode =
        Form("/legacy", text("legacy"), replace = false)
      ,
      action = proc(params: RouteParams, payload: string): RouteLoad =
        inc actionCalls
        actionPayload = payload
        loadReady(nil)
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  let form = findFirstTag(currentTree(), "form")
  assert form != nil
  assert attrValue(form, "method") == "post"
  assert attrValue(form, "enctype") == "application/x-www-form-urlencoded"

  var ev = UiEvent(
    eventType: etSubmit,
    extras: initTable[string, string]()
  )
  ev.extras["formPayload"] = "a=1&b=2"
  assert form.events.len == 1
  form.events[0].handler(ev)
  drainPendingFlushes()

  assert actionCalls == 1
  assert actionPayload == "a=1&b=2"
  unmount()

echo "PASS: Form supports method/enctype/serialize options and preserves legacy defaults"
