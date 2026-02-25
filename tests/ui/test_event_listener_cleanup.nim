import cps/ui

proc clicky(label: string): VNode =
  element(
    "button",
    events = @[on(etClick, proc(ev: UiEvent) = discard)],
    children = @[text(label)]
  )

block testListenerCleanupOnRemove:
  resetReconcilerIds()

  var tree = clicky("ok")
  let mountPatches = diffTrees(nil, tree, -1)
  applyPatches(mountPatches)
  assert boundEventCount() == 1

  let removePatches = diffTrees(tree, nil, -1)
  applyPatches(removePatches)
  assert boundEventCount() == 0

  clearBoundEvents()

echo "PASS: removing nodes clears bound event handlers"
