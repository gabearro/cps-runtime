import cps/ui

let ThemeCtx = createContext("guest")

var
  setThemeProc: proc(next: string) {.closure.}

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

proc themeLabel(): VNode =
  let theme = useContext(ThemeCtx)
  element("span", children = @[text(theme)])

proc appWithProvider(): VNode =
  let (theme, setTheme) = useState("light")
  setThemeProc = setTheme
  provider(
    ThemeCtx,
    theme,
    component(themeLabel, key = "theme-label", typeName = "ThemeLabel")
  )

proc appWithoutProvider(): VNode =
  component(themeLabel, key = "theme-label", typeName = "ThemeLabel")

block testContextProviderConsumer:
  mount("#app", appWithProvider)
  assert firstText(currentTree()) == "light"

  setThemeProc("dark")
  runPendingFlush()
  assert firstText(currentTree()) == "dark"
  unmount()

block testContextDefaultValue:
  mount("#app", appWithoutProvider)
  assert firstText(currentTree()) == "guest"
  unmount()

echo "PASS: context provider/consumer and defaults are deterministic"
