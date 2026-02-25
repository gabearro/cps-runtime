import std/[os, strutils]
import cps/gui
import cps/gui/[ir, swift_codegen, xcodeproj_codegen]

let tmpRoot = getTempDir() / "cps_gui_swiftui_advanced_features"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let entryFile = tmpRoot / "advanced.gui"
writeFile(entryFile, """
component DetailPanel {
  VStack(spacing: 12) {
    GroupBox("Settings") {
      Toggle("Notifications", isOn: notifyEnabled)
      Toggle("Dark Mode", isOn: darkMode)
    }

    DisclosureGroup("Advanced Options") {
      Text("Option A")
      Text("Option B")
    }

    Menu("Actions") {
      Button("Duplicate", action: Duplicate)
      Button("Archive", action: Archive)
      Divider()
      Button("Delete", role: ButtonRole.destructive, action: Delete)
    }
  }
  .sheet(isPresented: showingSheet) {
    Text("Sheet Content")
  }
  .alert("Confirm Delete", isPresented: showingAlert) {
    Button("Cancel", role: ButtonRole.cancel, action: DismissAlert)
    Button("Delete", role: ButtonRole.destructive, action: ConfirmDelete)
  }
  .confirmationDialog("Choose Action", isPresented: showingDialog) {
    Button("Option 1", action: PickOption1)
    Button("Option 2", action: PickOption2)
  }
}

component SettingsPanel {
  Form {
    LabeledContent("Username", value: selectedFilter)
    LabeledContent("Status") {
      Text("Active")
        .foregroundColor(Color.green)
    }
    ProgressView("Upload", value: progress, total: 100.0)
  }
}

component Root {
  NavigationSplitView {
    List {
      Section("Smart Lists") {
        Button("All", action: SetFilterAll)
        Button("Open", action: SetFilterOpen)
      }
    }
    .listStyle(SidebarListStyle())

    VStack(alignment: HorizontalAlignment.leading, spacing: 12) {
      Picker("Filter", selection: selectedFilter) {
        Text("All")
          .tag("all")
        Text("Open")
          .tag("open")
      }
      .pickerStyle(SegmentedPickerStyle())

      List {
        ForEach(items: tasks, item: taskItem) {
          Text(taskItem.title)
        }
      }
      .searchable(text: searchQuery, placement: SearchFieldPlacement.toolbar)
      .toolbar {
        ToolbarItem(placement: ToolbarItemPlacement.primaryAction) {
          Button("Create", action: CreateTask)
            .keyboardShortcut("n", modifiers: EventModifiers.command)
        }
      }
    }
    .navigationTitle("Tasks")
  }
}

app AdvancedFeatures {
  model TodoTask {
    title: String
  }

  state {
    searchQuery: String = ""
    selectedFilter: String = "all"
    tasks: TodoTask[] = []
    notifyEnabled: Bool = true
    darkMode: Bool = false
    showingSheet: Bool = false
    showingAlert: Bool = false
    showingDialog: Bool = false
    progress: Double = 0.0
  }

  action SetFilterAll owner swift
  action SetFilterOpen owner swift
  action CreateTask owner swift
  action Duplicate owner swift
  action Archive owner swift
  action Delete owner swift
  action DismissAlert owner swift
  action ConfirmDelete owner swift
  action PickOption1 owner swift
  action PickOption2 owner swift
}
""")

let parsed = parseGuiProgram(entryFile)
let sem = semanticCheck(parsed.program)
let allDiags = parsed.diagnostics & sem.diagnostics
assert not allDiags.hasErrors

let irProgram = buildIr(sem)
let outRoot = tmpRoot / "out"
createDir(outRoot)

var generatedFiles: seq[string] = @[]
var codegenDiags: seq[GuiDiagnostic] = @[]
let scaffold = emitXcodeProject(irProgram, outRoot, generatedFiles, codegenDiags)
emitSwiftSources(irProgram, scaffold.appDir, generatedFiles, codegenDiags)
assert not codegenDiags.hasErrors

let mainSwift = readFile(scaffold.appDir / "App" / "Generated" / "GUI.generated.swift")

# Navigation and layout
assert mainSwift.contains("NavigationSplitView {")
assert mainSwift.contains("} detail: {")

# Toolbar with ToolbarItem and keyboard shortcut
assert mainSwift.contains(".toolbar {")
assert mainSwift.contains("ToolbarItem(placement: ToolbarItemPlacement.primaryAction)")
assert mainSwift.contains(".keyboardShortcut(\"n\", modifiers: EventModifiers.command)")

# Searchable with binding and named args
assert mainSwift.contains(".searchable(text: $store.state.searchQuery, placement: SearchFieldPlacement.toolbar)")

# Picker with binding and tags
assert mainSwift.contains("Picker(\"Filter\", selection: $store.state.selectedFilter)")
assert mainSwift.contains(".tag(\"all\")")
assert mainSwift.contains(".tag(\"open\")")

# GroupBox with label
assert mainSwift.contains("GroupBox(\"Settings\")")
assert mainSwift.contains("Toggle(\"Notifications\", isOn: $store.state.notifyEnabled)")
assert mainSwift.contains("Toggle(\"Dark Mode\", isOn: $store.state.darkMode)")

# DisclosureGroup
assert mainSwift.contains("DisclosureGroup(\"Advanced Options\")")

# Menu with buttons including destructive role
assert mainSwift.contains("Menu(\"Actions\")")
assert mainSwift.contains("Button(\"Duplicate\") { store.send(.duplicate) }")
assert mainSwift.contains("Button(\"Archive\") { store.send(.archive) }")
assert mainSwift.contains("role: ButtonRole.destructive")

# Sheet with isPresented binding
assert mainSwift.contains(".sheet(isPresented: $store.state.showingSheet)")

# Alert with isPresented binding (positional title first, then named args)
assert mainSwift.contains(".alert(\"Confirm Delete\", isPresented: $store.state.showingAlert)")

# ConfirmationDialog with isPresented binding
assert mainSwift.contains(".confirmationDialog(\"Choose Action\", isPresented: $store.state.showingDialog)")

# LabeledContent with value
assert mainSwift.contains("LabeledContent(\"Username\", value: store.state.selectedFilter)")

# LabeledContent with content closure
assert mainSwift.contains("LabeledContent(\"Status\") {")

# ProgressView with binding value
assert mainSwift.contains("ProgressView(\"Upload\", value: $store.state.progress, total: 100.0)")

# Form view
assert mainSwift.contains("Form {")

echo "PASS: GUI advanced SwiftUI feature codegen"
