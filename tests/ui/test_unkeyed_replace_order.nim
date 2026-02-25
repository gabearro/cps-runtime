import cps/ui

proc tagged(tagName: string, s: string): VNode =
  element(tagName, children = @[text(s)])

block testUnkeyedMidReplaceUsesReplaceNode:
  resetReconcilerIds()

  var oldTree = element("div", children = @[
    tagged("span", "a"),
    tagged("b", "mid"),
    tagged("span", "c")
  ])
  discard diffTrees(nil, oldTree, -1)

  let newTree = element("div", children = @[
    tagged("span", "a"),
    tagged("i", "mid"),
    tagged("span", "c")
  ])

  let patches = diffTrees(oldTree, newTree, -1)

  var replaceNodeCount = 0
  var removeCount = 0
  var insertCount = 0
  for patch in patches:
    case patch.kind
    of pkReplaceNode: inc replaceNodeCount
    of pkRemove: inc removeCount
    of pkInsert: inc insertCount
    else: discard

  assert replaceNodeCount == 1
  assert removeCount == 0
  assert insertCount == 0

echo "PASS: unkeyed middle mismatch emits replace-node patch"
