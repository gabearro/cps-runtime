## Fail-soft runtime example for CPS UI runtime.
## Build:
##   scripts/build_ui_wasm.sh examples/ui/fail_soft_app.nim examples/ui/fail_soft_app.wasm

import cps/ui

proc app(): VNode =
  ui:
    `div`:
      text("Trigger fatal mount")
      portal("#missing-root"):
        span: text("should-fail")

setRootComponent(app)
