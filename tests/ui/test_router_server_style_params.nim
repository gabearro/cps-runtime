import std/tables
import cps/ui

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let t = firstText(child)
    if t.len > 0:
      return t
  ""

block testServerStylePathAndQueryHelpers:
  resetTestHistoryState()
  setTestLocationPath("/users/42?draft=true&page=3&ratio=2.5")

  let router = createRouter(@[
    route(
      "/users/{id:int}",
      proc(params: RouteParams): VNode =
        let info = useRoute()
        text(
          $pathParamInt(params, "id") & "|" &
          $queryParamBool(info.query, "draft") & "|" &
          $queryParamInt(info.query, "page", 1) & "|" &
          $queryParamFloat(info.query, "ratio")
        )
    ),
    route(
      "/users/{slug}",
      proc(params: RouteParams): VNode =
        text("slug:" & pathParamValue(params, "slug"))
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "42|true|3|2.5"

  # Int-constrained route should not match; fallback to generic slug route.
  setTestLocationPath("/users/alice")
  nimui_route_changed()
  runPendingFlush()
  assert firstText(currentTree()) == "slug:alice"

  unmount()

block testOptionalServerStylePathParam:
  resetTestHistoryState()
  setTestLocationPath("/search")

  let router = createRouter(@[
    route(
      "/search/{term?}",
      proc(params: RouteParams): VNode =
        text("term:" & params.getOrDefault("term", "all"))
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "term:all"

  setTestLocationPath("/search/nim")
  nimui_route_changed()
  runPendingFlush()
  assert firstText(currentTree()) == "term:nim"

  unmount()

block testQueryAndPathHelperErrors:
  var qp = initTable[string, string]()
  var pp = initTable[string, string]()

  assert queryParamInt(qp, "page", 7) == 7
  assert queryParamBool(qp, "draft", false) == false

  var threwMissingPath = false
  try:
    discard pathParamValue(pp, "id")
  except ValueError:
    threwMissingPath = true
  assert threwMissingPath

  qp["page"] = "oops"
  var threwInvalidInt = false
  try:
    discard queryParamInt(qp, "page")
  except ValueError:
    threwInvalidInt = true
  assert threwInvalidInt

echo "PASS: router supports server-style path/query parsing helpers"
