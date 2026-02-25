import cps/ui

static:
  doAssert compiles(block:
    proc validEnumConstraint(): VNode =
      ui:
        button(type = "submit")
    discard validEnumConstraint()
  )

  doAssert not compiles(block:
    proc invalidEnumConstraint(): VNode =
      ui:
        button(type = "submit-now")
    discard invalidEnumConstraint()
  )

  doAssert compiles(block:
    proc validSvgConstraint(): VNode =
      ui:
        `svg`(preserveAspectRatio = "xMidYMid meet")
    discard validSvgConstraint()
  )

  doAssert not compiles(block:
    proc invalidSvgConstraint(): VNode =
      ui:
        `svg`(preserveAspectRatio = "totally-invalid")
    discard invalidSvgConstraint()
  )

echo "PASS: literal enum constraints are compile-time validated"
