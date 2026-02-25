import cps/ui
import ./dsl_component_fixture as fixture

proc LocalCard(child: VNode): VNode =
  element("article", children = if child == nil: @[] else: @[child])

proc hasText(node: VNode, expected: string): bool =
  if node == nil:
    return false
  if node.kind == vkText and node.text == expected:
    return true
  for child in node.children:
    if hasText(child, expected):
      return true
  false

proc findComponent(node: VNode, expectedType: string): VNode =
  if node == nil:
    return nil
  if node.kind == vkComponent and node.componentType == expectedType:
    return node
  for child in node.children:
    let found = findComponent(child, expectedType)
    if found != nil:
      return found
  nil

proc dslRootSetupView(): VNode =
  ui:
    let prefix = "setup"
    span: text(prefix & "-ok")

proc dslComponentAndControlFlowView(choice: int): VNode =
  ui:
    `div`:
      LocalCard(key="local"):
        span: text("local")
      fixture.FixturePanel(key="qualified"):
        span: text("qualified")
      let marker = if choice == 0: "zero" else: "other"
      case choice:
      of 0:
        p: text("case-" & marker)
      else:
        p: text("case-other")
      when true:
        em: text("when-true")

block testDslExplicitAndQualifiedComponents:
  let root = dslComponentAndControlFlowView(0)
  assert root.kind == vkElement
  assert root.tag == "div"

  let localComp = findComponent(root, "LocalCard")
  assert localComp != nil
  assert localComp.kind == vkComponent
  assert localComp.componentType == "LocalCard"
  assert localComp.key == "local"
  let localRendered = localComp.renderFn()
  assert localRendered.kind == vkElement
  assert localRendered.tag == "article"

  let qualifiedComp = findComponent(root, "FixturePanel")
  assert qualifiedComp != nil
  assert qualifiedComp.kind == vkComponent
  assert qualifiedComp.componentType == "FixturePanel"
  assert qualifiedComp.key == "qualified"
  let qualifiedRendered = qualifiedComp.renderFn()
  assert qualifiedRendered.kind == vkElement
  assert qualifiedRendered.tag == "section"

block testDslCaseWhenAndSetupStatements:
  let root = dslComponentAndControlFlowView(0)
  assert hasText(root, "case-zero")
  assert hasText(root, "when-true")

  let setupRoot = dslRootSetupView()
  assert setupRoot.kind == vkElement
  assert setupRoot.tag == "span"
  assert hasText(setupRoot, "setup-ok")

echo "PASS: DSL resolves explicit/qualified components and supports case/when/setup statements"
