## Test SPA for validating CPS UI DSL behavior end-to-end.
## Build:
##   scripts/build_ui_wasm.sh examples/ui/test_spa_app.nim examples/ui/test_spa_app.wasm

import cps/ui

proc StatCard(title: string, value: string): VNode =
  ui:
    article(className="rounded-2xl border border-slate-200/80 bg-white/80 p-4 shadow-sm backdrop-blur transition hover:-translate-y-0.5 hover:shadow-md"):
      p(className="text-xs font-semibold uppercase tracking-[0.12em] text-slate-500"): text(title)
      p(className="mt-2 text-3xl font-semibold text-slate-900"): text(value)

proc app(): VNode =
  let (view, setView) = useState("dashboard")
  let (count, setCount) = useState(0)
  let (name, setName) = useState("Gabriel")
  let (done, setDone) = useState(false)
  let (reversed, setReversed) = useState(false)
  let (captureCount, setCaptureCount) = useState(0)
  let (bubbleCount, setBubbleCount) = useState(0)

  let tasks =
    if reversed:
      @["deploy", "test", "code"]
    else:
      @["code", "test", "deploy"]

  let dotX = 10 + (count mod 10) * 10

  ui:
    `div`(className="mx-auto w-full max-w-6xl space-y-6 p-5 sm:p-8", attr("data-view", view)):
      header(className="rounded-3xl border border-slate-200/80 bg-white/85 p-6 shadow-xl shadow-slate-900/5 backdrop-blur"):
        p(className="text-xs font-semibold uppercase tracking-[0.16em] text-emerald-600"): text("Nim + CPS Runtime")
        h1(
          className="mt-2 text-3xl font-black tracking-tight text-slate-900 sm:text-4xl",
          attr("data-testid", "spa-title")
        ):
          text("CPS UI DSL SPA")
        p(className="mt-2 max-w-2xl text-sm text-slate-600"):
          text("A Tailwind-styled SPA rendered by Nim->WASM and served through the CPS HTTP server.")
        nav(className="mt-5 flex flex-wrap gap-2"):
          button(
            className=
              if view == "dashboard":
                "rounded-full bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm shadow-emerald-700/30"
              else:
                "rounded-full border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:border-emerald-500 hover:text-emerald-600",
            attr("data-testid", "nav-dashboard"),
            onClick=proc(ev: var UiEvent) = setView("dashboard")
          ):
            text("Dashboard")
          button(
            className=
              if view == "tasks":
                "rounded-full bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm shadow-emerald-700/30"
              else:
                "rounded-full border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:border-emerald-500 hover:text-emerald-600",
            attr("data-testid", "nav-tasks"),
            onClick=proc(ev: var UiEvent) = setView("tasks")
          ):
            text("Tasks")
          button(
            className=
              if view == "labs":
                "rounded-full bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm shadow-emerald-700/30"
              else:
                "rounded-full border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:border-emerald-500 hover:text-emerald-600",
            attr("data-testid", "nav-labs"),
            onClick=proc(ev: var UiEvent) = setView("labs")
          ):
            text("Labs")

      if view == "dashboard":
        section(
          className="grid gap-6 rounded-3xl border border-slate-200/80 bg-white/85 p-6 shadow-xl shadow-slate-900/5 backdrop-blur lg:grid-cols-[1.4fr_1fr]",
          attr("data-testid", "dashboard-section")
        ):
          `div`(className="space-y-4"):
            p(className="text-sm text-slate-500"): text("Operator")
            p(className="text-2xl font-semibold text-slate-900", attr("data-testid", "welcome")):
              text("Hello " & name & (if done: " [done]" else: " [pending]"))

            label(className="block text-sm font-medium text-slate-700"): text("Display Name")
            input(
              className="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-slate-900 outline-none ring-emerald-500 transition focus:border-emerald-500 focus:ring-2",
              attr("data-testid", "name-input"),
              value=name,
              onInput=proc(ev: var UiEvent) = setName(ev.value)
            )

            label(className="mt-2 inline-flex items-center gap-2 text-sm font-medium text-slate-700"):
              input(
                className="h-4 w-4 rounded border-slate-300 text-emerald-600 focus:ring-emerald-500",
                attr("data-testid", "done-checkbox"),
                checked=done,
                onChange=proc(ev: var UiEvent) = setDone(ev.checked)
              )
              text("Done")

            `div`(
              className="mt-4 rounded-2xl border border-amber-300/80 bg-amber-50/70 p-4",
              attr("data-testid", "capture-zone"),
              onClickCapture=proc(ev: var UiEvent) = setCaptureCount(captureCount + 1)
            ):
              p(className="mb-3 text-xs font-semibold uppercase tracking-[0.12em] text-amber-700"):
                text("Capture/Bubble Event Zone")
              button(
                className="rounded-xl bg-amber-500 px-3 py-2 text-sm font-semibold text-white shadow hover:bg-amber-600",
                attr("data-testid", "capture-button"),
                onClick=proc(ev: var UiEvent) = setBubbleCount(bubbleCount + 1)
              ):
                text("Click me")

            p(className="mt-3 text-sm text-amber-800", attr("data-testid", "capture-stats")):
              text("capture=" & $captureCount & ", bubble=" & $bubbleCount)

            button(
              className="rounded-xl bg-emerald-600 px-4 py-2 text-sm font-semibold text-white shadow-sm shadow-emerald-700/30 hover:bg-emerald-700",
              attr("data-testid", "inc-button"),
              onClick=proc(ev: var UiEvent) = setCount(count + 1)
            ):
              text("Increment")

          `div`(className="grid gap-3 sm:grid-cols-3"):
            StatCard(title = "Count", value = $count, key = "count")
            StatCard(title = "View", value = view, key = "view")
            StatCard(title = "Done", value = $done, key = "done")

      elif view == "tasks":
        section(
          className="space-y-4 rounded-3xl border border-slate-200/80 bg-white/85 p-6 shadow-xl shadow-slate-900/5 backdrop-blur",
          attr("data-testid", "tasks-section")
        ):
          h2(className="text-2xl font-bold text-slate-900"): text("Tasks")
          button(
            className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:border-emerald-500 hover:text-emerald-600",
            attr("data-testid", "toggle-order"),
            onClick=proc(ev: var UiEvent) = setReversed(not reversed)
          ):
            text(if reversed: "Normal Order" else: "Reverse Order")
          ul(className="space-y-2", attr("data-testid", "task-list")):
            for task in tasks:
              li(
                key = task,
                className = "rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-medium text-slate-700"
              ):
                text(task)

      else:
        section(
          className="space-y-4 rounded-3xl border border-slate-200/80 bg-white/85 p-6 shadow-xl shadow-slate-900/5 backdrop-blur",
          attr("data-testid", "labs-section")
        ):
          h2(className="text-2xl font-bold text-slate-900"): text("Labs")
          customTag(
            "nim-card",
            attr("data-testid", "custom-card"),
            attr("data-kind", "demo"),
            attr("class", "block rounded-2xl border border-indigo-300/80 bg-indigo-50/70 p-4 text-sm text-indigo-900")
          ):
            text("Custom element works")

          `svg`(
            className="h-16 w-full rounded-xl border border-slate-200 bg-slate-50 p-2",
            attr("data-testid", "sparkline"),
            viewBox="0 0 120 20",
            width="120",
            height="20"
          ):
            line(x1 = "0", y1 = "10", x2 = "120", y2 = "10", stroke = "#334155")
            circle(cx = dotX, cy = "10", r = "6", fill = "#0f766e")

          math(className="inline-flex rounded-lg bg-slate-100 px-2 py-1 text-lg text-slate-800", attr("data-testid", "math-sample"), display="inline"):
            mrow:
              mi: text("x")
              mo: text("+")
              mn: text("1")

      portal("#modal-root"):
        `div`(
          className="rounded-2xl border border-emerald-300/70 bg-emerald-50/80 px-4 py-3 text-sm font-medium text-emerald-900 shadow",
          attr("data-testid", "modal-status")
        ):
          text("Modal => view:" & view & ", name:" & name)

setRootComponent(app)
