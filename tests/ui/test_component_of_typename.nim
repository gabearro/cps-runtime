import std/tables
import cps/ui

var
  setOrderProc: proc(next: bool) {.closure.}
  itemSetters = initTable[string, proc(next: int) {.closure.}]()

proc hasText(node: VNode, target: string): bool =
  if node == nil:
    return false
  if node.kind == vkText and node.text == target:
    return true
  for child in node.children:
    if hasText(child, target):
      return true
  false

proc ItemA(): VNode =
  let (value, setValue) = useState(0)
  itemSetters["a"] = setValue
  element("li", children = @[text("a:" & $value)])

proc ItemB(): VNode =
  let (value, setValue) = useState(0)
  itemSetters["b"] = setValue
  element("li", children = @[text("b:" & $value)])

proc app(): VNode =
  let (reversed, setReversed) = useState(false)
  setOrderProc = setReversed

  let items =
    if reversed:
      @[
        componentOf(ItemB, key = "b"),
        componentOf(ItemA, key = "a")
      ]
    else:
      @[
        componentOf(ItemA, key = "a"),
        componentOf(ItemB, key = "b")
      ]

  element("ul", children = items)

block testComponentOfInfersTypeName:
  let node = componentOf(ItemA, key = "a")
  assert node.kind == vkComponent
  assert node.componentType == "ItemA"
  assert node.key == "a"

block testComponentOfIdentityAcrossReorder:
  mount("#app", app)
  assert hasText(currentTree(), "a:0")
  assert hasText(currentTree(), "b:0")

  itemSetters["a"](9)
  runPendingFlush()
  assert hasText(currentTree(), "a:9")

  setOrderProc(true)
  runPendingFlush()

  # Reordering keyed components should preserve component-local state.
  assert hasText(currentTree(), "a:9")
  assert hasText(currentTree(), "b:0")

  unmount()

echo "PASS: componentOf infers typeName and preserves keyed component identity"
