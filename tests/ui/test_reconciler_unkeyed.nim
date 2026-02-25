import cps/ui

proc spanText(s: string): VNode =
  element("span", children = @[text(s)])

block testUnkeyedDiff:
  resetReconcilerIds()

  var oldTree = element("div", children = @[spanText("a"), spanText("b")])
  discard diffTrees(nil, oldTree, 0) # Assign initial DOM ids.

  let newTree = element("div", children = @[spanText("a"), spanText("c"), spanText("d")])
  let patches = diffTrees(oldTree, newTree, 0)

  var replaceTextCount = 0
  var insertCount = 0
  for patch in patches:
    if patch.kind == pkReplaceText:
      inc replaceTextCount
    if patch.kind == pkInsert:
      inc insertCount

  assert replaceTextCount >= 1
  assert insertCount == 1

echo "PASS: unkeyed reconciler emits expected replace/insert patches"
