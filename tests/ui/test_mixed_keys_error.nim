import std/strutils
import cps/ui

proc item(label: string, key: string = ""): VNode =
  element("li", key = key, children = @[text(label)])

block testMixedKeyedAndUnkeyedSiblingsThrow:
  resetReconcilerIds()

  var oldTree = element("ul", children = @[
    item("a", key = "a"),
    item("b", key = "b")
  ])
  discard diffTrees(nil, oldTree, -1)

  let badNewTree = element("ul", children = @[
    item("a", key = "a"),
    item("b")
  ])

  var threw = false
  try:
    discard diffTrees(oldTree, badNewTree, -1)
  except ValueError as e:
    threw = e.msg.contains("mixed keyed/unkeyed")

  assert threw

echo "PASS: mixed keyed/unkeyed siblings raise deterministic error"
