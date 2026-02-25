import cps/ui

static:
  doAssert compiles(block:
    proc dynamicButton(kind: string): VNode =
      ui:
        button(type = kind)
    discard dynamicButton("anything")
  )

  doAssert compiles(block:
    proc dynamicSvg(mode: string): VNode =
      ui:
        `svg`(preserveAspectRatio = mode)
    discard dynamicSvg("anything")
  )

echo "PASS: dynamic values are allowed when constraint validity is not statically provable"
