import std/strutils
import cps/ui

proc subscribeNoop(_: proc() {.closure.}): proc() {.closure.} =
  nil

proc app(): VNode =
  let value = useSyncExternalStore[int](
    subscribeNoop,
    proc(): int =
      raise newException(ValueError, "client snapshot should not run during SSR")
    ,
    proc(): int =
      42
  )
  element("div", children = @[text($value)])

block testSyncExternalStoreServerSnapshotOnSsr:
  let html = renderToString(app)
  assert html.contains(">42<")

echo "PASS: SSR useSyncExternalStore prefers getServerSnapshot over getSnapshot"
