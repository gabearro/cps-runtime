import cps/ui

var
  logs: seq[string] = @[]
  setFlagProc: proc(next: bool) {.closure.}

proc app(): VNode =
  let (flag, setFlag) = useState(false)
  setFlagProc = setFlag

  useLayoutEffect(
    proc(): EffectCleanup =
      logs.add("layout-create:" & $flag)
      proc() =
        logs.add("layout-cleanup:" & $flag),
    depsHash(flag)
  )

  useEffect(
    proc(): EffectCleanup =
      logs.add("effect-create:" & $flag)
      proc() =
        logs.add("effect-cleanup:" & $flag),
    depsHash(flag)
  )

  element("div", children = @[text(if flag: "1" else: "0")])

block testLayoutEffectOrdering:
  mount("#app", app)
  assert logs == @[
    "layout-create:false",
    "effect-create:false"
  ]

  setFlagProc(true)
  runPendingFlush()

  assert logs == @[
    "layout-create:false",
    "effect-create:false",
    "layout-cleanup:false",
    "effect-cleanup:false",
    "layout-create:true",
    "effect-create:true"
  ]

  unmount()
  assert logs == @[
    "layout-create:false",
    "effect-create:false",
    "layout-cleanup:false",
    "effect-cleanup:false",
    "layout-create:true",
    "effect-create:true",
    "layout-cleanup:true",
    "effect-cleanup:true"
  ]

echo "PASS: layout effects run before passive effects with deterministic cleanup/create order"
