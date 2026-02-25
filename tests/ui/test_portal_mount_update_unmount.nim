import cps/ui

block testPortalLifecyclePatches:
  resetReconcilerIds()

  var mounted = portal("#modal-root", element("div", children = @[text("open")]))
  let mountPatches = diffTrees(nil, mounted, -1)

  var sawMount = false
  for patch in mountPatches:
    if patch.kind == pkMountPortal:
      sawMount = true
  assert sawMount

  # Emulate a mounted portal root id assigned during commit.
  mounted.componentId = -42

  let updated = portal("#modal-root", element("div", children = @[text("updated")]))
  let updatePatches = diffTrees(mounted, updated, -1)

  var sawTextUpdate = false
  for patch in updatePatches:
    if patch.kind == pkReplaceText:
      sawTextUpdate = true
  assert sawTextUpdate

  let unmountPatches = diffTrees(mounted, nil, -1)
  var sawUnmount = false
  for patch in unmountPatches:
    if patch.kind == pkUnmountPortal and patch.rootId == -42:
      sawUnmount = true
  assert sawUnmount

echo "PASS: portal mount/update/unmount patches are explicit"
