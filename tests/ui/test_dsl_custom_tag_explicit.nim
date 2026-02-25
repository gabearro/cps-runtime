import cps/ui

proc customView(): VNode =
  ui:
    customTag("my-widget", attr("data-role", "x"), onClick=proc(ev: var UiEvent) = discard):
      span: text("inside")

block testExplicitCustomTag:
  let root = customView()
  assert root.kind == vkElement
  assert root.tag == "my-widget"
  assert root.children.len == 1
  assert root.children[0].tag == "span"

static:
  doAssert not compiles(block:
    proc badCustomTagName(): VNode =
      ui:
        customTag("widget"):
          text("x")
    discard badCustomTagName()
  )

echo "PASS: customTag requires explicit valid custom-element names"
