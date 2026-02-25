import cps/ui

block testFragmentAndPortalPatches:
  resetReconcilerIds()
  let tree = fragment(
    element("span", children = @[text("inline")]),
    portal("#modal-root", element("div", children = @[text("modal")]))
  )

  let patches = diffTrees(nil, tree, 0)
  var sawPortalMount = false
  var sawInsert = false
  for patch in patches:
    if patch.kind == pkMountPortal:
      sawPortalMount = true
    if patch.kind == pkInsert:
      sawInsert = true

  assert sawPortalMount
  assert sawInsert

echo "PASS: fragment + portal produce insert and mountPortal patches"
