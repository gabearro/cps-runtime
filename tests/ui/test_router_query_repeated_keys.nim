import std/[strutils, tables]
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

block testRepeatedQueryKeysExposeAllValues:
  resetTestHistoryState()
  setTestLocationPath("/search?tag=a&tag=b&tag=c&n=1&n=2&ok=true&ok=false")

  let router = createRouter(@[
    route(
      "/search",
      proc(params: RouteParams): VNode =
        let info = useRoute()
        let tags = queryParamAll(info.queryAll, "tag")
        let nums = queryParamAllInt(info.queryAll, "n")
        let flags = queryParamAllBool(info.queryAll, "ok")

        var sum = 0
        for n in nums:
          sum += n

        text(
          tags.join(",") & "|" &
          $sum & "|" &
          $flags.len & "|" &
          info.query.getOrDefault("tag", "")
        )
    )
  ])

  proc app(): VNode =
    RouterRoot(router)

  mount("#app", app)
  assert firstText(currentTree()) == "a,b,c|3|2|c"
  unmount()

echo "PASS: repeated query keys are preserved via queryAll helpers"
