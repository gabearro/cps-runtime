## Counter example for CPS UI runtime.
## Build:
##   scripts/build_ui_wasm.sh examples/ui/counter_app.nim examples/ui/counter_app.wasm

import cps/ui

proc app(): VNode =
  let (count, setCount) = useState(0)

  useEffect(
    proc(): EffectCleanup =
      proc() = discard,
    depsHash(count)
  )

  ui:
    `div`(className="counter-app"):
      h1: text("Count: " & $count)
      button(onClick=proc(ev: UiEvent) = setCount(count + 1)):
        text("Increment")

setRootComponent(app)
