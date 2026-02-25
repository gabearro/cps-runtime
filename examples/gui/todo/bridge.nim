## Nim bridge logic for the Todo GUI example.
##
## Payload contract:
## - 4 bytes: action tag (u32 little-endian)
## - 4 bytes: state blob length (u32 little-endian)
## - N bytes: UTF-8 JSON for GUIState snapshot

import std/[algorithm, json, os, strutils, times]

type
  TaskStatus = enum
    tsBacklog,
    tsInProgress,
    tsBlocked,
    tsDone

  TaskPriority = enum
    tpLow,
    tpMedium,
    tpHigh,
    tpUrgent

  TaskFilter = enum
    tfAll,
    tfOpen,
    tfDone,
    tfBlocked

  TaskSort = enum
    tsNewest,
    tsDueSoonest,
    tsPriority

  TodoTask = object
    id: int
    title: string
    status: TaskStatus
    priority: TaskPriority
    dueDate: string

  BridgeStateSnapshot = object
    newTaskTitle: string
    draftDueDate: string
    draftStatus: int
    draftPriority: int
    filterMode: int
    sortMode: int
    searchQuery: string
    selectedTaskId: int
    editTaskTitle: string
    editTaskDueDate: string

  GUIBridgeBuffer {.bycopy.} = object
    data: ptr uint8
    len: uint32

  GUIBridgeDispatchOutput {.bycopy.} = object
    statePatch: GUIBridgeBuffer
    effects: GUIBridgeBuffer
    emittedActions: GUIBridgeBuffer
    diagnostics: GUIBridgeBuffer

  GUIBridgeFunctionTable {.bycopy.} = object
    abiVersion: uint32
    alloc: proc(size: csize_t): pointer {.cdecl.}
    free: proc(p: pointer) {.cdecl.}
    dispatch: proc(payload: ptr uint8, payloadLen: uint32, outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}

const
  guiBridgeAbiVersion = 2'u32

  # Nim-owned action tags (must match action declaration order in app.gui).
  tagCreateTask = 0'u32
  tagClearDraftTitle = 1'u32
  tagClearSearch = 2'u32
  tagSelectTask = 3'u32
  tagRenameActiveTask = 4'u32
  tagSetActiveDueDate = 5'u32
  tagClearActiveDueDate = 6'u32
  tagSetActiveStatusBacklog = 7'u32
  tagSetActiveStatusInProgress = 8'u32
  tagSetActiveStatusBlocked = 9'u32
  tagSetActiveStatusDone = 10'u32
  tagCompleteActiveTask = 11'u32
  tagReopenActiveTask = 12'u32
  tagRemoveActiveTask = 13'u32
  tagClearCompleted = 14'u32
  tagLoadDemoData = 15'u32
  tagResetTodos = 16'u32
  tagMoveActiveTaskUp = 17'u32
  tagMoveActiveTaskDown = 18'u32
  tagSetActivePriorityLow = 19'u32
  tagSetActivePriorityMedium = 20'u32
  tagSetActivePriorityHigh = 21'u32
  tagSetActivePriorityUrgent = 22'u32
  tagFilterChanged = 23'u32
  tagSetFilterAll = 24'u32
  tagSetFilterActive = 25'u32
  tagSetFilterDone = 26'u32
  tagSetFilterBlocked = 27'u32

var
  gTasks: seq[TodoTask]
  gSelectedTaskId = -1
  gNextTaskId = 1

  gNewTaskTitle = ""
  gDraftDueDate = ""
  gDraftStatus = 0    # 0=Backlog, 1=InProgress, 2=Blocked
  gDraftPriority = 1  # 0=Low, 1=Medium, 2=High, 3=Urgent
  gFilterMode = 0     # 0=All, 1=Open, 2=Done, 3=Blocked
  gSortMode = 0       # 0=Newest, 1=DueSoonest, 2=Priority
  gSearchQuery = ""
  gEditTaskTitle = ""
  gEditTaskDueDate = ""

  gStatusText = "Ready"
  gInitialized = false

# ---- Memory helpers ----

proc bridgeAlloc(size: csize_t): pointer {.cdecl.} =
  if size <= 0:
    return nil
  allocShared(size)

proc bridgeFree(p: pointer) {.cdecl.} =
  if p != nil:
    deallocShared(p)

proc writeBlob(value: openArray[byte]): GUIBridgeBuffer =
  if value.len == 0:
    return GUIBridgeBuffer(data: nil, len: 0)
  let mem = cast[ptr uint8](bridgeAlloc(value.len.csize_t))
  if mem == nil:
    return GUIBridgeBuffer(data: nil, len: 0)
  copyMem(mem, unsafeAddr value[0], value.len)
  GUIBridgeBuffer(data: mem, len: value.len.uint32)

proc toBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  if text.len > 0:
    copyMem(addr result[0], unsafeAddr text[0], text.len)

# ---- Payload decoding ----

proc decodeLeU32(data: ptr UncheckedArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
  (uint32(data[offset + 1]) shl 8) or
  (uint32(data[offset + 2]) shl 16) or
  (uint32(data[offset + 3]) shl 24)

proc decodeActionTag(payload: ptr uint8, payloadLen: uint32): uint32 =
  if payload == nil or payloadLen < 4:
    return high(uint32)
  let bytes = cast[ptr UncheckedArray[uint8]](payload)
  decodeLeU32(bytes, 0)

proc decodeStateJson(payload: ptr uint8, payloadLen: uint32): string =
  if payload == nil or payloadLen < 8:
    return ""
  let bytes = cast[ptr UncheckedArray[uint8]](payload)
  let declaredLen = int(decodeLeU32(bytes, 4))
  if declaredLen <= 0:
    return ""
  let availableLen = int(payloadLen) - 8
  if availableLen <= 0:
    return ""
  let takeLen = min(declaredLen, availableLen)
  result = newString(takeLen)
  copyMem(addr result[0], addr bytes[8], takeLen)

proc jsonString(node: JsonNode, key: string, defaultValue: string): string =
  if node.kind != JObject or key notin node:
    return defaultValue
  let value = node[key]
  if value.kind == JString:
    return value.getStr()
  defaultValue

proc jsonInt(node: JsonNode, key: string, defaultValue: int): int =
  if node.kind != JObject or key notin node:
    return defaultValue
  let value = node[key]
  case value.kind
  of JInt:
    value.getInt()
  of JFloat:
    value.getFloat().int
  of JString:
    try:
      parseInt(value.getStr())
    except ValueError:
      defaultValue
  else:
    defaultValue

proc jsonBool(node: JsonNode, key: string, defaultValue: bool): bool =
  if node.kind != JObject or key notin node:
    return defaultValue
  let value = node[key]
  case value.kind
  of JBool:
    value.getBool()
  of JInt:
    value.getInt() != 0
  of JString:
    case value.getStr().toLowerAscii()
    of "true", "1", "yes", "on":
      true
    of "false", "0", "no", "off":
      false
    else:
      defaultValue
  else:
    defaultValue

proc decodeSnapshot(payload: ptr uint8, payloadLen: uint32): BridgeStateSnapshot =
  result = BridgeStateSnapshot(
    newTaskTitle: "",
    draftDueDate: "",
    draftStatus: 0,
    draftPriority: 1,
    filterMode: 0,
    sortMode: 0,
    searchQuery: "",
    selectedTaskId: -1,
    editTaskTitle: "",
    editTaskDueDate: ""
  )

  let stateJson = decodeStateJson(payload, payloadLen)
  if stateJson.len == 0:
    return

  try:
    let node = parseJson(stateJson)
    result.newTaskTitle = jsonString(node, "newTaskTitle", "")
    result.draftDueDate = jsonString(node, "draftDueDate", "")
    result.draftStatus = jsonInt(node, "draftStatus", 0)
    result.draftPriority = jsonInt(node, "draftPriority", 1)
    result.filterMode = jsonInt(node, "filterMode", 0)
    result.sortMode = jsonInt(node, "sortMode", 0)
    result.searchQuery = jsonString(node, "searchQuery", "")
    result.selectedTaskId = jsonInt(node, "selectedTaskId", -1)
    result.editTaskTitle = jsonString(node, "editTaskTitle", "")
    result.editTaskDueDate = jsonString(node, "editTaskDueDate", "")
  except CatchableError:
    discard

# ---- Task status/priority helpers ----

proc statusText(status: TaskStatus): string =
  case status
  of tsBacklog: "Backlog"
  of tsInProgress: "In Progress"
  of tsBlocked: "Blocked"
  of tsDone: "Done"

proc statusFromInt(v: int): TaskStatus =
  case v
  of 1: tsInProgress
  of 2: tsBlocked
  else: tsBacklog

proc priorityText(priority: TaskPriority): string =
  case priority
  of tpLow: "Low"
  of tpMedium: "Medium"
  of tpHigh: "High"
  of tpUrgent: "Urgent"

proc priorityFromInt(v: int): TaskPriority =
  case v
  of 0: tpLow
  of 2: tpHigh
  of 3: tpUrgent
  else: tpMedium

proc statusFromText(value: string): TaskStatus =
  case value.toLowerAscii().strip()
  of "backlog": tsBacklog
  of "in progress", "in_progress", "inprogress": tsInProgress
  of "blocked": tsBlocked
  of "done": tsDone
  else: tsBacklog

proc priorityFromText(value: string): TaskPriority =
  case value.toLowerAscii().strip()
  of "low": tpLow
  of "high": tpHigh
  of "urgent": tpUrgent
  else: tpMedium

proc filterFromInt(v: int): TaskFilter =
  case v
  of 1: tfOpen
  of 2: tfDone
  of 3: tfBlocked
  else: tfAll

proc sortFromInt(v: int): TaskSort =
  case v
  of 1: tsDueSoonest
  of 2: tsPriority
  else: tsNewest

# ---- Task query helpers ----

proc findTaskIndexById(taskId: int): int =
  if taskId < 0:
    return -1
  for i in 0 ..< gTasks.len:
    if gTasks[i].id == taskId:
      return i
  -1

proc activeTaskIndex(): int =
  findTaskIndexById(gSelectedTaskId)

proc syncEditorFromActive() =
  let idx = activeTaskIndex()
  if idx >= 0:
    gEditTaskTitle = gTasks[idx].title
    gEditTaskDueDate = gTasks[idx].dueDate
  else:
    gEditTaskTitle = ""
    gEditTaskDueDate = ""

proc normalizeSelection() =
  if gTasks.len == 0:
    gSelectedTaskId = -1
    syncEditorFromActive()
    return
  if findTaskIndexById(gSelectedTaskId) >= 0:
    syncEditorFromActive()
    return
  gSelectedTaskId = gTasks[0].id
  syncEditorFromActive()

# ---- Counting helpers ----

proc visibleCount(): int =
  gTasks.len

proc doneCount(): int =
  for task in gTasks:
    if task.status == tsDone:
      inc result

proc blockedCount(): int =
  for task in gTasks:
    if task.status == tsBlocked:
      inc result

proc openCount(): int =
  for task in gTasks:
    if task.status != tsDone:
      inc result

# ---- Date helpers ----

proc parseDueDate(value: string, normalized: var string, key: var int): bool =
  let trimmed = value.strip()
  if trimmed.len == 0:
    normalized = ""
    key = high(int)
    return true
  try:
    let dt = parse(trimmed, "yyyy-MM-dd")
    normalized = dt.format("yyyy-MM-dd")
    key = dt.year * 10000 + ord(dt.month) * 100 + dt.monthday
    true
  except TimeParseError:
    false

proc todayDateKey(): int =
  let dt = now()
  dt.year * 10000 + ord(dt.month) * 100 + dt.monthday

proc dueKeyForTask(task: TodoTask): int =
  var normalized = ""
  var dueKey = high(int)
  if parseDueDate(task.dueDate, normalized, dueKey):
    dueKey
  else:
    high(int)

proc isTaskOverdue(task: TodoTask): bool =
  if task.status == tsDone:
    return false
  let dueKey = dueKeyForTask(task)
  if dueKey == high(int):
    return false
  dueKey < todayDateKey()

proc dueDateLabel(task: TodoTask): string =
  var normalized = ""
  var dueKey = high(int)
  if not parseDueDate(task.dueDate, normalized, dueKey):
    return "No due date"
  if normalized.len == 0:
    return "No due date"
  if task.status != tsDone and dueKey < todayDateKey():
    return normalized & " (overdue)"
  normalized

proc priorityRank(priority: TaskPriority): int =
  case priority
  of tpUrgent: 4
  of tpHigh: 3
  of tpMedium: 2
  of tpLow: 1

# ---- Filter/sort ----

proc matchesFilter(task: TodoTask): bool =
  let f = filterFromInt(gFilterMode)
  case f
  of tfAll:
    true
  of tfOpen:
    task.status != tsDone
  of tfDone:
    task.status == tsDone
  of tfBlocked:
    task.status == tsBlocked

proc matchesSearch(task: TodoTask): bool =
  let query = gSearchQuery.strip().toLowerAscii()
  if query.len == 0:
    return true
  task.title.toLowerAscii().contains(query)

proc sortTasks(tasks: var seq[TodoTask]) =
  let s = sortFromInt(gSortMode)
  case s
  of tsNewest:
    sort(tasks, proc(a, b: TodoTask): int = cmp(b.id, a.id))
  of tsDueSoonest:
    sort(tasks, proc(a, b: TodoTask): int =
      let dueCmp = cmp(dueKeyForTask(a), dueKeyForTask(b))
      if dueCmp != 0:
        return dueCmp
      let priorityCmp = cmp(priorityRank(b.priority), priorityRank(a.priority))
      if priorityCmp != 0:
        return priorityCmp
      cmp(a.id, b.id)
    )
  of tsPriority:
    sort(tasks, proc(a, b: TodoTask): int =
      let priorityCmp = cmp(priorityRank(b.priority), priorityRank(a.priority))
      if priorityCmp != 0:
        return priorityCmp
      let dueCmp = cmp(dueKeyForTask(a), dueKeyForTask(b))
      if dueCmp != 0:
        return dueCmp
      cmp(a.id, b.id)
    )

# ---- CRUD ----

proc addTask(title: string, status: TaskStatus, priority: TaskPriority, dueDate: string) =
  gTasks.add TodoTask(
    id: gNextTaskId,
    title: title,
    status: status,
    priority: priority,
    dueDate: dueDate
  )
  gSelectedTaskId = gNextTaskId
  inc gNextTaskId
  syncEditorFromActive()

proc resetModel() =
  gTasks.setLen(0)
  gSelectedTaskId = -1
  gNextTaskId = 1
  gDraftStatus = 0
  gDraftPriority = 1
  gFilterMode = 0
  gSortMode = 0
  gNewTaskTitle = ""
  gDraftDueDate = ""
  gSearchQuery = ""
  gEditTaskTitle = ""
  gEditTaskDueDate = ""
  gStatusText = "Ready"

proc addDemoTasks() =
  resetModel()
  addTask("Set up CI pipeline for release builds", tsInProgress, tpHigh, "2030-02-01")
  addTask("Write integration tests for bridge protocol", tsBacklog, tpUrgent, "2030-01-28")
  addTask("Review and merge PR #47 (auth flow)", tsBlocked, tpMedium, "")
  addTask("Update README with new API docs", tsDone, tpLow, "2030-01-15")
  addTask("Implement dark mode support", tsBacklog, tpMedium, "2030-03-01")
  addTask("Fix memory leak in connection pool", tsInProgress, tpHigh, "2030-01-25")
  addTask("Benchmark serialization performance", tsBacklog, tpLow, "")
  if gTasks.len > 0:
    gSelectedTaskId = gTasks[0].id
  normalizeSelection()
  gStatusText = "Loaded demo board with " & $gTasks.len & " tasks"

proc selectedTaskTitle(): string =
  let idx = activeTaskIndex()
  if idx >= 0:
    gTasks[idx].title
  else:
    "No task selected"

proc selectedTaskStatusText(): string =
  let idx = activeTaskIndex()
  if idx >= 0:
    statusText(gTasks[idx].status) & " / " & priorityText(gTasks[idx].priority)
  else:
    ""

# ---- Persistence ----

proc persistencePath(): string =
  getHomeDir() / ".cpsimpl_nim_todo_state_v3.json"

proc savePersistedState() =
  var root = newJObject()
  root["selectedTaskId"] = %gSelectedTaskId
  root["nextTaskId"] = %gNextTaskId
  root["draftStatus"] = %gDraftStatus
  root["draftPriority"] = %gDraftPriority
  root["filterMode"] = %gFilterMode
  root["sortMode"] = %gSortMode
  root["newTaskTitle"] = %gNewTaskTitle
  root["draftDueDate"] = %gDraftDueDate
  root["searchQuery"] = %gSearchQuery
  root["editTaskTitle"] = %gEditTaskTitle
  root["editTaskDueDate"] = %gEditTaskDueDate

  var tasks = newJArray()
  for task in gTasks:
    var node = newJObject()
    node["id"] = %task.id
    node["title"] = %task.title
    node["status"] = %statusText(task.status)
    node["priority"] = %priorityText(task.priority)
    node["dueDate"] = %task.dueDate
    tasks.add node
  root["tasks"] = tasks

  try:
    writeFile(persistencePath(), $root)
  except CatchableError:
    discard

proc loadPersistedState() =
  let path = persistencePath()
  if not fileExists(path):
    return

  try:
    let parsed = parseJson(readFile(path))
    if parsed.kind != JObject:
      return

    gSelectedTaskId = jsonInt(parsed, "selectedTaskId", -1)
    gNextTaskId = max(1, jsonInt(parsed, "nextTaskId", 1))
    gDraftStatus = jsonInt(parsed, "draftStatus", 0)
    gDraftPriority = jsonInt(parsed, "draftPriority", 1)
    gFilterMode = jsonInt(parsed, "filterMode", 0)
    gSortMode = jsonInt(parsed, "sortMode", 0)
    gNewTaskTitle = jsonString(parsed, "newTaskTitle", "")
    gDraftDueDate = jsonString(parsed, "draftDueDate", "")
    gSearchQuery = jsonString(parsed, "searchQuery", "")
    gEditTaskTitle = jsonString(parsed, "editTaskTitle", "")
    gEditTaskDueDate = jsonString(parsed, "editTaskDueDate", "")

    gTasks.setLen(0)
    if "tasks" in parsed and parsed["tasks"].kind == JArray:
      for item in parsed["tasks"].items:
        if item.kind != JObject:
          continue
        let title = jsonString(item, "title", "").strip()
        if title.len == 0:
          continue
        let task = TodoTask(
          id: max(1, jsonInt(item, "id", gNextTaskId)),
          title: title,
          status: statusFromText(jsonString(item, "status", "Backlog")),
          priority: priorityFromText(jsonString(item, "priority", "Medium")),
          dueDate: jsonString(item, "dueDate", "")
        )
        gTasks.add task

    if gTasks.len > 0:
      var maxId = 0
      for task in gTasks:
        maxId = max(maxId, task.id)
      gNextTaskId = max(gNextTaskId, maxId + 1)

    normalizeSelection()
  except CatchableError:
    discard

# ---- Init ----

proc ensureInit() =
  if not gInitialized:
    resetModel()
    loadPersistedState()
    normalizeSelection()
    gInitialized = true

# ---- Action names ----

proc actionName(tag: uint32): string =
  case tag
  of tagCreateTask: "CreateTask"
  of tagClearDraftTitle: "ClearDraftTitle"
  of tagClearSearch: "ClearSearch"
  of tagSelectTask: "SelectTask"
  of tagRenameActiveTask: "RenameActiveTask"
  of tagSetActiveDueDate: "SetActiveDueDate"
  of tagClearActiveDueDate: "ClearActiveDueDate"
  of tagSetActiveStatusBacklog: "SetActiveStatusBacklog"
  of tagSetActiveStatusInProgress: "SetActiveStatusInProgress"
  of tagSetActiveStatusBlocked: "SetActiveStatusBlocked"
  of tagSetActiveStatusDone: "SetActiveStatusDone"
  of tagCompleteActiveTask: "CompleteActiveTask"
  of tagReopenActiveTask: "ReopenActiveTask"
  of tagRemoveActiveTask: "RemoveActiveTask"
  of tagClearCompleted: "ClearCompleted"
  of tagLoadDemoData: "LoadDemoData"
  of tagResetTodos: "ResetTodos"
  of tagMoveActiveTaskUp: "MoveActiveTaskUp"
  of tagMoveActiveTaskDown: "MoveActiveTaskDown"
  of tagSetActivePriorityLow: "SetActivePriorityLow"
  of tagSetActivePriorityMedium: "SetActivePriorityMedium"
  of tagSetActivePriorityHigh: "SetActivePriorityHigh"
  of tagSetActivePriorityUrgent: "SetActivePriorityUrgent"
  of tagFilterChanged: "FilterChanged"
  of tagSetFilterAll: "SetFilterAll"
  of tagSetFilterActive: "SetFilterActive"
  of tagSetFilterDone: "SetFilterDone"
  of tagSetFilterBlocked: "SetFilterBlocked"
  else: "Unknown"

# ---- State patch builder ----

proc buildPatch(): seq[byte] =
  var patch = newJObject()

  normalizeSelection()

  # Sync draft controls from snapshot values
  let filter = filterFromInt(gFilterMode)
  let sort = sortFromInt(gSortMode)

  patch["todoCount"] = %visibleCount()
  patch["openCount"] = %openCount()
  patch["doneCount"] = %doneCount()
  patch["blockedCount"] = %blockedCount()

  patch["newTaskTitle"] = %gNewTaskTitle
  patch["draftDueDate"] = %gDraftDueDate
  patch["draftStatus"] = %gDraftStatus
  patch["draftPriority"] = %gDraftPriority

  patch["filterMode"] = %gFilterMode
  patch["sortMode"] = %gSortMode

  patch["searchQuery"] = %gSearchQuery

  patch["selectedTaskId"] = %gSelectedTaskId
  patch["selectedTaskTitle"] = %selectedTaskTitle()
  patch["selectedTaskStatusText"] = %selectedTaskStatusText()
  patch["editTaskTitle"] = %gEditTaskTitle
  patch["editTaskDueDate"] = %gEditTaskDueDate

  var visibleTasks: seq[TodoTask] = @[]
  for task in gTasks:
    if matchesFilter(task) and matchesSearch(task):
      visibleTasks.add task
  sortTasks(visibleTasks)

  var tasksNode = newJArray()
  for task in visibleTasks:
    var taskNode = newJObject()
    taskNode["id"] = %task.id
    taskNode["title"] = %task.title
    taskNode["statusText"] = %statusText(task.status)
    taskNode["priorityText"] = %priorityText(task.priority)
    taskNode["dueDateText"] = %dueDateLabel(task)
    taskNode["done"] = %(task.status == tsDone)
    taskNode["blocked"] = %(task.status == tsBlocked)
    taskNode["active"] = %(task.id == gSelectedTaskId)
    taskNode["overdue"] = %isTaskOverdue(task)
    taskNode["priorityUrgent"] = %(task.priority == tpUrgent)
    taskNode["priorityHigh"] = %(task.priority == tpHigh)
    tasksNode.add taskNode

  patch["tasks"] = tasksNode
  patch["status"] = %gStatusText

  toBytes($patch)

# ---- Dispatch ----

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32, outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} =
  ensureInit()

  let actionTag = decodeActionTag(payload, payloadLen)
  let snapshot = decodeSnapshot(payload, payloadLen)

  # Sync GUI-owned state from the snapshot
  gNewTaskTitle = snapshot.newTaskTitle
  gDraftDueDate = snapshot.draftDueDate
  gDraftStatus = snapshot.draftStatus
  gDraftPriority = snapshot.draftPriority
  gFilterMode = snapshot.filterMode
  gSortMode = snapshot.sortMode
  gSearchQuery = snapshot.searchQuery
  gEditTaskTitle = snapshot.editTaskTitle
  gEditTaskDueDate = snapshot.editTaskDueDate

  if snapshot.selectedTaskId >= 0 and findTaskIndexById(snapshot.selectedTaskId) >= 0:
    gSelectedTaskId = snapshot.selectedTaskId

  case actionTag
  of tagCreateTask:
    var title = gNewTaskTitle.strip()
    if title.len == 0:
      title = "Untitled task"
    var normalizedDue = ""
    var dueKey = high(int)
    if not parseDueDate(gDraftDueDate, normalizedDue, dueKey):
      gStatusText = "Invalid due date format (use YYYY-MM-DD)"
    else:
      let status = statusFromInt(gDraftStatus)
      let priority = priorityFromInt(gDraftPriority)
      addTask(title, status, priority, normalizedDue)
      gStatusText = "Created: " & title
      gNewTaskTitle = ""
      gDraftDueDate = ""

  of tagClearDraftTitle:
    gNewTaskTitle = ""
    gDraftDueDate = ""
    gStatusText = "Draft cleared"

  of tagClearSearch:
    gSearchQuery = ""
    gStatusText = "Search cleared"

  of tagSelectTask:
    if snapshot.selectedTaskId >= 0 and findTaskIndexById(snapshot.selectedTaskId) >= 0:
      gSelectedTaskId = snapshot.selectedTaskId
      syncEditorFromActive()
      gStatusText = "Selected: " & selectedTaskTitle()
    else:
      gStatusText = "Task not found"

  of tagRenameActiveTask:
    let idx = activeTaskIndex()
    if idx < 0:
      gStatusText = "No task selected"
    else:
      let newTitle = gEditTaskTitle.strip()
      if newTitle.len == 0:
        gStatusText = "Title cannot be empty"
      else:
        gTasks[idx].title = newTitle
        syncEditorFromActive()
        gStatusText = "Renamed to: " & newTitle

  of tagSetActiveDueDate:
    let idx = activeTaskIndex()
    if idx < 0:
      gStatusText = "No task selected"
    else:
      var normalizedDue = ""
      var dueKey = high(int)
      if not parseDueDate(gEditTaskDueDate, normalizedDue, dueKey):
        gStatusText = "Invalid date format (use YYYY-MM-DD)"
      else:
        gTasks[idx].dueDate = normalizedDue
        syncEditorFromActive()
        if normalizedDue.len == 0:
          gStatusText = "Due date cleared"
        else:
          gStatusText = "Due date set to " & normalizedDue

  of tagClearActiveDueDate:
    let idx = activeTaskIndex()
    if idx < 0:
      gStatusText = "No task selected"
    else:
      gTasks[idx].dueDate = ""
      syncEditorFromActive()
      gStatusText = "Due date cleared"

  of tagSetActiveStatusBacklog:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].status = tsBacklog
      gStatusText = selectedTaskTitle() & " -> Backlog"
    else:
      gStatusText = "No task selected"

  of tagSetActiveStatusInProgress:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].status = tsInProgress
      gStatusText = selectedTaskTitle() & " -> In Progress"
    else:
      gStatusText = "No task selected"

  of tagSetActiveStatusBlocked:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].status = tsBlocked
      gStatusText = selectedTaskTitle() & " -> Blocked"
    else:
      gStatusText = "No task selected"

  of tagSetActiveStatusDone:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].status = tsDone
      gStatusText = selectedTaskTitle() & " -> Done"
    else:
      gStatusText = "No task selected"

  of tagCompleteActiveTask:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].status = tsDone
      gStatusText = "Completed: " & gTasks[idx].title
    else:
      gStatusText = "No task selected"

  of tagReopenActiveTask:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].status = tsInProgress
      gStatusText = "Reopened: " & gTasks[idx].title
    else:
      gStatusText = "No task selected"

  of tagRemoveActiveTask:
    let idx = activeTaskIndex()
    if idx >= 0:
      let title = gTasks[idx].title
      gTasks.delete(idx)
      normalizeSelection()
      gStatusText = "Removed: " & title
    else:
      gStatusText = "No task selected"

  of tagClearCompleted:
    var removed = 0
    if gTasks.len > 0:
      for i in countdown(gTasks.len - 1, 0):
        if gTasks[i].status == tsDone:
          gTasks.delete(i)
          inc removed
    normalizeSelection()
    if removed > 0:
      gStatusText = "Cleared " & $removed & " completed task(s)"
    else:
      gStatusText = "No completed tasks to clear"

  of tagLoadDemoData:
    addDemoTasks()

  of tagResetTodos:
    resetModel()
    gStatusText = "Board reset"

  of tagMoveActiveTaskUp:
    let idx = activeTaskIndex()
    if idx < 0:
      gStatusText = "No task selected"
    elif idx == 0:
      gStatusText = "Already at top"
    else:
      let movedId = gTasks[idx].id
      swap(gTasks[idx], gTasks[idx - 1])
      gSelectedTaskId = movedId
      syncEditorFromActive()
      gStatusText = "Moved up"

  of tagMoveActiveTaskDown:
    let idx = activeTaskIndex()
    if idx < 0:
      gStatusText = "No task selected"
    elif idx >= gTasks.len - 1:
      gStatusText = "Already at bottom"
    else:
      let movedId = gTasks[idx].id
      swap(gTasks[idx], gTasks[idx + 1])
      gSelectedTaskId = movedId
      syncEditorFromActive()
      gStatusText = "Moved down"

  of tagSetActivePriorityLow:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].priority = tpLow
      gStatusText = selectedTaskTitle() & " -> Low priority"
    else:
      gStatusText = "No task selected"

  of tagSetActivePriorityMedium:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].priority = tpMedium
      gStatusText = selectedTaskTitle() & " -> Medium priority"
    else:
      gStatusText = "No task selected"

  of tagSetActivePriorityHigh:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].priority = tpHigh
      gStatusText = selectedTaskTitle() & " -> High priority"
    else:
      gStatusText = "No task selected"

  of tagSetActivePriorityUrgent:
    let idx = activeTaskIndex()
    if idx >= 0:
      gTasks[idx].priority = tpUrgent
      gStatusText = selectedTaskTitle() & " -> Urgent priority"
    else:
      gStatusText = "No task selected"

  of tagFilterChanged:
    # Just re-filters with current search/filter/sort state
    discard

  of tagSetFilterAll:
    gFilterMode = 0
    gStatusText = "Showing all tasks"

  of tagSetFilterActive:
    gFilterMode = 1
    gStatusText = "Showing active tasks"

  of tagSetFilterDone:
    gFilterMode = 2
    gStatusText = "Showing completed tasks"

  of tagSetFilterBlocked:
    gFilterMode = 3
    gStatusText = "Showing blocked tasks"

  else:
    gStatusText = "Unknown action (" & $actionTag & ")"

  normalizeSelection()
  savePersistedState()

  let patchBlob = buildPatch()
  let diagBlob = toBytes(
    "nim.todo action=" & actionName(actionTag) &
    " tasks=" & $visibleCount() &
    " open=" & $openCount() &
    " done=" & $doneCount()
  )

  if outp != nil:
    outp[].statePatch = writeBlob(patchBlob)
    outp[].effects = writeBlob(@[])
    outp[].emittedActions = writeBlob(@[])
    outp[].diagnostics = writeBlob(diagBlob)

  0'i32

var gBridgeTable = GUIBridgeFunctionTable(
  abiVersion: guiBridgeAbiVersion,
  alloc: bridgeAlloc,
  free: bridgeFree,
  dispatch: bridgeDispatch
)

proc gui_bridge_get_table(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} =
  addr gBridgeTable
