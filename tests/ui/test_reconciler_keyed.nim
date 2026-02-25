import cps/ui

proc keyedItem(k: string): VNode =
  element("li", children = @[text(k)], key = k)

block testKeyedDiffLIS:
  resetReconcilerIds()

  var oldTree = element("ul", children = @[
    keyedItem("a"),
    keyedItem("b"),
    keyedItem("c"),
    keyedItem("d")
  ])
  discard diffTrees(nil, oldTree, 0) # Assign initial DOM ids.

  let newTree = element("ul", children = @[
    keyedItem("c"),
    keyedItem("a"),
    keyedItem("b"),
    keyedItem("d")
  ])

  let patches = diffTrees(oldTree, newTree, 0)

  var moveCount = 0
  var insertCount = 0
  var removeCount = 0
  for patch in patches:
    case patch.kind
    of pkMove: inc moveCount
    of pkInsert: inc insertCount
    of pkRemove: inc removeCount
    else: discard

  # [a,b,c,d] -> [c,a,b,d] should be handled with one move in keyed mode.
  assert moveCount == 1
  assert insertCount == 0
  assert removeCount == 0

echo "PASS: keyed reconciler uses move patch with LIS minimization"
