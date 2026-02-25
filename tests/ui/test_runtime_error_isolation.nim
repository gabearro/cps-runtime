import std/strutils
import cps/ui

var
  errors: seq[string] = @[]

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

proc crashingEventApp(): VNode =
  ui:
    button(onClick=proc(ev: UiEvent) =
      raise newException(ValueError, "boom-click")
    ):
      text("boom")

proc crashingEffectApp(): VNode =
  useEffect(
    proc(): EffectCleanup =
      raise newException(ValueError, "boom-effect"),
    depsHash(1)
  )
  element("div", children = @[text("ok")])

block testEventHandlerErrorsAreContained:
  errors = @[]
  clearLastUiError()
  setUiErrorHandler(proc(phase: string, message: string) =
    errors.add(phase & "|" & message)
  )

  mount("#app", crashingEventApp)
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
  assert flags == 0
  assert errors.len == 1
  assert errors[0].contains("event:click")
  assert errors[0].contains("boom-click")
  assert lastUiError.contains("boom-click")

  unmount()

block testEffectErrorsAreContained:
  errors = @[]
  clearLastUiError()
  setUiErrorHandler(proc(phase: string, message: string) =
    errors.add(phase & "|" & message)
  )

  mount("#app", crashingEffectApp)

  assert currentTree() != nil
  assert errors.len == 1
  assert errors[0].contains("effect-create")
  assert errors[0].contains("boom-effect")
  assert lastUiError.contains("boom-effect")

  unmount()
  clearUiErrorHandler()

echo "PASS: runtime contains event/effect failures and reports deterministic errors"
