## Momentum Workspace
## A functional productivity SPA built with cps/ui DSL.
##
## Build:
##   bash scripts/build_ui_wasm.sh examples/ui/workspace_app.nim examples/ui/workspace_app.wasm
##   nim c --mm:arc -d:release -o:examples/ui/workspace_demo_server examples/ui/workspace_demo_server.nim
##   ./examples/ui/workspace_demo_server

import std/[strutils, tables]
import cps/ui

type
  TaskStatus = enum
    tsInbox, tsDoing, tsDone

  TaskPriority = enum
    tpLow, tpMedium, tpHigh

  TaskFilter = enum
    tfAll, tfInbox, tfDoing, tfDone

  ThemeMode = enum
    tmMint, tmOcean, tmSunset

  Task = object
    id: int
    title: string
    notes: string
    status: TaskStatus
    priority: TaskPriority
    estimateMins: int
    focus: bool

  TaskState = object
    nextId: int
    items: seq[Task]
    query: string
    filter: TaskFilter
    selectedId: int

  TaskActionKind = enum
    taAdd, taRemove, taCycleStatus, taToggleFocus, taSetQuery, taSetFilter,
    taSelect, taCloseModal, taUpdateNotes, taBumpPriority, taAdjustEstimate, taRename

  TaskAction = object
    kind: TaskActionKind
    id: int
    text: string
    delta: int
    filter: TaskFilter

  TaskDispatch = proc(action: TaskAction) {.closure.}

  TaskModel = object
    state: TaskState
    dispatch: TaskDispatch

  ThemeModel = object
    mode: ThemeMode
    owner: string
    dense: bool
    setMode: proc(next: ThemeMode) {.closure.}
    setOwner: proc(next: string) {.closure.}
    setDense: proc(next: bool) {.closure.}

  ActivityModel = object
    items: seq[string]
    push: proc(msg: string) {.closure.}

  NetworkDemoModel = object
    fetchState: string
    fetchBody: string
    wsState: string
    wsLastMessage: string
    sseState: string
    sseLastEvent: string

  TaskStats = object
    inbox: int
    doing: int
    done: int
    focus: int
    totalMinutes: int

proc statusLabel(status: TaskStatus): string =
  case status
  of tsInbox: "Inbox"
  of tsDoing: "Doing"
  of tsDone: "Done"

proc priorityLabel(priority: TaskPriority): string =
  case priority
  of tpLow: "Low"
  of tpMedium: "Medium"
  of tpHigh: "High"

proc filterLabel(filter: TaskFilter): string =
  case filter
  of tfAll: "All"
  of tfInbox: "Inbox"
  of tfDoing: "Doing"
  of tfDone: "Done"

proc filterValue(filter: TaskFilter): string =
  case filter
  of tfAll: "all"
  of tfInbox: "inbox"
  of tfDoing: "doing"
  of tfDone: "done"

proc filterFromValue(value: string): TaskFilter =
  case value.toLowerAscii()
  of "inbox": tfInbox
  of "doing": tfDoing
  of "done": tfDone
  else: tfAll

proc modeValue(mode: ThemeMode): string =
  case mode
  of tmMint: "mint"
  of tmOcean: "ocean"
  of tmSunset: "sunset"

proc modeFromValue(value: string): ThemeMode =
  case value.toLowerAscii()
  of "ocean": tmOcean
  of "sunset": tmSunset
  else: tmMint

proc accentHex(mode: ThemeMode): string =
  case mode
  of tmMint: "#2dd4bf"
  of tmOcean: "#60a5fa"
  of tmSunset: "#fbbf24"

proc wsUrlForCurrentOrigin(path: string): string =
  let origin = locationOrigin()
  if origin.len == 0:
    return "ws://127.0.0.1:8080" & path
  if origin.startsWith("https://"):
    return "wss://" & origin["https://".len .. ^1] & path
  if origin.startsWith("http://"):
    return "ws://" & origin["http://".len .. ^1] & path
  origin & path

proc themeBadgeClass(mode: ThemeMode): string =
  case mode
  of tmMint: "bg-emerald-100 text-emerald-800 border-emerald-300"
  of tmOcean: "bg-blue-100 text-blue-800 border-blue-300"
  of tmSunset: "bg-amber-100 text-amber-800 border-amber-300"

proc priorityClass(priority: TaskPriority): string =
  case priority
  of tpLow: "bg-slate-100 text-slate-700 border-slate-200"
  of tpMedium: "bg-violet-100 text-violet-700 border-violet-200"
  of tpHigh: "bg-rose-100 text-rose-700 border-rose-200"

proc statusClass(status: TaskStatus): string =
  case status
  of tsInbox: "bg-slate-100 text-slate-700 border-slate-200"
  of tsDoing: "bg-sky-100 text-sky-700 border-sky-200"
  of tsDone: "bg-emerald-100 text-emerald-700 border-emerald-200"

proc statusDotColor(status: TaskStatus): string =
  case status
  of tsInbox: "#64748b"
  of tsDoing: "#38bdf8"
  of tsDone: "#34d399"

proc transportTone(status: string): string =
  let lowered = status.toLowerAscii()
  if lowered.startsWith("error"):
    return "border-rose-200 bg-rose-50 text-rose-700"
  if lowered.startsWith("message") or lowered.startsWith("event") or lowered.startsWith("open") or lowered.startsWith("200"):
    return "border-emerald-200 bg-emerald-50 text-emerald-700"
  if lowered.startsWith("connecting") or lowered.startsWith("loading"):
    return "border-amber-200 bg-amber-50 text-amber-700"
  "border-slate-200 bg-slate-50 text-slate-600"

proc nextStatus(status: TaskStatus): TaskStatus =
  case status
  of tsInbox: tsDoing
  of tsDoing: tsDone
  of tsDone: tsInbox

proc nextPriority(priority: TaskPriority): TaskPriority =
  case priority
  of tpLow: tpMedium
  of tpMedium: tpHigh
  of tpHigh: tpLow

proc matchesFilter(filter: TaskFilter, status: TaskStatus): bool =
  case filter
  of tfAll: true
  of tfInbox: status == tsInbox
  of tfDoing: status == tsDoing
  of tfDone: status == tsDone

proc taskFingerprint(items: seq[Task]): uint64 =
  var hash = 1469598103934665603'u64
  for item in items:
    hash = (hash xor uint64(item.id + 17)) * 1099511628211'u64
    hash = (hash xor uint64(ord(item.status) + 3)) * 1099511628211'u64
    hash = (hash xor uint64(ord(item.priority) + 5)) * 1099511628211'u64
    hash = (hash xor uint64(item.estimateMins + 11)) * 1099511628211'u64
    hash = (hash xor uint64(if item.focus: 1 else: 0)) * 1099511628211'u64
    for ch in item.title:
      hash = (hash xor uint64(ord(ch))) * 1099511628211'u64
    for ch in item.notes:
      hash = (hash xor uint64(ord(ch))) * 1099511628211'u64
  hash

proc computeStats(items: seq[Task]): TaskStats =
  for item in items:
    case item.status
    of tsInbox: inc result.inbox
    of tsDoing: inc result.doing
    of tsDone: inc result.done
    if item.focus:
      inc result.focus
    result.totalMinutes += item.estimateMins

proc filteredTasks(state: TaskState): seq[Task] =
  let q = state.query.toLowerAscii().strip()
  for item in state.items:
    if not matchesFilter(state.filter, item.status):
      continue
    if q.len > 0:
      let hay = (item.title & " " & item.notes).toLowerAscii()
      if hay.find(q) < 0:
        continue
    result.add item

proc selectedTask(state: TaskState): tuple[found: bool, task: Task] =
  for item in state.items:
    if item.id == state.selectedId:
      return (true, item)
  (false, Task())

proc parseGoalFormula(formula: string): int =
  let cleaned = formula.strip()
  if cleaned.len == 0:
    raise newException(ValueError, "formula is empty")
  for term in cleaned.split('+'):
    let part = term.strip()
    if part.len == 0:
      raise newException(ValueError, "empty term")
    result += parseInt(part)
  if result <= 0:
    raise newException(ValueError, "goal must be positive")

proc initialTaskState(): TaskState =
  TaskState(
    nextId: 5,
    query: "",
    filter: tfAll,
    selectedId: 0,
    items: @[
      Task(
        id: 1,
        title: "Plan weekly roadmap",
        notes: "Draft milestones and dependencies for the team meeting.",
        status: tsDoing,
        priority: tpHigh,
        estimateMins: 60,
        focus: true
      ),
      Task(
        id: 2,
        title: "Review pull requests",
        notes: "Focus on runtime stability and wasm CI checks.",
        status: tsInbox,
        priority: tpMedium,
        estimateMins: 45,
        focus: false
      ),
      Task(
        id: 3,
        title: "Write release notes",
        notes: "Capture breaking DSL updates with migration examples.",
        status: tsInbox,
        priority: tpLow,
        estimateMins: 30,
        focus: true
      ),
      Task(
        id: 4,
        title: "Ship browser matrix fixes",
        notes: "Verify Chromium/Firefox/WebKit all pass.",
        status: tsDone,
        priority: tpMedium,
        estimateMins: 40,
        focus: false
      )
    ]
  )

proc taskReducer(state: TaskState, action: TaskAction): TaskState =
  result = state
  case action.kind
  of taAdd:
    let title = action.text.strip()
    if title.len == 0:
      return state
    result.items.add Task(
      id: state.nextId,
      title: title,
      notes: "Add context and next steps.",
      status: tsInbox,
      priority: tpMedium,
      estimateMins: 25,
      focus: false
    )
    result.nextId = state.nextId + 1
    result.selectedId = state.nextId

  of taRemove:
    var kept: seq[Task] = @[]
    for item in state.items:
      if item.id != action.id:
        kept.add item
    result.items = kept
    if result.selectedId == action.id:
      result.selectedId = 0

  of taCycleStatus:
    for item in result.items.mitems:
      if item.id == action.id:
        item.status = nextStatus(item.status)
        break

  of taToggleFocus:
    for item in result.items.mitems:
      if item.id == action.id:
        item.focus = not item.focus
        break

  of taSetQuery:
    result.query = action.text

  of taSetFilter:
    result.filter = action.filter

  of taSelect:
    result.selectedId = action.id

  of taCloseModal:
    result.selectedId = 0

  of taUpdateNotes:
    for item in result.items.mitems:
      if item.id == action.id:
        item.notes = action.text
        break

  of taBumpPriority:
    for item in result.items.mitems:
      if item.id == action.id:
        item.priority = nextPriority(item.priority)
        break

  of taAdjustEstimate:
    for item in result.items.mitems:
      if item.id == action.id:
        let nextVal = item.estimateMins + action.delta
        item.estimateMins = if nextVal < 5: 5 else: nextVal
        break

  of taRename:
    let name = action.text.strip()
    if name.len == 0:
      return state
    for item in result.items.mitems:
      if item.id == action.id:
        item.title = name
        break

let TaskCtx = createContext(TaskModel(state: initialTaskState(), dispatch: nil))
let ThemeCtx = createContext(
  ThemeModel(
    mode: tmMint,
    owner: "Operator",
    dense: false,
    setMode: nil,
    setOwner: nil,
    setDense: nil
  )
)
let ActivityCtx = createContext(ActivityModel(items: @[], push: nil))
let NetworkDemoCtx = createContext(
  NetworkDemoModel(
    fetchState: "idle",
    fetchBody: "-",
    wsState: "idle",
    wsLastMessage: "-",
    sseState: "idle",
    sseLastEvent: "-"
  )
)

proc emitActivity(activity: ActivityModel, message: string) =
  if activity.push != nil:
    activity.push(message)

# ═══════════════════════════════════════════════════════════════
# Rendering Components
# ═══════════════════════════════════════════════════════════════

proc StatCard(title: string, value: string, subtitle: string, tint: string, icon: string): VNode =
  ui:
    article(className="rounded-2xl border p-5 shadow-sm " & tint):
      `div`(className="flex items-center justify-between"):
        p(className="text-[10px] font-bold uppercase tracking-[0.16em] text-slate-400"):
          text(title)
        span(className="text-base opacity-60"):
          text(icon)
      p(className="mt-3 text-3xl font-black tracking-tight tabular-nums"):
        text(value)
      p(className="mt-1.5 text-xs opacity-60"):
        text(subtitle)

proc GoalPreview(formula: string): VNode =
  let minutes = parseGoalFormula(formula)
  ui:
    `div`(
      className = "rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-emerald-800",
      attr("data-testid", "goal-preview")
    ):
      `div`(className="flex items-center gap-2"):
        span(className="text-sm"): text("\xE2\x97\x8E")
        p(className="text-[10px] font-bold uppercase tracking-[0.14em]"): text("Daily Goal")
      p(className="mt-2 text-2xl font-black tabular-nums"): text($minutes)
      p(className="text-xs opacity-70"): text("focused minutes")

proc ProgressRing(pct: int, accent: string, size: int = 120): VNode =
  let r = (size div 2) - 10
  let circumference = 2.0 * 3.14159265 * float(r)
  let offset = circumference * (1.0 - float(pct) / 100.0)
  let viewBox = "0 0 " & $size & " " & $size
  let center = $(size div 2)
  ui:
    svg(
      className="progress-ring",
      attr("viewBox", viewBox),
      attr("width", $size),
      attr("height", $size)
    ):
      circle(
        cx=center, cy=center, r= $r,
        fill="none",
        attr("stroke", "rgba(255,255,255,0.04)"),
        attr("stroke-width", "7")
      )
      circle(
        cx=center, cy=center, r= $r,
        fill="none",
        attr("stroke", accent),
        attr("stroke-width", "7"),
        attr("stroke-linecap", "round"),
        attr("stroke-dasharray", $circumference),
        attr("stroke-dashoffset", $offset),
        styleProp("transform", "rotate(-90deg)"),
        styleProp("transform-origin", "center"),
        styleProp("transition", "stroke-dashoffset 0.8s cubic-bezier(0.4,0,0.2,1)"),
        styleProp("filter", "drop-shadow(0 0 8px " & accent & "40)")
      )

proc DashboardPage(): VNode =
  let tasks = useContext(TaskCtx)
  let theme = useContext(ThemeCtx)
  let activity = useContext(ActivityCtx)
  let (draftTitle, setDraftTitle) = useState("")
  let (pointerStatus, setPointerStatus) = useState("Move over the focus map")
  let (tipHidden, setTipHidden) = useState(false)
  let quickInputRef = useMemo(proc(): NodeRef = createNodeRef(), deps())

  let fingerprint = taskFingerprint(tasks.state.items)
  let stats = useMemo(
    proc(): TaskStats = computeStats(tasks.state.items),
    deps(fingerprint)
  )

  let completionPct =
    if tasks.state.items.len == 0:
      0
    else:
      (stats.done * 100) div tasks.state.items.len

  var spotlight: seq[Task] = @[]
  for item in tasks.state.items:
    if item.status != tsDone:
      spotlight.add item
    if spotlight.len == 3:
      break

  proc submitQuickAdd(ev: var UiEvent) =
    preventDefault(ev)
    let title = draftTitle.strip()
    if title.len == 0 or tasks.dispatch == nil:
      return
    tasks.dispatch(TaskAction(kind: taAdd, text: title))
    setDraftTitle("")
    emitActivity(activity, "Added from dashboard: " & title)

  let pointerMoveOpts = opts(passive = true)
  let tipDismissOpts = opts(`once` = true)

  ui:
    `div`(className="space-y-5"):
      # ─── Welcome Hero ───
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-6 shadow-xl sm:p-8"):
        `div`(className="flex flex-col gap-6 lg:flex-row lg:items-center lg:justify-between"):
          `div`(className="max-w-2xl"):
            p(className="text-[10px] font-bold uppercase tracking-[0.18em] text-slate-500"):
              text("Welcome Back")
            h2(className="mt-2 text-3xl font-black tracking-tight text-slate-900 sm:text-4xl"):
              text(theme.owner & "'s Workspace")
            p(className="mt-2 text-sm leading-relaxed text-slate-600"):
              text("Capture priority work, stay in flow, and keep your team aligned.")

            form(className="mt-5 flex gap-2", onSubmit=submitQuickAdd):
              input(
                className="flex-1 rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-sm text-slate-800 outline-none ring-emerald-500 transition focus:border-emerald-500 focus:ring-2",
                attr("placeholder", "Quick capture \xE2\x80\x94 what needs doing?"),
                attr("data-testid", "quick-input"),
                refProp(quickInputRef),
                value=draftTitle,
                onFocus=proc(ev: var UiEvent) = setPointerStatus("Quick capture ready"),
                onBlur=proc(ev: var UiEvent) = setPointerStatus("Quick capture paused"),
                onInput=proc(ev: var UiEvent) = setDraftTitle(ev.value)
              )
              button(
                className="rounded-xl bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white shadow hover:bg-slate-800",
                attr("type", "submit"),
                attr("data-testid", "quick-add-btn")
              ):
                text("Add")

          # ─── Progress Ring ───
          `div`(className="flex flex-col items-center gap-2"):
            ProgressRing(completionPct, accentHex(theme.mode), 128)
            p(className="text-2xl font-black tracking-tight text-slate-900 tabular-nums"):
              text($completionPct & "%")
            p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
              text("complete")

      # ─── Stat Cards Grid ───
      section(className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4 !border-0 !bg-transparent !shadow-none"):
        StatCard(
          title = "Inbox",
          value = $stats.inbox,
          subtitle = "newly captured",
          tint = "border-slate-200 bg-slate-50 text-slate-800",
          icon = "\xE2\x97\x87"
        )
        StatCard(
          title = "In Progress",
          value = $stats.doing,
          subtitle = "actively moving",
          tint = "border-sky-200 bg-sky-50 text-sky-800",
          icon = "\xE2\x96\xB6"
        )
        StatCard(
          title = "Done",
          value = $stats.done,
          subtitle = $completionPct & "% of total",
          tint = "border-emerald-200 bg-emerald-50 text-emerald-800",
          icon = "\xE2\x9C\x93"
        )
        StatCard(
          title = "Focus",
          value = $stats.focus,
          subtitle = $stats.totalMinutes & " planned min",
          tint = "border-amber-200 bg-amber-50 text-amber-800",
          icon = "\xE2\x97\x8E"
        )

      # ─── Completion Trend + Spotlight ───
      section(
        className="grid gap-5 rounded-3xl border border-slate-200 bg-white/85 p-5 shadow-lg lg:grid-cols-[1.2fr_1fr]",
        on(etPointerMove, proc(ev: var UiEvent) =
          let pointerType = eventExtra(ev, "pointerType", "pointer")
          setPointerStatus(pointerType & " @ " & $ev.clientX & "," & $ev.clientY)
        , pointerMoveOpts),
        attr("data-testid", "dashboard-map")
      ):
        `div`(className="space-y-4"):
          h3(className="text-lg font-bold text-slate-900"): text("Completion Trend")
          p(className="text-sm text-slate-600"):
            text("Daily momentum pulse check across your active board.")

          # Progress bar
          `div`(className="h-3 w-full rounded-full bg-slate-200 progress-track"):
            `div`(
              className="h-3 rounded-full transition-all duration-500 progress-fill",
              styleProp("width", $completionPct & "%"),
              styleProp("background", "linear-gradient(90deg, " & accentHex(theme.mode) & ", " & accentHex(theme.mode) & "cc)")
            )

          `div`(className="flex items-center justify-between"):
            p(className="text-xs text-slate-500"): text(pointerStatus)
            customTag(
              "focus-chip",
              attr("class", "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-semibold " & themeBadgeClass(theme.mode)),
              attr("data-owner", theme.owner)
            ):
              text(theme.owner)

        `div`(className="rounded-2xl border border-slate-200 bg-slate-50 p-4"):
          h4(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
            text("Spotlight")
          if spotlight.len == 0:
            p(className="mt-4 text-sm text-slate-500"): text("No active tasks. Add one above.")
          else:
            ul(className="mt-3 space-y-2"):
              for item in spotlight:
                li(
                  key = $item.id,
                  className="flex items-center gap-3 rounded-xl border border-slate-200 bg-white px-3 py-2.5"
                ):
                  # Status dot
                  span(
                    className="h-2 w-2 shrink-0 rounded-full",
                    styleProp("background-color", statusDotColor(item.status))
                  )
                  `div`(className="min-w-0 flex-1"):
                    p(className="truncate text-sm font-semibold text-slate-800"):
                      text(item.title)
                    p(className="text-[11px] text-slate-500"):
                      text(statusLabel(item.status) & " \xC2\xB7 " & $item.estimateMins & "m")

      # ─── Tip Banner ───
      if not tipHidden:
        section(className="flex items-center justify-between rounded-2xl border border-amber-200 bg-amber-50 px-5 py-3 text-amber-900 shadow-sm"):
          `div`:
            p(className="text-sm font-medium"):
              text("Press Ctrl/Cmd + K for quick navigation")
          button(
            className="rounded-lg bg-amber-500 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-600",
            on(etClick, proc(ev: var UiEvent) =
              setTipHidden(true)
              emitActivity(activity, "Dismissed onboarding tip")
            , tipDismissOpts)
          ):
            text("Got it")

proc TasksPage(): VNode =
  let tasks = useContext(TaskCtx)
  let activity = useContext(ActivityCtx)
  let (draftTitle, setDraftTitle) = useState("")
  let (listHint, setListHint) = useState("")

  let fingerprint = taskFingerprint(tasks.state.items)
  let visible = useMemo(
    proc(): seq[Task] = filteredTasks(tasks.state),
    deps(fingerprint, tasks.state.query, ord(tasks.state.filter))
  )

  useLayoutEffect(
    proc(): EffectCleanup =
      setListHint($visible.len & " " & filterLabel(tasks.state.filter).toLowerAscii() & " tasks")
      proc() = discard,
    deps(visible.len, tasks.state.query, ord(tasks.state.filter))
  )

  proc dispatch(action: TaskAction) =
    if tasks.dispatch != nil:
      tasks.dispatch(action)

  proc renderTaskRow(item: Task): VNode =
    ui:
      li(
        key = $item.id,
        className="rounded-2xl border border-slate-200 bg-slate-50 p-4",
        onClick=proc(ev: var UiEvent) = dispatch(TaskAction(kind: taSelect, id: item.id))
      ):
        `div`(className="flex items-start gap-3"):
          # Status indicator dot
          `div`(className="mt-1.5 flex flex-col items-center gap-1"):
            span(
              className="h-2.5 w-2.5 rounded-full",
              styleProp("background-color", statusDotColor(item.status)),
              styleProp("box-shadow", "0 0 8px " & statusDotColor(item.status) & "40")
            )

          `div`(className="min-w-0 flex-1"):
            `div`(className="flex flex-wrap items-center gap-2"):
              p(className="font-semibold text-slate-900"): text(item.title)
              if item.focus:
                span(className="rounded-full border border-amber-300 bg-amber-100 px-2 py-0.5 text-[10px] font-bold text-amber-700"):
                  text("Focus")

            `div`(className="mt-1 flex flex-wrap items-center gap-2 text-xs text-slate-500"):
              span: text($item.estimateMins & " min")
              span(className="opacity-40"): text("\xC2\xB7")
              span(className="rounded-full border px-2 py-0.5 text-[10px] font-semibold " & statusClass(item.status)):
                text(statusLabel(item.status))
              span(className="rounded-full border px-2 py-0.5 text-[10px] font-semibold " & priorityClass(item.priority)):
                text(priorityLabel(item.priority))

            if item.notes.len > 0:
              p(className="mt-1.5 text-xs text-slate-500 line-clamp-1"):
                text(item.notes)

        # ─── Actions ───
        `div`(className="mt-3 flex flex-wrap gap-1.5 pl-6"):
          button(
            className="rounded-lg border border-slate-300 bg-white px-2.5 py-1 text-xs font-semibold text-slate-700 hover:border-slate-500",
            onClick=proc(ev: var UiEvent) =
              stopPropagation(ev)
              dispatch(TaskAction(kind: taCycleStatus, id: item.id))
          ):
            text("Status \xE2\x86\x92")
          button(
            className="rounded-lg border border-violet-300 bg-violet-50 px-2.5 py-1 text-xs font-semibold text-violet-700",
            onClick=proc(ev: var UiEvent) =
              stopPropagation(ev)
              dispatch(TaskAction(kind: taBumpPriority, id: item.id))
          ):
            text("Priority")
          label(className="inline-flex cursor-pointer items-center gap-1 rounded-lg border border-amber-200 bg-amber-50 px-2.5 py-1 text-xs font-semibold text-amber-700"):
            input(
              className="h-3.5 w-3.5 rounded border-amber-300",
              attr("type", "checkbox"),
              checked=item.focus,
              onChange=proc(ev: var UiEvent) =
                stopPropagation(ev)
                dispatch(TaskAction(kind: taToggleFocus, id: item.id))
            )
            text("Focus")
          button(
            className="rounded-lg border border-slate-300 bg-white px-2.5 py-1 text-xs font-semibold text-slate-700",
            onClick=proc(ev: var UiEvent) =
              stopPropagation(ev)
              dispatch(TaskAction(kind: taAdjustEstimate, id: item.id, delta: -5))
          ):
            text("-5m")
          button(
            className="rounded-lg border border-slate-300 bg-white px-2.5 py-1 text-xs font-semibold text-slate-700",
            onClick=proc(ev: var UiEvent) =
              stopPropagation(ev)
              dispatch(TaskAction(kind: taAdjustEstimate, id: item.id, delta: 5))
          ):
            text("+5m")
          button(
            className="rounded-lg border border-rose-200 bg-rose-50 px-2.5 py-1 text-xs font-semibold text-rose-700",
            onClick=proc(ev: var UiEvent) =
              stopPropagation(ev)
              dispatch(TaskAction(kind: taRemove, id: item.id))
          ):
            text("Remove")

  proc submitAdd(ev: var UiEvent) =
    preventDefault(ev)
    let title = draftTitle.strip()
    if title.len == 0:
      return
    dispatch(TaskAction(kind: taAdd, text: title))
    setDraftTitle("")
    emitActivity(activity, "Added task from board: " & title)

  ui:
    `div`(className="space-y-4"):
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl"):
        `div`(className="flex flex-wrap items-center justify-between gap-3"):
          `div`(className="flex items-center gap-3"):
            h2(className="text-2xl font-black tracking-tight text-slate-900"): text("Task Board")
            customTag(
              "board-chip",
              attr("class", "inline-flex items-center rounded-full border border-slate-200 bg-slate-100 px-3 py-1 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-600 tabular-nums")
            ):
              text(listHint)

        form(className="mt-4 flex flex-col gap-2 sm:flex-row", onSubmit=submitAdd):
          input(
            className="flex-1 rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-sm text-slate-800 outline-none ring-sky-500 transition focus:border-sky-500 focus:ring-2",
            attr("placeholder", "New task title"),
            attr("data-testid", "tasks-add-input"),
            value=draftTitle,
            onInput=proc(ev: var UiEvent) = setDraftTitle(ev.value)
          )
          input(
            className="sm:max-w-[200px] rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-sm text-slate-800 outline-none ring-sky-500 transition focus:border-sky-500 focus:ring-2",
            attr("placeholder", "Search\xE2\x80\xA6"),
            attr("data-testid", "tasks-query-input"),
            value=tasks.state.query,
            onInput=proc(ev: var UiEvent) = dispatch(TaskAction(kind: taSetQuery, text: ev.value))
          )
          button(
            className="rounded-xl bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white hover:bg-slate-800",
            attr("type", "submit")
          ):
            text("Add")

        `div`(className="mt-3 flex flex-wrap items-center gap-2"):
          p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"): text("Filter")
          select(
            className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700",
            value=filterValue(tasks.state.filter),
            onChange=proc(ev: var UiEvent) =
              dispatch(TaskAction(kind: taSetFilter, filter: filterFromValue(ev.value)))
          ):
            option(value="all"): text("All")
            option(value="inbox"): text("Inbox")
            option(value="doing"): text("Doing")
            option(value="done"): text("Done")

      section(className="rounded-3xl border border-slate-200 bg-white/90 p-4 shadow-lg"):
        if visible.len == 0:
          `div`(className="flex flex-col items-center gap-2 py-8"):
            p(className="text-3xl opacity-20"): text("\xE2\x97\x87")
            p(className="text-sm text-slate-500"): text("No tasks match this filter.")
        else:
          ul(className="space-y-2", attr("data-testid", "task-list")):
            for item in visible:
              renderTaskRow(item)

proc FocusPage(): VNode =
  let tasks = useContext(TaskCtx)
  let activity = useContext(ActivityCtx)
  let navigate = useNavigate()
  let (completedSessions, setCompletedSessions) = useStateFn(0)
  let (boardEnergy, setBoardEnergy) = useStateFn(0)

  let fingerprint = taskFingerprint(tasks.state.items)
  let queue = useMemo(
    proc(): seq[Task] =
      for item in tasks.state.items:
        if item.focus and item.status != tsDone:
          result.add item
    ,
    deps(fingerprint)
  )

  proc dispatch(action: TaskAction) =
    if tasks.dispatch != nil:
      tasks.dispatch(action)

  proc completeNextFocus(ev: var UiEvent) =
    if queue.len == 0:
      return
    let item = queue[0]
    dispatch(TaskAction(kind: taCycleStatus, id: item.id))
    setCompletedSessions(proc(prev: int): int = prev + 1)
    emitActivity(activity, "Completed focus block: " & item.title)

  ui:
    `div`(className="space-y-4"):
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-6 shadow-xl sm:p-8"):
        `div`(className="flex flex-col items-center text-center"):
          # Breathing ring decoration
          `div`(className="breathe-ring mb-4 h-20 w-20 opacity-50")
          h2(className="text-2xl font-black tracking-tight text-slate-900"): text("Focus Planner")
          p(className="mt-1 max-w-md text-sm text-slate-600"):
            text("Build deep-work momentum from your prioritized queue.")
          `div`(className="mt-5 flex flex-wrap justify-center gap-2"):
            button(
              className="rounded-xl bg-emerald-600 px-5 py-2.5 text-sm font-semibold text-white shadow hover:bg-emerald-700",
              attr("data-testid", "focus-complete-btn"),
              onClick=completeNextFocus
            ):
              text("Complete Next Block")
            button(
              className="rounded-xl border border-slate-300 bg-white px-5 py-2.5 text-sm font-semibold text-slate-700",
              onClick=proc(ev: var UiEvent) = navigate("/tasks")
            ):
              text("Open Board")
          p(className="mt-3 text-xs tabular-nums text-slate-500"):
            text("Sessions completed: " & $completedSessions)

      section(
        className="rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-lg",
        attr("data-testid", "focus-queue"),
        onPointerDown=proc(ev: var UiEvent) =
          setBoardEnergy(proc(prev: int): int = prev + 1),
        onPointerUp=proc(ev: var UiEvent) =
          setBoardEnergy(proc(prev: int): int = prev + 1)
      ):
        `div`(className="flex items-center justify-between"):
          h3(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
            text("Focus Queue")
          span(className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500 tabular-nums"):
            text("Energy: " & $boardEnergy)
        if queue.len == 0:
          `div`(className="flex flex-col items-center gap-2 py-8"):
            p(className="text-3xl opacity-20"): text("\xE2\x97\x8E")
            p(className="text-sm text-slate-500"):
              text("No focus tasks. Mark a task as focus in the board.")
        else:
          ul(className="mt-3 space-y-2"):
            for idx, item in queue:
              li(
                key = $item.id,
                className="flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2.5"
              ):
                span(className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-slate-300 bg-white text-[10px] font-bold text-slate-500 tabular-nums"):
                  text($(idx + 1))
                `div`(className="min-w-0 flex-1"):
                  p(className="truncate text-sm font-semibold text-slate-800"): text(item.title)
                span(className="shrink-0 text-xs tabular-nums text-slate-500"):
                  text($item.estimateMins & "m")

proc SettingsPage(): VNode =
  let theme = useContext(ThemeCtx)
  let activity = useContext(ActivityCtx)
  let (goalFormula, setGoalFormula) = useState("25+10+5")
  let (savedBanner, setSavedBanner) = useState(false)
  let goalPreviewNode = component(
    proc(): VNode = GoalPreview(goalFormula),
    key = "goal-preview",
    typeName = "GoalPreview"
  )
  let goalFallback = proc(msg: string): VNode =
    ui:
      p(
        className = "rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700",
        attr("data-testid", "goal-fallback")
      ):
        text("Formula error: " & msg)

  proc persistSettings(ev: var UiEvent) =
    preventDefault(ev)
    setSavedBanner(true)
    emitActivity(activity, "Saved workspace settings")

  ui:
    `div`(className="space-y-4"):
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-6 shadow-xl"):
        h2(className="text-2xl font-black tracking-tight text-slate-900"): text("Settings")
        p(className="mt-1 text-sm text-slate-600"): text("Personalize your workspace experience.")

        form(className="mt-5 space-y-4", onSubmit=persistSettings):
          # ─── Owner Name ───
          label(className="block space-y-1.5"):
            p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
              text("Owner Name")
            input(
              className="w-full rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-slate-800 outline-none ring-emerald-500 transition focus:border-emerald-500 focus:ring-2",
              attr("data-testid", "owner-input"),
              value=theme.owner,
              onInput=proc(ev: var UiEvent) =
                if theme.setOwner != nil:
                  theme.setOwner(ev.value)
                  setSavedBanner(false)
            )

          # ─── Theme ───
          label(className="block space-y-1.5"):
            p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
              text("Theme")
            select(
              className="w-full rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-slate-800",
              value=modeValue(theme.mode),
              attr("data-testid", "theme-select"),
              onChange=proc(ev: var UiEvent) =
                if theme.setMode != nil:
                  theme.setMode(modeFromValue(ev.value))
                  setSavedBanner(false)
            ):
              option(value="mint"): text("Mint")
              option(value="ocean"): text("Ocean")
              option(value="sunset"): text("Sunset")

          # Theme preview swatches
          `div`(className="flex gap-2"):
            `div`(
              className="h-8 w-8 rounded-full border-2 transition-all",
              styleProp("background-color", "#2dd4bf"),
              styleProp("border-color", if theme.mode == tmMint: "white" else: "transparent"),
              styleProp("box-shadow", if theme.mode == tmMint: "0 0 0 2px #2dd4bf" else: "none")
            )
            `div`(
              className="h-8 w-8 rounded-full border-2 transition-all",
              styleProp("background-color", "#60a5fa"),
              styleProp("border-color", if theme.mode == tmOcean: "white" else: "transparent"),
              styleProp("box-shadow", if theme.mode == tmOcean: "0 0 0 2px #60a5fa" else: "none")
            )
            `div`(
              className="h-8 w-8 rounded-full border-2 transition-all",
              styleProp("background-color", "#fbbf24"),
              styleProp("border-color", if theme.mode == tmSunset: "white" else: "transparent"),
              styleProp("box-shadow", if theme.mode == tmSunset: "0 0 0 2px #fbbf24" else: "none")
            )

          # ─── Compact density ───
          label(className="inline-flex cursor-pointer items-center gap-2.5 text-sm font-semibold text-slate-700"):
            input(
              className="h-4 w-4 rounded border-slate-300",
              attr("type", "checkbox"),
              checked=theme.dense,
              onChange=proc(ev: var UiEvent) =
                if theme.setDense != nil:
                  theme.setDense(ev.checked)
                  setSavedBanner(false)
            )
            text("Compact density")

          button(
            className="rounded-xl bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white hover:bg-slate-800",
            attr("type", "submit")
          ):
            text("Save Preferences")

        if savedBanner:
          p(className="mt-3 rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-sm text-emerald-700"):
            text("Preferences saved for this session.")

      # ─── Goal Parser ───
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-lg"):
        h3(className="text-lg font-bold text-slate-900"): text("Daily Goal Parser")
        p(className="mt-1 text-sm text-slate-600"):
          text("Use a + separated formula to set your target focus minutes.")
        input(
          className="mt-3 w-full rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-slate-800 outline-none ring-amber-500 transition focus:border-amber-500 focus:ring-2",
          attr("data-testid", "goal-formula"),
          value=goalFormula,
          onInput=proc(ev: var UiEvent) = setGoalFormula(ev.value)
        )
        `div`(className="mt-3"):
          errorBoundary(goalPreviewNode, goalFallback, "goal-boundary")

proc InsightsPage(): VNode =
  let info = useRoute()
  let tasks = useContext(TaskCtx)
  let stats = computeStats(tasks.state.items)
  let sectionName = info.params.getOrDefault("section", "overview")
  let range = info.query.getOrDefault("range", "7d")

  let total = stats.inbox + stats.doing + stats.done
  let donePct = if total == 0: 0 else: (stats.done * 100) div total
  let doingPct = if total == 0: 0 else: (stats.doing * 100) div total
  let inboxPct = if total == 0: 0 else: (stats.inbox * 100) div total

  ui:
    `div`(className="space-y-4"):
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-6 shadow-xl"):
        `div`(className="flex flex-wrap items-center justify-between gap-3"):
          `div`:
            p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
              text("Analytics")
            h2(className="mt-1 text-2xl font-black tracking-tight text-slate-900"):
              text("Insights: " & sectionName)
          `div`(className="flex items-center gap-2"):
            span(className="rounded-full border border-slate-200 bg-slate-100 px-3 py-1 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-600"):
              text(range)
            span(className="rounded-full border border-emerald-200 bg-emerald-100 px-3 py-1 text-[10px] font-bold text-emerald-700 tabular-nums"):
              text($donePct & "% done")

      section(className="rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-lg"):
        # ─── Horizontal stacked bar ───
        `div`(className="space-y-3"):
          h3(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
            text("Distribution")
          `div`(className="flex h-8 w-full overflow-hidden rounded-lg"):
            if donePct > 0:
              `div`(
                className="flex items-center justify-center text-[10px] font-bold text-white",
                styleProp("width", $donePct & "%"),
                styleProp("background", "#10b981"),
                styleProp("min-width", "24px")
              ): text($stats.done)
            if doingPct > 0:
              `div`(
                className="flex items-center justify-center text-[10px] font-bold text-white",
                styleProp("width", $doingPct & "%"),
                styleProp("background", "#0ea5e9"),
                styleProp("min-width", "24px")
              ): text($stats.doing)
            if inboxPct > 0:
              `div`(
                className="flex items-center justify-center text-[10px] font-bold text-white",
                styleProp("width", $inboxPct & "%"),
                styleProp("background", "#64748b"),
                styleProp("min-width", "24px")
              ): text($stats.inbox)
          # Legend
          `div`(className="flex flex-wrap gap-4 text-xs"):
            `div`(className="flex items-center gap-1.5"):
              span(className="h-2.5 w-2.5 rounded-full", styleProp("background", "#10b981"))
              text("Done " & $stats.done)
            `div`(className="flex items-center gap-1.5"):
              span(className="h-2.5 w-2.5 rounded-full", styleProp("background", "#0ea5e9"))
              text("Doing " & $stats.doing)
            `div`(className="flex items-center gap-1.5"):
              span(className="h-2.5 w-2.5 rounded-full", styleProp("background", "#64748b"))
              text("Inbox " & $stats.inbox)

      # ─── SVG bar chart ───
      section(className="rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-lg"):
        h3(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
          text("Breakdown")
        svg(
          className="mt-3 w-full",
          attr("viewBox", "0 0 420 120"),
          attr("width", "420"),
          attr("height", "120")
        ):
          rect(x="10", y="20", width = $((donePct * 3) + 20), height="24", fill="#10b981", attr("rx", "6"))
          rect(x="10", y="58", width = $((doingPct * 3) + 20), height="24", fill="#0ea5e9", attr("rx", "6"))
          rect(x="10", y="96", width = $((inboxPct * 3) + 20), height="12", fill="#64748b", attr("rx", "4"))
          text(x="16", y="36", fill="#ffffff"): text("Done " & $stats.done)
          text(x="16", y="74", fill="#ffffff"): text("Doing " & $stats.doing)

proc TaskDetailModal(): VNode =
  let tasks = useContext(TaskCtx)
  let theme = useContext(ThemeCtx)
  let selected = selectedTask(tasks.state)
  if not selected.found:
    return nil

  let item = selected.task

  proc dispatch(action: TaskAction) =
    if tasks.dispatch != nil:
      tasks.dispatch(action)

  proc closeModal(ev: var UiEvent) =
    dispatch(TaskAction(kind: taCloseModal))

  ui:
    portal("#modal-root"):
      `div`(
        className="fixed inset-0 z-40 flex items-center justify-center bg-slate-900/40 p-4 backdrop-blur-sm",
        attr("data-testid", "task-modal"),
        onClick=closeModal
      ):
        `div`(
          className="w-full max-w-xl rounded-3xl border border-slate-200 bg-white p-6 shadow-2xl",
          onClick=proc(ev: var UiEvent) = stopPropagation(ev)
        ):
          # ─── Header ───
          `div`(className="flex items-start justify-between gap-3"):
            `div`(className="min-w-0 flex-1"):
              p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
                text("Task Detail")
              h3(className="mt-1 text-xl font-bold text-slate-900 break-words"):
                text(item.title)
            button(
              className="rounded-lg border border-slate-300 bg-white px-2.5 py-1 text-xs font-semibold text-slate-700",
              attr("data-testid", "modal-close"),
              onClick=closeModal
            ):
              text("Close")

          # ─── Meta strip ───
          `div`(className="mt-3 flex flex-wrap items-center gap-2"):
            `div`(className="flex items-center gap-1.5"):
              span(
                className="h-2 w-2 rounded-full",
                styleProp("background-color", statusDotColor(item.status))
              )
              span(className="text-xs font-medium text-slate-600"): text(statusLabel(item.status))
            span(className="text-xs text-slate-400"): text("\xC2\xB7")
            span(className="text-xs font-medium text-slate-600"):
              text(priorityLabel(item.priority) & " priority")
            span(className="text-xs text-slate-400"): text("\xC2\xB7")
            span(className="text-xs tabular-nums text-slate-600"):
              text($item.estimateMins & " min")
            if item.focus:
              span(className="rounded-full border border-amber-200 bg-amber-50 px-2 py-0.5 text-[10px] font-bold text-amber-700"):
                text("Focus")

          # ─── Divider ───
          `div`(className="my-4 border-t border-slate-200")

          # ─── Notes ───
          p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
            text("Notes")
          textarea(
            className="mt-1.5 min-h-[120px] w-full rounded-xl border border-slate-300 bg-white px-4 py-3 text-sm text-slate-800 outline-none ring-sky-500 transition focus:border-sky-500 focus:ring-2",
            attr("data-testid", "task-notes"),
            value=item.notes,
            onInput=proc(ev: var UiEvent) =
              dispatch(TaskAction(kind: taUpdateNotes, id: item.id, text: ev.value)),
            onKeyDown=proc(ev: var UiEvent) =
              if ev.key == "Escape":
                dispatch(TaskAction(kind: taCloseModal))
          )

          # ─── Divider ───
          `div`(className="my-4 border-t border-slate-200")

          # ─── Actions ───
          `div`(className="flex flex-wrap items-center gap-2"):
            button(
              className="rounded-lg border px-3 py-1.5 text-xs font-semibold " & themeBadgeClass(theme.mode),
              styleProp("border-color", accentHex(theme.mode)),
              onClick=proc(ev: var UiEvent) =
                dispatch(TaskAction(kind: taCycleStatus, id: item.id))
            ):
              text("Advance Status")
            button(
              className="rounded-lg border border-violet-300 bg-violet-50 px-3 py-1.5 text-xs font-semibold text-violet-700",
              onClick=proc(ev: var UiEvent) =
                dispatch(TaskAction(kind: taBumpPriority, id: item.id))
            ):
              text("Bump Priority")
            button(
              className="rounded-lg border border-rose-200 bg-rose-50 px-3 py-1.5 text-xs font-semibold text-rose-700",
              onClick=proc(ev: var UiEvent) =
                dispatch(TaskAction(kind: taRemove, id: item.id))
            ):
              text("Delete Task")

proc NotFoundPage(): VNode =
  ui:
    section(className="rounded-3xl border border-rose-200 bg-rose-50 p-8 text-center text-rose-800"):
      p(className="text-5xl font-black opacity-20"): text("404")
      h2(className="mt-2 text-2xl font-black tracking-tight"): text("Page Not Found")
      p(className="mt-2 text-sm"): text("Try one of the sections in the top navigation.")

proc AppShell(): VNode =
  let theme = useContext(ThemeCtx)
  let activity = useContext(ActivityCtx)
  let network = useContext(NetworkDemoCtx)
  let info = useRoute()
  let navigate = useNavigate()
  let renderPass = useRef(0)
  let (paletteOpen, setPaletteOpen) = useState(false)
  let (crumb, setCrumb) = useState(info.path)
  renderPass.current = renderPass.current + 1

  useLayoutEffect(
    proc(): EffectCleanup =
      setCrumb(info.path)
      proc() = discard,
    deps(info.path)
  )

  useEffect(
    proc(): EffectCleanup =
      setPaletteOpen(false)
      emitActivity(activity, "Navigated to " & info.path)
      proc() = discard,
    deps(info.path)
  )

  let activePath = info.path
  let isDashboard = activePath == "/"
  let isTasks = activePath == "/tasks"
  let isFocus = activePath == "/focus"
  let isSettings = activePath == "/settings"
  let isInsights = activePath.startsWith("/insights")

  ui:
    `div`(
      className = "workspace-app space-y-6",
      styleProp("border-color", accentHex(theme.mode)),
      styleProp("--accent", accentHex(theme.mode)),
      attr("data-theme", modeValue(theme.mode)),
      attr("tabindex", "0"),
      onKeyDownCapture=proc(ev: var UiEvent) =
        if (ev.ctrlKey or ev.metaKey) and (ev.key == "k" or ev.key == "K"):
          preventDefault(ev)
          setPaletteOpen(not paletteOpen)
    ):
      # ═══ Header ═══
      header(className="rounded-3xl border border-slate-200 bg-white/95 p-6 shadow-2xl sm:p-8"):
        `div`(className="flex flex-wrap items-start justify-between gap-4"):
          `div`:
            p(className="text-[10px] font-bold uppercase tracking-[0.18em] text-slate-500"):
              text("Momentum Workspace")
            h1(
              className="mt-1 text-3xl font-black tracking-tight text-slate-900 sm:text-4xl",
              attr("data-testid", "app-title")
            ):
              text("Productivity Command Center")
            `div`(className="mt-2 flex flex-wrap items-center gap-2 text-xs text-slate-500"):
              span: text(theme.owner)
              span(className="opacity-40"): text("/")
              span(className="font-mono"): text(crumb)

          span(className="rounded-full border px-3 py-1 text-xs font-semibold " & themeBadgeClass(theme.mode)):
            text(modeValue(theme.mode))

        # ─── Navigation ───
        nav(className="mt-5 flex flex-wrap gap-2"):
          Link("/", text("Dashboard"), key="nav-dashboard")
          Link("/tasks", text("Tasks"), key="nav-tasks")
          Link("/focus", text("Focus"), key="nav-focus")
          Link("/insights/weekly?range=7d", text("Insights"), key="nav-insights")
          Link("/settings", text("Settings"), key="nav-settings")

        # ─── Active route indicator ───
        `div`(className="mt-3 flex flex-wrap gap-1.5"):
          if isDashboard:
            span(className="rounded-full bg-slate-900 px-3 py-1 text-[10px] font-bold text-white", attr("data-testid", "nav-dashboard")): text("Dashboard")
          if isTasks:
            span(className="rounded-full bg-slate-900 px-3 py-1 text-[10px] font-bold text-white", attr("data-testid", "nav-tasks")): text("Tasks")
          if isFocus:
            span(className="rounded-full bg-slate-900 px-3 py-1 text-[10px] font-bold text-white", attr("data-testid", "nav-focus")): text("Focus")
          if isInsights:
            span(className="rounded-full bg-slate-900 px-3 py-1 text-[10px] font-bold text-white", attr("data-testid", "nav-insights")): text("Insights")
          if isSettings:
            span(className="rounded-full bg-slate-900 px-3 py-1 text-[10px] font-bold text-white", attr("data-testid", "nav-settings")): text("Settings")

      # ═══ Main Content ═══
      main(className="space-y-4"):
        section(className="rounded-2xl border border-slate-200 bg-white/95 p-5 shadow-sm", attr("data-testid", "transport-panel")):
          p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
            text("Live Transport Demo")
          p(className="mt-1 text-xs text-slate-500"):
            text("HTTP fetch + WebSocket + SSE, mounted or hydrated from the workspace demo server.")
          `div`(className="mt-3 grid gap-2 sm:grid-cols-3"):
            `div`(className="rounded-xl border px-3 py-2 " & transportTone(network.fetchState)):
              p(className="text-[10px] font-bold uppercase tracking-[0.14em]"):
                text("HTTP Fetch")
              p(className="mt-1 text-xs font-semibold", attr("data-testid", "transport-fetch-state")):
                text(network.fetchState)
              p(className="mt-1 truncate text-[11px]", attr("data-testid", "transport-fetch-body")):
                text(network.fetchBody)
            `div`(className="rounded-xl border px-3 py-2 " & transportTone(network.wsState)):
              p(className="text-[10px] font-bold uppercase tracking-[0.14em]"):
                text("WebSocket")
              p(className="mt-1 text-xs font-semibold", attr("data-testid", "transport-ws-state")):
                text(network.wsState)
              p(className="mt-1 truncate text-[11px]", attr("data-testid", "transport-ws-last")):
                text(network.wsLastMessage)
            `div`(className="rounded-xl border px-3 py-2 " & transportTone(network.sseState)):
              p(className="text-[10px] font-bold uppercase tracking-[0.14em]"):
                text("SSE")
              p(className="mt-1 text-xs font-semibold", attr("data-testid", "transport-sse-state")):
                text(network.sseState)
              p(className="mt-1 truncate text-[11px]", attr("data-testid", "transport-sse-last")):
                text(network.sseLastEvent)

        Outlet()

      # ═══ Command Palette ═══
      if paletteOpen:
        section(className="rounded-2xl border border-slate-200 bg-white/95 p-5 shadow-lg", attr("data-testid", "command-palette")):
          `div`(className="flex items-center justify-between"):
            p(className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-500"):
              text("Command Palette")
            span(className="rounded border border-slate-200 bg-slate-100 px-2 py-0.5 text-[10px] font-mono font-bold text-slate-500"):
              text("Esc")
          `div`(className="mt-3 grid gap-2 sm:grid-cols-3"):
            button(
              className="rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-left text-sm font-semibold text-slate-700",
              onClick=proc(ev: var UiEvent) = navigate("/tasks")
            ):
              `div`(className="flex items-center gap-2"):
                span(className="opacity-50"): text("\xE2\x96\xA3")
                text("Tasks")
            button(
              className="rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-left text-sm font-semibold text-slate-700",
              onClick=proc(ev: var UiEvent) = navigate("/focus")
            ):
              `div`(className="flex items-center gap-2"):
                span(className="opacity-50"): text("\xE2\x97\x8E")
                text("Focus")
            button(
              className="rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-left text-sm font-semibold text-slate-700",
              onClick=proc(ev: var UiEvent) = navigate("/settings")
            ):
              `div`(className="flex items-center gap-2"):
                span(className="opacity-50"): text("\xE2\x9A\x99")
                text("Settings")

      # ═══ Footer ═══
      footer(className="rounded-2xl border border-slate-200 bg-white/90 px-5 py-3 text-xs text-slate-500"):
        `div`(className="flex flex-wrap items-center justify-between gap-2"):
          p(className="tabular-nums"):
            text("render:" & $renderPass.current & " \xC2\xB7 events:" & $activity.items.len)
          if activity.items.len > 0:
            p(className="truncate text-slate-600 max-w-xs"): text(activity.items[^1])

let WorkspaceRouter = createRouter(
  @[
    route(
      "/",
      proc(params: RouteParams): VNode =
        componentOf(AppShell, key = "shell"),
      children = @[
        route(
          "/",
          proc(params: RouteParams): VNode =
            componentOf(DashboardPage, key = "dashboard")
        ),
        route(
          "/tasks",
          proc(params: RouteParams): VNode =
            componentOf(TasksPage, key = "tasks")
        ),
        route(
          "/focus",
          proc(params: RouteParams): VNode =
            componentOf(FocusPage, key = "focus")
        ),
        route(
          "/insights/:section",
          proc(params: RouteParams): VNode =
            componentOf(InsightsPage, key = "insights")
        ),
        route(
          "/settings",
          proc(params: RouteParams): VNode =
            componentOf(SettingsPage, key = "settings")
        )
      ]
    )
  ],
  notFound = NotFoundPage
)

proc workspaceRoot*(): VNode =
  let (taskState, taskDispatch) = useReducer(taskReducer, initialTaskState())
  let (themeMode, setThemeMode) = useState(tmMint)
  let (ownerName, setOwnerName) = useState("Operator")
  let (denseMode, setDenseMode) = useState(false)
  let (activityItems, setActivityItems) = useStateFn(@["Workspace initialized"])
  let (networkDemo, setNetworkDemo) = useStateFn(
    NetworkDemoModel(
      fetchState: "idle",
      fetchBody: "-",
      wsState: "idle",
      wsLastMessage: "-",
      sseState: "idle",
      sseLastEvent: "-"
    )
  )
  let wsRef = useRef(0'i32)
  let sseRef = useRef(0'i32)

  let fingerprint = taskFingerprint(taskState.items)
  let stats = useMemo(
    proc(): TaskStats = computeStats(taskState.items),
    deps(fingerprint)
  )

  let pushActivity = useCallback(
    proc(message: string) =
      setActivityItems(
        proc(previous: seq[string]): seq[string] =
          var next = previous
          next.add(message)
          if next.len > 12:
            next = next[next.len - 12 .. ^1]
          next
      ),
    deps()
  )

  useEffect(
    proc(): EffectCleanup =
      pushActivity(
        "Stats changed: " &
        "inbox=" & $stats.inbox &
        ", doing=" & $stats.doing &
        ", focus=" & $stats.focus
      )
      proc() = discard,
    deps(stats.inbox, stats.doing, stats.focus)
  )

  useEffect(
    proc(): EffectCleanup =
      setNetworkDemo(
        proc(previous: NetworkDemoModel): NetworkDemoModel =
          var next = previous
          next.fetchState = "loading"
          next.wsState = "connecting"
          next.sseState = "connecting"
          next
      )

      discard fetch(
        "/api/workspace/summary",
        onSuccess = proc(resp: FetchResponse) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              var next = previous
              next.fetchState = $resp.status & " " & resp.statusText
              next.fetchBody = resp.body
              next
          )
          pushActivity("HTTP fetch ready (" & $resp.status & ")"),
        onError = proc(message: string) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              var next = previous
              next.fetchState = "error"
              next.fetchBody = message
              next
          )
          pushActivity("HTTP fetch failed: " & message)
      )

      wsRef.current = wsConnect(
        wsUrlForCurrentOrigin("/ws/workspace"),
        onOpen = proc() =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              var next = previous
              next.wsState = "open"
              next
          )
          if wsRef.current != 0:
            discard wsSend(wsRef.current, "workspace-client:ready")
        ,
        onMessage = proc(data: string) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              var next = previous
              next.wsState = "message"
              next.wsLastMessage = data
              next
          )
          pushActivity("WebSocket message: " & data),
        onClose = proc(code: int, reason: string, wasClean: bool) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              if previous.wsState == "message":
                return previous
              var next = previous
              next.wsState = "closed:" & $code
              if reason.len > 0:
                next.wsLastMessage = reason
              elif wasClean:
                next.wsLastMessage = "clean close"
              else:
                next.wsLastMessage = "unclean close"
              next
          ),
        onError = proc(message: string) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              if previous.wsState == "message":
                return previous
              var next = previous
              next.wsState = "error"
              next.wsLastMessage = message
              next
          )
      )

      sseRef.current = sseConnect(
        "/events/workspace",
        onMessage = proc(eventName: string, data: string, lastEventId: string) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              var next = previous
              next.sseState = "event:" & eventName
              next.sseLastEvent = data
              if lastEventId.len > 0:
                next.sseLastEvent.add(" #" & lastEventId)
              next
          )
          pushActivity("SSE event: " & eventName)
          if sseRef.current != 0:
            discard sseClose(sseRef.current)
            sseRef.current = 0
        ,
        onError = proc(message: string) =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              if previous.sseState.startsWith("event:"):
                return previous
              var next = previous
              next.sseState = "error"
              next.sseLastEvent = message
              next
          ),
        onOpen = proc() =
          setNetworkDemo(
            proc(previous: NetworkDemoModel): NetworkDemoModel =
              var next = previous
              next.sseState = "open"
              next
          )
      )

      proc() =
        if wsRef.current != 0:
          discard wsClose(wsRef.current)
          wsRef.current = 0
        if sseRef.current != 0:
          discard sseClose(sseRef.current)
          sseRef.current = 0
    ,
    deps(1)
  )

  let taskModel = TaskModel(state: taskState, dispatch: taskDispatch)
  let themeModel = ThemeModel(
    mode: themeMode,
    owner: ownerName,
    dense: denseMode,
    setMode: setThemeMode,
    setOwner: setOwnerName,
    setDense: setDenseMode
  )
  let activityModel = ActivityModel(items: activityItems, push: pushActivity)

  provider(
    ThemeCtx,
    themeModel,
    provider(
      TaskCtx,
      taskModel,
      provider(
        ActivityCtx,
        activityModel,
        provider(
          NetworkDemoCtx,
          networkDemo,
          fragment(
            RouterRoot(WorkspaceRouter),
            componentOf(TaskDetailModal, key = "task-modal")
          )
        )
      )
    )
  )

setRootComponent(workspaceRoot)
