import cps/ui

static:
  doAssert compiles(block:
    proc validGlobalAttrs(): VNode =
      ui:
        `div`(
          id = "app",
          className = "shell",
          attr("data-role", "main"),
          attr("aria-label", "Main App")
        )
    discard validGlobalAttrs()
  )

echo "PASS: global attrs and data-/aria- attrs compile under strict validation"
