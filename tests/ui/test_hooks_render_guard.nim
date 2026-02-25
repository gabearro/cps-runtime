import std/strutils
import cps/ui

proc badApp(): VNode =
  let (count, setCount) = useState(0)
  if count == 0:
    setCount(1)
  element("span", children = @[text($count)])

block testSetStateDuringRenderThrows:
  var threw = false
  try:
    mount("#app", badApp)
  except ValueError as e:
    threw = e.msg.contains("setState is not allowed during render")

  assert threw
  unmount()

echo "PASS: setState during render throws deterministic hook error"
