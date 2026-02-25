## Controlled input example for CPS UI runtime.
## Build:
##   scripts/build_ui_wasm.sh examples/ui/controlled_input_app.nim examples/ui/controlled_input_app.wasm

import cps/ui

proc app(): VNode =
  let (value, setValue) = useState("hello")
  let (checked, setChecked) = useState(false)

  ui:
    `div`(className="controlled-input-app"):
      input(
        value=value,
        checked=checked,
        onInput=proc(ev: var UiEvent) =
          setValue(ev.value),
        onChange=proc(ev: var UiEvent) =
          setChecked(ev.checked)
      )
      p: text(value & "|" & $checked)

setRootComponent(app)
