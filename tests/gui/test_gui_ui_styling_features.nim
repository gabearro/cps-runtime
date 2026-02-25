import std/[os, strutils]
import cps/gui
import cps/gui/[ir, swift_codegen, xcodeproj_codegen]

let entry = "examples/gui/todo/app.gui"
let parsed = parseGuiProgram(entry)
let sem = semanticCheck(parsed.program)
let diags = parsed.diagnostics & sem.diagnostics
assert not diags.hasErrors

let irProgram = buildIr(sem)
let outRoot = getTempDir() / "cps_gui_todo_styling"
if dirExists(outRoot):
  removeDir(outRoot)
createDir(outRoot)

var generatedFiles: seq[string] = @[]
var codegenDiags: seq[GuiDiagnostic] = @[]
let scaffold = emitXcodeProject(irProgram, outRoot, generatedFiles, codegenDiags)
emitSwiftSources(irProgram, scaffold.appDir, generatedFiles, codegenDiags)
assert not codegenDiags.hasErrors

let mainSwift = readFile(scaffold.appDir / "App" / "Generated" / "GUI.generated.swift")

# Root component is TodoApp with NavigationSplitView
assert mainSwift.contains("Component_TodoApp(store: store)")
assert mainSwift.contains("NavigationSplitView {")
assert mainSwift.contains(".navigationSplitViewStyle(BalancedNavigationSplitViewStyle())")
assert mainSwift.contains("@Environment(\\.colorScheme) var colorScheme")
assert mainSwift.contains("let isDark")
assert mainSwift.contains("ColorScheme.dark")
assert not mainSwift.contains(".preferredColorScheme(")

# Sidebar width constraints
assert mainSwift.contains("minWidth: 220")
assert mainSwift.contains("maxWidth: 300")

# New Task input in sidebar
assert mainSwift.contains("TextField(\"New task...\", text: $store.state.newTaskTitle)")
assert mainSwift.contains(".onSubmit { store.send(.createTask) }")

# No stat cards or draft pickers
assert not mainSwift.contains("Component_StatCard")
assert not mainSwift.contains("Picker(\"Status\", selection: $store.state.draftStatus)")

# FilterRow components for sidebar navigation
assert mainSwift.contains("Component_FilterRow(store: store")
assert mainSwift.contains("label: \"All Tasks\"")
assert mainSwift.contains("label: \"Active\"")
assert mainSwift.contains("label: \"Completed\"")
assert mainSwift.contains("label: \"Blocked\"")

# Filter row icons
assert mainSwift.contains("icon: \"tray.full\"")
assert mainSwift.contains("icon: \"circle\"")
assert mainSwift.contains("icon: \"checkmark.circle\"")
assert mainSwift.contains("icon: \"exclamationmark.triangle\"")

# Filter actions via onTap
assert mainSwift.contains("store.send(.setFilterAll)")
assert mainSwift.contains("store.send(.setFilterActive)")
assert mainSwift.contains("store.send(.setFilterDone)")
assert mainSwift.contains("store.send(.setFilterBlocked)")

# Sort picker in sidebar
assert mainSwift.contains("Picker(\"Sort\", selection: $store.state.sortMode)")
assert mainSwift.contains(".pickerStyle(SegmentedPickerStyle())")

# Workspace actions
assert mainSwift.contains("Button(\"Load Demo\") { store.send(.loadDemoData) }")
assert mainSwift.contains("Button(\"Clear Done\") { store.send(.clearCompleted) }")
assert mainSwift.contains("Button(\"Reset\") { store.send(.resetTodos) }")

# Search bar with onChange for real-time filtering
assert mainSwift.contains("Image(systemName: \"magnifyingglass\")")
assert mainSwift.contains("TextField(\"Search tasks...\", text: $store.state.searchQuery)")
assert mainSwift.contains(".onChange(of: store.state.searchQuery)")

# Conditional Clear search button
assert mainSwift.contains("store.state.searchQuery != \"\"")

# Conditional TaskEditor
assert mainSwift.contains("store.state.selectedTaskId >= 0")

# Empty state with ContentUnavailableView
assert mainSwift.contains("store.state.todoCount == 0")
assert mainSwift.contains("ContentUnavailableView(\"No tasks yet\"")

# Task editor: labeled sections
assert mainSwift.contains("Button(\"Save\") { store.send(.renameActiveTask) }")
assert mainSwift.contains("Button(\"Set\") { store.send(.setActiveDueDate) }")
assert mainSwift.contains("Text(\"Title\")")
assert mainSwift.contains("Text(\"Due Date\")")
assert mainSwift.contains("Text(\"Status\")")
assert mainSwift.contains("Text(\"Priority\")")

# Status buttons
assert mainSwift.contains("Button(\"Backlog\") { store.send(.setActiveStatusBacklog) }")
assert mainSwift.contains("Button(\"In Progress\") { store.send(.setActiveStatusInProgress) }")
assert mainSwift.contains("Button(\"Done\") { store.send(.setActiveStatusDone) }")

# Priority buttons
assert mainSwift.contains("Button(\"Low\") { store.send(.setActivePriorityLow) }")
assert mainSwift.contains("Button(\"High\") { store.send(.setActivePriorityHigh) }")
assert mainSwift.contains("Button(\"Urgent\") { store.send(.setActivePriorityUrgent) }")

# Delete button
assert mainSwift.contains("Button(\"Delete Task\") { store.send(.removeActiveTask) }")

# Editor shadow
assert mainSwift.contains(".shadow(")

# ForEach task list with tap gesture
assert mainSwift.contains("ForEach(Array(store.state.tasks.indices), id: \\.self)")
assert mainSwift.contains("Component_TodoRow(store: store, task: task, isDark: isDark)")
assert mainSwift.contains(".onTapGesture { store.send(.selectTask(taskId: task.id)) }")
assert mainSwift.contains(".listRowBackground(Color.clear)")

# PlainListStyle
assert mainSwift.contains(".listStyle(PlainListStyle())")

# contentShape for tappable rows
assert mainSwift.contains(".contentShape(Rectangle())")

# Window configuration
assert mainSwift.contains("WindowGroup(\"Nim Tasks\")")
assert mainSwift.contains("applicationShouldTerminateAfterLastWindowClosed")

# Design tokens
assert mainSwift.contains("GUITokens.color_accent")
assert mainSwift.contains("GUITokens.color_surface")
assert mainSwift.contains("GUITokens.color_border")

# Semantic fonts
assert mainSwift.contains(".font(.body)")
assert mainSwift.contains(".font(.caption)")
assert mainSwift.contains(".font(.caption2)")
assert mainSwift.contains(".font(.headline)")
assert mainSwift.contains(".font(.title3)")

# Ternary expressions
assert mainSwift.contains("(task.done) ? (0.55) : (1.0)")
assert mainSwift.contains("(task.done) ? (\"checkmark.circle.fill\")")

# controlSize
assert mainSwift.contains(".controlSize(.small)")

# Named padding → EdgeInsets codegen
assert mainSwift.contains(".padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))")

# Detail panel background tint
assert mainSwift.contains("let pageBackgroundColor")
assert mainSwift.contains("Color(red: 0.06, green: 0.08, blue: 0.12)")
assert mainSwift.contains(".background(pageBackgroundColor)")

# Reducer handles filter actions
assert mainSwift.contains("case .setFilterAll:")
assert mainSwift.contains("case .setFilterActive:")
assert mainSwift.contains("case .setFilterDone:")
assert mainSwift.contains("case .setFilterBlocked:")

echo "PASS: GUI UI styling feature codegen"
