import std/macros
import cps/ui
import cps/ui/schema/generated/events

macro defineAllEventsView(): untyped =
  var stmts = newNimNode(nnkStmtList)

  for eventName in dslEventNames:
    let bubbleAssign = newTree(
      nnkExprEqExpr,
      ident(eventName),
      quote do:
        proc(ev: var UiEvent) =
          discard
    )
    stmts.add newCall(ident("div"), bubbleAssign)

    let captureAssign = newTree(
      nnkExprEqExpr,
      ident(eventName & "Capture"),
      quote do:
        proc(ev: var UiEvent) =
          discard
    )
    stmts.add newCall(ident("div"), captureAssign)

  let uiExpr = newCall(ident("ui"), stmts)
  result = quote do:
    proc allEventsView(): VNode =
      `uiExpr`

defineAllEventsView()

block testAllDslEventAliases:
  let root = allEventsView()
  assert root.kind == vkFragment
  assert root.children.len == dslEventNames.len * 2

  let bubble = root.children[0]
  let capture = root.children[1]
  assert bubble.events.len == 1
  assert capture.events.len == 1
  assert bubble.events[0].options.capture == false
  assert capture.events[0].options.capture == true

echo "PASS: DSL rewrites all event aliases and capture variants"
