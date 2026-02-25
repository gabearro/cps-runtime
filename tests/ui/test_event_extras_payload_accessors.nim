import std/tables
import cps/ui

block testEventExtrasAccessors:
  var ev = UiEvent(
    eventType: etClick,
    targetId: 10,
    currentTargetId: 10,
    extras: initTable[string, string]()
  )
  ev.extras["deltaX"] = "12"
  ev.extras["isPrimary"] = "true"
  ev.extras["count"] = "oops"

  assert eventExtra(ev, "deltaX") == "12"
  assert eventExtra(ev, "missing", "fallback") == "fallback"

  assert eventExtraInt(ev, "deltaX", -1) == 12
  assert eventExtraInt(ev, "count", 7) == 7

  assert eventExtraBool(ev, "isPrimary", false)
  assert eventExtraBool(ev, "missing", true)

echo "PASS: event extras accessors return typed values with defaults"
