import cps/ui

proc inputNode(value: string, checked: bool): VNode =
  element(
    "input",
    attrs = @[
      attr("value", value),
      attr("checked", if checked: "true" else: "false")
    ]
  )

block testControlledInputAttrsDiff:
  resetReconcilerIds()

  var oldTree = inputNode("a", false)
  discard diffTrees(nil, oldTree, -1)

  let newTree = inputNode("b", true)
  let patches = diffTrees(oldTree, newTree, -1)

  var sawValue = false
  var sawChecked = false
  for patch in patches:
    if patch.kind == pkSetAttr and patch.attrName == "value" and patch.attrValue == "b":
      sawValue = true
    if patch.kind == pkSetAttr and patch.attrName == "checked" and patch.attrValue == "true":
      sawChecked = true

  assert sawValue
  assert sawChecked

echo "PASS: controlled input attrs produce deterministic diff patches"
