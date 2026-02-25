import std/strutils
import cps/ui

proc app(): VNode =
  element("div", children = @[text("ok")])

block testCommitEvent:
  mount("#app", app)
  assert lastUiRuntimeEvent.len > 0
  assert lastUiRuntimeEvent.contains("\"type\":\"commit\"")
  unmount()

echo "PASS: runtime commit telemetry payload is exported"
