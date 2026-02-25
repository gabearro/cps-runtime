import std/strutils
import cps/ui

proc keyed(k: string): VNode =
  element("li", key = k, children = @[text(k)])

block testDuplicateKeyThrows:
  resetReconcilerIds()

  var oldTree = element("ul", children = @[keyed("a"), keyed("b")])
  discard diffTrees(nil, oldTree, -1)

  let badNewTree = element("ul", children = @[keyed("a"), keyed("a")])

  var threw = false
  try:
    discard diffTrees(oldTree, badNewTree, -1)
  except ValueError as e:
    threw = e.msg.contains("duplicate key")

  assert threw

echo "PASS: duplicate keyed siblings raise deterministic error"
