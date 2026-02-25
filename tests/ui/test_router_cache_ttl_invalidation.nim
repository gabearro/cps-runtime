import std/os
import cps/ui

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let value = firstText(child)
    if value.len > 0:
      return value
  ""

proc drainPendingFlushes(limit = 16) =
  var spins = 0
  while isFlushPending() and spins < limit:
    inc spins
    runPendingFlush()

block testRouterDataCacheLruEviction:
  resetTestHistoryState()
  setTestLocationPath("/item/1")

  var loaderCalls = 0
  let router = createRouter(
    @[
      route(
        "/item/:id",
        proc(params: RouteParams): VNode =
          text(useRouteData[string]()),
        loader = proc(params: RouteParams): RouteLoad =
          inc loaderCalls
          loadReady(params.pathParamValue("id"))
      )
    ],
    opts = RouterOptions(maxDataEntries: 2, cacheTtlMs: 0)
  )

  proc app(): VNode =
    RouterRoot(router)

  proc navigate(path: string) =
    setTestLocationPath(path)
    nimui_route_changed()
    drainPendingFlushes()

  mount("#app", app)
  assert firstText(currentTree()) == "1"
  assert loaderCalls == 1

  navigate("/item/2")
  assert firstText(currentTree()) == "2"
  assert loaderCalls == 2

  navigate("/item/3")
  assert firstText(currentTree()) == "3"
  assert loaderCalls == 3

  navigate("/item/1")
  assert firstText(currentTree()) == "1"
  assert loaderCalls == 4

  unmount()

block testRouterDataCacheTtl:
  resetTestHistoryState()
  setTestLocationPath("/ttl/1")

  var loaderCalls = 0
  let router = createRouter(
    @[
      route(
        "/ttl/:id",
        proc(params: RouteParams): VNode =
          text(useRouteData[string]()),
        loader = proc(params: RouteParams): RouteLoad =
          inc loaderCalls
          loadReady(params.pathParamValue("id"))
      )
    ],
    opts = RouterOptions(maxDataEntries: 8, cacheTtlMs: 10)
  )

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "1"
  assert loaderCalls == 1

  sleep(20)
  requestFlush()
  drainPendingFlushes()
  assert firstText(currentTree()) == "1"
  assert loaderCalls == 2

  unmount()

block testInvalidateRouteDataTriggersRevalidation:
  resetTestHistoryState()
  setTestLocationPath("/invalidate/7")

  var loaderCalls = 0
  let router = createRouter(
    @[
      route(
        "/invalidate/:id",
        proc(params: RouteParams): VNode =
          text(useRouteData[string]()),
        loader = proc(params: RouteParams): RouteLoad =
          inc loaderCalls
          loadReady(params.pathParamValue("id"))
      )
    ],
    opts = RouterOptions(maxDataEntries: 8, cacheTtlMs: 0)
  )

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "7"
  assert loaderCalls == 1

  invalidateRouteData(router, "/invalidate", includeChildren = true)
  drainPendingFlushes()
  assert firstText(currentTree()) == "7"
  assert loaderCalls == 2

  unmount()

echo "PASS: router data cache honors LRU capacity, TTL expiry, and explicit invalidation"
