## Keyed list + portal example for CPS UI runtime.
## Build:
##   scripts/build_ui_wasm.sh examples/ui/todo_keyed_app.nim examples/ui/todo_keyed_app.wasm

import cps/ui

proc app(): VNode =
  let (reversed, setReversed) = useState(false)

  useEffect(
    proc(): EffectCleanup =
      proc() = discard,
    depsHash(reversed)
  )

  let order = if reversed: @["task-c", "task-b", "task-a"] else: @["task-a", "task-b", "task-c"]

  ui:
    `div`(className="todo-app"):
      h2: text("Keyed Todo List")
      button(onClick=proc(ev: UiEvent) = setReversed(not reversed)):
        text(if reversed: "Show A->C" else: "Show C->A")
      ul:
        li(key=order[0]): text(order[0])
        li(key=order[1]): text(order[1])
        li(key=order[2]): text(order[2])
      portal("#modal-root"):
        `div`(className="modal"):
          text("Portal mounted: " & (if reversed: "reversed" else: "normal"))

setRootComponent(app)
