import cps/ui

static:
  doAssert not compiles(block:
    proc badUnknownTag(): VNode =
      ui:
        frobnicator()
    discard badUnknownTag()
  )

echo "PASS: unknown lowercase tags are compile-time errors"
