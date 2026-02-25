import cps/ui

var
  logs: seq[string] = @[]
  setFlagProc: proc(next: bool) {.closure.}

proc Child(flag: bool): VNode =
  useEffect(
    proc(): EffectCleanup =
      logs.add("create:child:" & $flag)
      proc() =
        logs.add("cleanup:child:" & $flag),
    depsHash(flag)
  )
  element("span", children = @[text(if flag: "child:1" else: "child:0")])

proc app(): VNode =
  let (flag, setFlag) = useState(false)
  setFlagProc = setFlag

  useEffect(
    proc(): EffectCleanup =
      logs.add("create:root:" & $flag)
      proc() =
        logs.add("cleanup:root:" & $flag),
    depsHash(flag)
  )

  element(
    "div",
    children = @[
      component(proc(): VNode = Child(flag), key = "child", typeName = "Child")
    ]
  )

block testEffectOrderIsTreeDeterministic:
  mount("#app", app)
  assert logs == @[
    "create:root:false",
    "create:child:false"
  ]

  setFlagProc(true)
  runPendingFlush()

  assert logs == @[
    "create:root:false",
    "create:child:false",
    "cleanup:root:false",
    "cleanup:child:false",
    "create:root:true",
    "create:child:true"
  ]

  unmount()
  assert logs == @[
    "create:root:false",
    "create:child:false",
    "cleanup:root:false",
    "cleanup:child:false",
    "create:root:true",
    "create:child:true",
    "cleanup:root:true",
    "cleanup:child:true"
  ]

echo "PASS: effect cleanup/create ordering is deterministic in tree order"
