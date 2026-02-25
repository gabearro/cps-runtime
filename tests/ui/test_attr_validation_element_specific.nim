import cps/ui

static:
  doAssert compiles(block:
    proc validElementAttrs(): VNode =
      ui:
        img(src = "x.png", alt = "x", loading = "lazy")
    discard validElementAttrs()
  )

  doAssert not compiles(block:
    proc invalidElementAttrs(): VNode =
      ui:
        img(denomalign = "left")
    discard invalidElementAttrs()
  )

  doAssert not compiles(block:
    proc invalidHelperAttr(): VNode =
      ui:
        img(attr("denomalign", "left"))
    discard invalidHelperAttr()
  )

echo "PASS: element-specific attribute legality is enforced at compile time"
