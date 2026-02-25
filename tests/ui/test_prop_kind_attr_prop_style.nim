import cps/ui

proc viewA(): VNode =
  element(
    "input",
    attrs = @[
      attr("title", "old"),
      prop("value", "a"),
      boolProp("disabled", false),
      styleProp("color", "red")
    ]
  )

proc viewB(): VNode =
  element(
    "input",
    attrs = @[
      attr("title", "new"),
      prop("value", "b"),
      boolProp("disabled", true),
      styleProp("color", "blue")
    ]
  )

proc viewNoStyle(): VNode =
  element(
    "input",
    attrs = @[
      attr("title", "new"),
      prop("value", "b"),
      boolProp("disabled", true)
    ]
  )

block testAttrKindsInDiffPatches:
  resetReconcilerIds()

  var oldTree = viewA()
  discard diffTrees(nil, oldTree, -1)

  var nextTree = viewB()
  let patches = diffTrees(oldTree, nextTree, -1)

  var sawAttr = false
  var sawPropValue = false
  var sawPropBool = false
  var sawStyle = false

  for p in patches:
    if p.kind != pkSetAttr:
      continue
    if p.attrKind == vakAttr and p.attrName == "title" and p.attrValue == "new":
      sawAttr = true
    if p.attrKind == vakProp and p.attrName == "value" and p.attrValue == "b":
      sawPropValue = true
    if p.attrKind == vakProp and p.attrName == "disabled" and p.attrValue == "true":
      sawPropBool = true
    if p.attrKind == vakStyle and p.attrName == "color" and p.attrValue == "blue":
      sawStyle = true

  assert sawAttr
  assert sawPropValue
  assert sawPropBool
  assert sawStyle

  oldTree = nextTree
  nextTree = viewNoStyle()
  let removePatches = diffTrees(oldTree, nextTree, -1)

  var sawStyleRemove = false
  for p in removePatches:
    if p.kind == pkRemoveAttr and p.attrKind == vakStyle and p.attrName == "color":
      sawStyleRemove = true
  assert sawStyleRemove

echo "PASS: vakAttr/vakProp/vakStyle patches are emitted deterministically"
