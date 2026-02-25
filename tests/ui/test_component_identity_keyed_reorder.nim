import std/tables
import cps/ui

var
  setOrderProc: proc(next: bool) {.closure.}
  itemSetters = initTable[string, proc(next: int) {.closure.}]()

proc collectTexts(node: VNode, acc: var seq[string]) =
  if node == nil:
    return
  if node.kind == vkText:
    acc.add node.text
  for child in node.children:
    collectTexts(child, acc)

proc hasText(node: VNode, target: string): bool =
  var texts: seq[string] = @[]
  collectTexts(node, texts)
  for t in texts:
    if t == target:
      return true
  false

proc item(id: string): VNode =
  component(
    proc(): VNode =
      let (value, setValue) = useState(0)
      itemSetters[id] = setValue
      element("li", children = @[text(id & ":" & $value)]),
    key = id,
    typeName = "ItemCounter"
  )

proc app(): VNode =
  let (reversed, setReversed) = useState(false)
  setOrderProc = setReversed
  let order = if reversed: @["b", "a"] else: @["a", "b"]
  element("ul", children = @[item(order[0]), item(order[1])])

block testComponentIdentityAcrossKeyedReorder:
  mount("#app", app)
  assert hasText(currentTree(), "a:0")
  assert hasText(currentTree(), "b:0")

  itemSetters["a"](7)
  runPendingFlush()
  assert hasText(currentTree(), "a:7")

  setOrderProc(true)
  runPendingFlush()

  # Keyed reorder should preserve component-local state.
  assert hasText(currentTree(), "a:7")
  assert hasText(currentTree(), "b:0")

  unmount()

echo "PASS: keyed component reorder preserves local component state"
