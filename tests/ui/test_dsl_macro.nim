import cps/ui

proc sampleView(): VNode =
  ui:
    `div`(className="app-shell"):
      h1: text("Hello")
      button(key="inc", onClick=proc(ev: UiEvent) = discard):
        text("+")

proc Counter(): VNode =
  element("span", children = @[text("counter")])

proc AppShell(child: VNode): VNode =
  element("section", children = @[child])

proc composedView(): VNode =
  ui:
    AppShell():
      Counter(key="left")

proc controlFlowView(flag: bool, items: seq[string]): VNode =
  var i = 0
  ui:
    `div`:
      if flag:
        span: text("on")
      else:
        span: text("off")
      for it in items:
        li(key=it): text(it)
      while i < 0:
        br()
      br()

proc helperArgView(): VNode =
  ui:
    input(
      attr("data-role", "field"),
      prop("value", "abc"),
      styleProp("color", "red"),
      on(etInput, proc(ev: var UiEvent) = discard)
    )

proc implicitTextView(name: string): VNode =
  ui:
    span:
      "Hello, " & name

proc hasText(node: VNode, expected: string): bool =
  if node == nil:
    return false
  if node.kind == vkText and node.text == expected:
    return true
  for child in node.children:
    if hasText(child, expected):
      return true
  false

proc hasTag(node: VNode, expected: string): bool =
  if node == nil:
    return false
  if node.kind == vkElement and node.tag == expected:
    return true
  for child in node.children:
    if hasTag(child, expected):
      return true
  false

block testDslShape:
  let root = sampleView()
  assert root.kind == vkElement
  assert root.tag == "div"
  assert root.attrs.len == 1
  assert root.attrs[0].name == "class"
  assert root.attrs[0].value == "app-shell"
  assert root.children.len == 2

  let buttonNode = root.children[1]
  assert buttonNode.kind == vkElement
  assert buttonNode.tag == "button"
  assert buttonNode.key == "inc"
  assert buttonNode.events.len == 1
  assert buttonNode.events[0].eventType == etClick

block testUppercaseComponentRewrite:
  let root = composedView()
  assert root.kind == vkComponent
  assert root.componentType == "AppShell"
  assert root.renderFn != nil

  let rendered = root.renderFn()
  assert rendered.kind == vkElement
  assert rendered.tag == "section"
  assert rendered.children.len == 1
  let childComp = rendered.children[0]
  assert childComp.kind == vkComponent
  assert childComp.componentType == "Counter"
  assert childComp.key == "left"

block testDslControlFlowAndEmptyTags:
  let root = controlFlowView(true, @["a", "b"])
  assert root.kind == vkElement
  assert root.tag == "div"
  assert hasText(root, "on")
  assert hasText(root, "a")
  assert hasText(root, "b")
  assert hasTag(root, "br")

block testDslHelperArgsAndImplicitText:
  let inputNode = helperArgView()
  assert inputNode.kind == vkElement
  assert inputNode.tag == "input"
  assert inputNode.attrs.len == 3
  assert inputNode.attrs[0].kind == vakAttr
  assert inputNode.attrs[1].kind == vakProp
  assert inputNode.attrs[2].kind == vakStyle
  assert inputNode.events.len == 1
  assert inputNode.events[0].eventType == etInput

  let textRoot = implicitTextView("Nim")
  assert textRoot.kind == vkElement
  assert textRoot.tag == "span"
  assert hasText(textRoot, "Hello, Nim")

echo "PASS: DSL macro emits expected VDOM shape"
