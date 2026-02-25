import cps/ui

proc app(): VNode =
  raise newException(ValueError, "intentional unhandled wasm exception")

setRootComponent(app)
