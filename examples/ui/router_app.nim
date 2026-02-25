## Router example for CPS UI runtime.
## Build:
##   scripts/build_ui_wasm.sh examples/ui/router_app.nim examples/ui/router_app.wasm

import std/tables
import cps/ui

proc HomePage(): VNode =
  ui:
    `div`(className="router-home"):
      h1: text("Home")
      Link("/users/42?tab=profile", text("Go User 42"))
      Link("/settings", text("Settings"))

proc UserPage(): VNode =
  let info = useRoute()
  let userId = $pathParamInt(info.params, "id")
  let tab = info.query.getOrDefault("tab", "overview")
  ui:
    `div`(className="router-user"):
      h2: text("User:" & userId)
      p: text("Tab:" & tab)
      Link("/", text("Back Home"))

proc SettingsPage(): VNode =
  ui:
    `div`(className="router-settings"):
      h2: text("Settings")
      Link("/", text("Back Home"))

let appRouter = createRouter(@[
  route(
    "/",
    proc(params: RouteParams): VNode =
      componentOf(HomePage, key = "home-page")
  ),
  route(
    "/users/{id:int}",
    proc(params: RouteParams): VNode =
      componentOf(UserPage, key = "user-page")
  ),
  route(
    "/settings",
    proc(params: RouteParams): VNode =
      componentOf(SettingsPage, key = "settings-page")
  )
])

proc app(): VNode =
  RouterRoot(appRouter)

setRootComponent(app)
