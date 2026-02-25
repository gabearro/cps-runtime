import std/macros
import cps/ui
import cps/ui/schema/generated/elements

macro defineAllTagsView(): untyped =
  var stmts = newNimNode(nnkStmtList)
  for tag in standardElementNames:
    let head = parseExpr("`" & tag & "`")
    stmts.add newCall(head)

  let uiExpr = newCall(ident("ui"), stmts)
  result = quote do:
    proc allTagsView(): VNode =
      `uiExpr`

defineAllTagsView()

block testAllKnownTagsCompileInDsl:
  let root = allTagsView()
  assert root.kind == vkFragment
  assert root.children.len == standardElementNames.len

echo "PASS: DSL accepts all known HTML/SVG/MathML tags"
