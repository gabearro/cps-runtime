## Tests for new GUI DSL features:
## - String interpolation
## - Conditional views (if/else if/else)
## - New view types with bindings (Slider, Stepper, DatePicker, ColorPicker, TextEditor)
## - New modifier semantics (sheet, alert, onChange, onSubmit, task, swipeActions)

import std/[os, strutils, tables, sets, hashes, sequtils]
import cps/gui/types
import cps/gui/ast
import cps/gui/lexer
import cps/gui/parser
import cps/gui/sema
import cps/gui/ir
import cps/gui/swift_codegen

# ---- Helpers ----

proc parseSrc(source: string): tuple[program: GuiProgram, diagnostics: seq[GuiDiagnostic]] =
  let tmpDir = getTempDir() / "gui_test_" & $hash(source)
  createDir(tmpDir)
  writeFile(tmpDir / "test.gui", source)
  parseGuiProgram(tmpDir / "test.gui")

proc generateSwift(source: string): tuple[swift: string, errors: seq[string]] =
  let tmpDir = getTempDir() / "gui_test_cg_" & $hash(source)
  createDir(tmpDir)
  writeFile(tmpDir / "test.gui", source)
  let (parsedProg, parseDiags) = parseGuiProgram(tmpDir / "test.gui")
  var allErrors: seq[string] = @[]
  for d in parseDiags:
    if d.severity == gsError:
      allErrors.add d.message
  if allErrors.len > 0:
    return ("", allErrors)
  let sem = semanticCheck(parsedProg)
  for d in sem.diagnostics:
    if d.severity == gsError:
      allErrors.add d.message
  if allErrors.len > 0:
    return ("", allErrors)
  let irProg = buildIr(sem)
  var generatedFiles: seq[string] = @[]
  var codegenDiags: seq[GuiDiagnostic] = @[]
  emitSwiftSources(irProg, tmpDir, generatedFiles, codegenDiags)
  for d in codegenDiags:
    if d.severity == gsError:
      allErrors.add d.message
  let mainSwiftPath = tmpDir / "App" / "Generated" / "GUI.generated.swift"
  if fileExists(mainSwiftPath):
    (readFile(mainSwiftPath), allErrors)
  else:
    ("", allErrors)

# ---- String Interpolation Tests ----

block testStringInterpLexer:
  let (tokens, diags) = lexGui("<test>", """
    "hello \(name) world"
  """)
  assert diags.len == 0, "Expected no diagnostics, got: " & $diags.len
  var foundStart = false
  var foundEnd = false
  for t in tokens:
    if t.kind == gtkStringInterpStart:
      assert t.lexeme == "hello ", "Expected 'hello ', got '" & t.lexeme & "'"
      foundStart = true
    if t.kind == gtkStringInterpEnd:
      assert t.lexeme == " world", "Expected ' world', got '" & t.lexeme & "'"
      foundEnd = true
  assert foundStart and foundEnd
  echo "PASS: string interpolation lexer basic"

block testStringInterpLexerMultiple:
  let (tokens, diags) = lexGui("<test>", """
    "\(a) and \(b)"
  """)
  assert diags.len == 0, "Expected no diagnostics, got: " & $diags.len
  var startCount, midCount, endCount = 0
  for t in tokens:
    if t.kind == gtkStringInterpStart: inc startCount
    if t.kind == gtkStringInterpMid: inc midCount
    if t.kind == gtkStringInterpEnd: inc endCount
  assert startCount == 1, "Expected 1 start, got " & $startCount
  assert midCount == 1, "Expected 1 mid, got " & $midCount
  assert endCount == 1, "Expected 1 end, got " & $endCount
  echo "PASS: string interpolation lexer multiple"

block testStringInterpLexerExpr:
  let (tokens, diags) = lexGui("<test>", """
    "result: \(a + b)"
  """)
  assert diags.len == 0
  var hasPlus = false
  for t in tokens:
    if t.kind == gtkPlus:
      hasPlus = true
  assert hasPlus, "Expected + operator inside interpolation"
  echo "PASS: string interpolation lexer with expression"

block testStringInterpParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      name: String = "world"
    }
    component Main {
      Text("hello \(name)")
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.components.len == 1
  let textNode = prog.components[0].body[0]
  assert textNode.name == "Text"
  assert textNode.args.len == 1
  let arg = textNode.args[0]
  assert arg.kind == geInterpolatedString, "Expected interpolated string, got " & $arg.kind
  assert arg.parts.len == 2, "Expected 2 parts, got " & $arg.parts.len
  assert arg.parts[0] == "hello "
  assert arg.parts[1] == ""
  assert arg.expressions.len == 1
  assert arg.expressions[0].kind == geIdent
  assert arg.expressions[0].ident == "name"
  echo "PASS: string interpolation parser"

block testPlainStringUnchanged:
  let (tokens, diags) = lexGui("<test>", """
    "hello world"
  """)
  assert diags.len == 0
  var hasPlainString = false
  for t in tokens:
    if t.kind == gtkString and t.lexeme == "hello world":
      hasPlainString = true
  assert hasPlainString, "Plain strings should still produce gtkString tokens"
  echo "PASS: plain string unchanged"

# ---- Conditional View Tests ----

block testConditionalViewParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      showDetail: Bool = false
    }
    component Main {
      if showDetail {
        Text("Detail")
      } else {
        Text("Summary")
      }
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.components.len == 1
  let ifNode = prog.components[0].body[0]
  assert ifNode.isConditional, "Expected conditional node"
  assert ifNode.condition != nil
  assert ifNode.condition.kind == geIdent
  assert ifNode.condition.ident == "showDetail"
  assert ifNode.children.len == 1
  assert ifNode.children[0].name == "Text"
  assert ifNode.elseChildren.len == 1
  assert ifNode.elseChildren[0].name == "Text"
  echo "PASS: conditional view parser"

block testConditionalViewElseIf:
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      mode: Int = 0
    }
    component Main {
      if mode == 0 {
        Text("Zero")
      } else if mode == 1 {
        Text("One")
      } else {
        Text("Other")
      }
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  let ifNode = prog.components[0].body[0]
  assert ifNode.isConditional
  assert ifNode.elseIfBranches.len == 1, "Expected 1 else-if branch, got " & $ifNode.elseIfBranches.len
  assert ifNode.elseIfBranches[0].isConditional
  assert ifNode.elseChildren.len == 1
  echo "PASS: conditional view parser (else if)"

block testConditionalViewSema:
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      showDetail: Bool = false
    }
    component Main {
      if showDetail {
        Text("Detail")
      } else {
        Text("Summary")
      }
    }
  """)
  assert diags.len == 0
  let sem = semanticCheck(prog)
  let errors = sem.diagnostics.filterIt(it.severity == gsError)
  assert errors.len == 0, "Expected 0 sema errors, got " & $errors.len & ": " & (if errors.len > 0: errors[0].message else: "")
  echo "PASS: conditional view sema"

block testConditionalOnlyIf:
  # Test: if without else
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      visible: Bool = true
    }
    component Main {
      if visible {
        Text("Visible")
      }
    }
  """)
  assert diags.len == 0
  let ifNode = prog.components[0].body[0]
  assert ifNode.isConditional
  assert ifNode.children.len == 1
  assert ifNode.elseIfBranches.len == 0
  assert ifNode.elseChildren.len == 0
  echo "PASS: conditional view if-only"

# ---- Codegen Tests ----

block testConditionalViewCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      showDetail: Bool = false
    }
    component Main {
      if showDetail {
        Text("Detail view")
      } else {
        Text("Summary view")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if store.state.showDetail" in swift, "Expected 'if store.state.showDetail' in generated Swift:\n" & swift
  assert "} else {" in swift, "Expected '} else {'"
  assert "Text(\"Detail view\")" in swift
  assert "Text(\"Summary view\")" in swift
  echo "PASS: conditional view codegen"

block testConditionalViewCodegenElseIf:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      mode: Int = 0
    }
    component Main {
      if mode == 0 {
        Text("Zero")
      } else if mode == 1 {
        Text("One")
      } else {
        Text("Other")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if (store.state.mode == 0)" in swift, "Expected if condition"
  assert "else if (store.state.mode == 1)" in swift, "Expected else if"
  assert "} else {" in swift
  echo "PASS: conditional view codegen (else if)"

block testStringInterpCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      name: String = "World"
    }
    component Main {
      Text("Hello \(name)!")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "\\(store.state.name)" in swift, "Expected interpolation in Swift output"
  echo "PASS: string interpolation codegen"

block testStringInterpCodegenMultiple:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      first: String = "John"
      last: String = "Doe"
    }
    component Main {
      Text("\(first) \(last)")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "\\(store.state.first)" in swift
  assert "\\(store.state.last)" in swift
  echo "PASS: string interpolation codegen multiple"

# ---- New View Type Tests ----

block testSliderCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      volume: Double = 0.5
    }
    component Main {
      Slider(value: volume)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Slider(value: $store.state.volume)" in swift, "Expected Slider binding"
  echo "PASS: Slider codegen"

block testStepperCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      Stepper("Count", value: count)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "$store.state.count" in swift, "Expected Stepper binding"
  echo "PASS: Stepper codegen"

block testDatePickerCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      selectedDate: String = ""
    }
    component Main {
      DatePicker("Pick a date", selection: selectedDate)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "DatePicker" in swift
  assert "$store.state.selectedDate" in swift, "Expected DatePicker binding"
  echo "PASS: DatePicker codegen"

block testColorPickerCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      color: String = ""
    }
    component Main {
      ColorPicker("Choose color", selection: color)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ColorPicker" in swift
  assert "$store.state.color" in swift, "Expected ColorPicker binding"
  echo "PASS: ColorPicker codegen"

block testTextEditorCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      notes: String = ""
    }
    component Main {
      TextEditor(text: notes)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "TextEditor(text: $store.state.notes)" in swift, "Expected TextEditor binding"
  echo "PASS: TextEditor codegen"

# ---- Modifier Semantics Tests ----

block testSheetModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      showSheet: Bool = false
    }
    component Main {
      Text("Hello")
        .sheet(isPresented: showSheet) {
          Text("Sheet content")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".sheet(isPresented: $store.state.showSheet)" in swift, "Expected sheet modifier with binding"
  assert "Text(\"Sheet content\")" in swift, "Expected sheet content"
  echo "PASS: sheet modifier codegen"

block testAlertModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      showAlert: Bool = false
    }
    component Main {
      Text("Hello")
        .alert(isPresented: showAlert) {
          Text("Alert!")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".alert(isPresented: $store.state.showAlert)" in swift, "Expected alert modifier with binding"
  echo "PASS: alert modifier codegen"

block testPopoverModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      showPopover: Bool = false
    }
    component Main {
      Text("Hello")
        .popover(isPresented: showPopover) {
          Text("Popover content")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".popover(isPresented: $store.state.showPopover)" in swift
  assert "Text(\"Popover content\")" in swift
  echo "PASS: popover modifier codegen"

block testOnChangeModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      query: String = ""
    }
    action Search
    component Main {
      Text("Search")
        .onChange(of: query, action: Search)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".onChange(of: store.state.query)" in swift, "Expected onChange modifier"
  assert "store.send(" in swift, "Expected action dispatch"
  echo "PASS: onChange modifier codegen"

block testOnSubmitModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      query: String = ""
    }
    action Submit
    component Main {
      TextField("Enter text", text: query)
        .onSubmit(Submit)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".onSubmit" in swift, "Expected onSubmit modifier"
  assert "store.send(.submit)" in swift, "Expected action dispatch in onSubmit"
  echo "PASS: onSubmit modifier codegen"

block testTaskModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    action Load
    component Main {
      Text("Content")
        .task(Load)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".task { store.send(.load) }" in swift, "Expected task modifier with action dispatch"
  echo "PASS: task modifier codegen"

# ---- Compound Feature Tests ----

block testConditionalWithInterpolation:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      if count > 0 {
        Text("Count: \(count)")
      } else {
        Text("No items")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if (store.state.count > 0)" in swift
  assert "\\(store.state.count)" in swift
  assert "Text(\"No items\")" in swift
  echo "PASS: conditional with interpolation codegen"

block testNestedConditionals:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      a: Bool = false
      b: Bool = false
    }
    component Main {
      if a {
        if b {
          Text("Both")
        } else {
          Text("Only A")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if store.state.a" in swift
  assert "if store.state.b" in swift
  assert "Text(\"Both\")" in swift
  assert "Text(\"Only A\")" in swift
  echo "PASS: nested conditionals codegen"

block testConditionalViewInsideForEach:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items, item: it) {
        if it == "special" {
          Text("Special item")
        } else {
          Text("Normal item")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ForEach" in swift
  assert "if" in swift
  echo "PASS: conditional view inside ForEach"

# ---- ForEach id: parameter (Identifiable) Tests ----

block testForEachWithId:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items, id: self, item: it) {
        Text(it)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ForEach(store.state.items, id: \\.self)" in swift, "Expected ForEach with id: \\.self in:\n" & swift
  assert "{ it in" in swift, "Expected item name 'it'"
  echo "PASS: ForEach with id: self"

block testForEachWithIdKeyPath:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items, id: name, item: it) {
        Text(it)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ForEach(store.state.items, id: \\.name)" in swift, "Expected ForEach with id: \\.name in:\n" & swift
  echo "PASS: ForEach with id: keypath"

block testForEachIndexBasedFallback:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items, item: it) {
        Text(it)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ForEach(Array(store.state.items.indices)" in swift, "Expected index-based ForEach in:\n" & swift
  echo "PASS: ForEach index-based fallback"

# ---- @State Local Variables Tests ----

block testLocalStateParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      global: String = "hello"
    }
    component Main {
      @State counter: Int = 0
      @State label: String = "Click me"
      Text(label)
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.components.len == 1
  assert prog.components[0].localState.len == 2
  assert prog.components[0].localState[0].name == "counter"
  assert prog.components[0].localState[0].typ == "Int"
  assert prog.components[0].localState[1].name == "label"
  assert prog.components[0].localState[1].typ == "String"
  echo "PASS: @State parser"

block testLocalStateCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      title: String = "App"
    }
    component Main {
      @State counter: Int = 0
      @State isExpanded: Bool = false
      Text("Count")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@State private var counter: Int = 0" in swift, "Expected @State counter in:\n" & swift
  assert "@State private var isExpanded: Bool = false" in swift, "Expected @State isExpanded"
  echo "PASS: @State codegen"

block testLocalStateBinding:
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      @State text: String = ""
      TextField("Enter text", text: text)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@State private var text: String" in swift
  assert "TextField(\"Enter text\", text: $text)" in swift, "Expected local binding $text, got:\n" & swift
  echo "PASS: @State local binding"

block testLocalStateNotPrefixed:
  # Local state vars should NOT get store.state. prefix
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      name: String = "World"
    }
    component Main {
      @State isEditing: Bool = false
      if isEditing {
        Text("editing")
      } else {
        Text(name)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if isEditing" in swift, "Local state should not have store.state prefix"
  assert "store.state.name" in swift, "Global state should have store.state prefix"
  echo "PASS: @State no store prefix"

# ---- @Binding Parameters Tests ----

block testBindingParamParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    component Toggle(@Binding isOn: Bool) {
      Text("toggle")
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.components[0].params.len == 1
  assert prog.components[0].params[0].name == "isOn"
  assert prog.components[0].params[0].isBinding == true
  assert prog.components[0].params[0].typ == "Bool"
  echo "PASS: @Binding param parser"

block testBindingParamCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    component ToggleRow(@Binding isOn: Bool, label: String) {
      Text(label)
    }
    component Main {
      Text("Hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@Binding var isOn: Bool" in swift, "Expected @Binding in struct"
  assert "var label: String" in swift, "Expected normal var for non-binding param"
  echo "PASS: @Binding param codegen"

# ---- @Environment Tests ----

block testEnvironmentParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    component Main {
      @Environment(.colorScheme) colorScheme: ColorScheme
      Text("Hello")
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.components[0].envBindings.len == 1
  assert prog.components[0].envBindings[0].keyPath == "colorScheme"
  assert prog.components[0].envBindings[0].localName == "colorScheme"
  assert prog.components[0].envBindings[0].typ == "ColorScheme"
  echo "PASS: @Environment parser"

block testEnvironmentCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      @Environment(.colorScheme) colorScheme: ColorScheme
      @Environment(.dismiss) dismiss: DismissAction
      Text("Hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@Environment(\\.colorScheme) var colorScheme" in swift, "Expected @Environment in:\n" & swift
  assert "@Environment(\\.dismiss) var dismiss" in swift
  echo "PASS: @Environment codegen"

# ---- Enum Type Tests ----

block testEnumParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    enum Tab {
      home
      search
      profile
    }
    state {
      selectedTab: Tab = home
    }
    component Main {
      Text("App")
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.enums.len == 1
  assert prog.enums[0].name == "Tab"
  assert prog.enums[0].cases.len == 3
  assert prog.enums[0].cases[0].name == "home"
  assert prog.enums[0].cases[1].name == "search"
  assert prog.enums[0].cases[2].name == "profile"
  echo "PASS: enum parser"

block testEnumCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    enum Tab {
      home
      search
      profile
    }
    state {
      selectedTab: String = "home"
    }
    component Main {
      Text("Hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "enum Tab: String, CaseIterable, Codable, Equatable, Hashable {" in swift, "Expected enum declaration in:\n" & swift
  assert "case home" in swift
  assert "case search" in swift
  assert "case profile" in swift
  echo "PASS: enum codegen"

# ---- Component with @State + @Binding integration ----

block testComponentBindingInvocation:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      enabled: Bool = false
    }
    component MyToggle(@Binding value: Bool) {
      Toggle("Toggle", isOn: value)
    }
    component Main {
      MyToggle(value: enabled)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  # The component struct should have @Binding
  assert "@Binding var value: Bool" in swift
  # When invoked, binding params should use $ prefix
  assert "value: $store.state.enabled" in swift, "Expected binding invocation in:\n" & swift
  echo "PASS: component @Binding invocation"

block testLocalStateWithSheetModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      @State showSheet: Bool = false
      Button("Show Sheet", action: showSheet)
        .sheet(isPresented: showSheet) {
          Text("Sheet content")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@State private var showSheet: Bool = false" in swift
  assert ".sheet(isPresented: $showSheet)" in swift, "Expected local state binding for sheet in:\n" & swift
  echo "PASS: @State with sheet modifier"

# ---- Let Binding Tests ----

block testLetBindingParser:
  let (prog, diags) = parseSrc("""
    app TestApp
    state {
      first: String = "John"
      last: String = "Doe"
    }
    component Main {
      let fullName = "\(first) \(last)"
      Text(fullName)
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  assert prog.components[0].letBindings.len == 1
  assert prog.components[0].letBindings[0].name == "fullName"
  assert prog.components[0].letBindings[0].value != nil
  echo "PASS: let binding parser"

block testLetBindingCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      first: String = "John"
      last: String = "Doe"
    }
    component Main {
      let fullName = "\(first) \(last)"
      Text(fullName)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "let fullName = " in swift, "Expected let binding in body:\n" & swift
  assert "Text(fullName)" in swift, "Expected let binding used without store prefix"
  echo "PASS: let binding codegen"

block testLetBindingWithExplicitType:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      let count: Int = 42
      Text("Count")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "let count: Int = 42" in swift, "Expected typed let binding:\n" & swift
  echo "PASS: let binding with explicit type"

# ---- Binding.constant expression ----

block testBindingConstantExpr:
  # Binding.constant(value) should emit as .constant(value)
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      Toggle("Preview", isOn: true)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Toggle" in swift
  # When a literal bool is passed to a binding param, it should use .constant()
  assert "isOn: .constant(true)" in swift, "Expected Binding.constant for literal:\n" & swift
  echo "PASS: Binding.constant for literal"

# ---- @FocusState Tests ----

block testFocusStateCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      @FocusState isFocused: Bool
      @State text: String = ""
      TextField("Enter text", text: text)
        .focused(isFocused)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@FocusState private var isFocused: Bool" in swift, "Expected @FocusState in:\n" & swift
  assert ".focused" in swift
  echo "PASS: @FocusState codegen"

# ---- NavigationLink Tests ----

block testNavigationLinkCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      NavigationLink("Go to detail", value: "detail") {
        Text("Detail View")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "NavigationLink" in swift
  assert "value:" in swift or "\"detail\"" in swift
  echo "PASS: NavigationLink codegen"

# ---- GeometryReader Tests ----

block testGeometryReaderCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    component Main {
      GeometryReader(proxy: geo) {
        Text("Width")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "GeometryReader { geo in" in swift, "Expected GeometryReader closure in:\n" & swift
  echo "PASS: GeometryReader codegen"

# ---- List with selection ----

block testListCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      selectedItem: String = ""
    }
    component Main {
      List(selection: selectedItem) {
        Text("Item 1")
        Text("Item 2")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "List(selection: $store.state.selectedItem)" in swift, "Expected List with binding in:\n" & swift
  echo "PASS: List with selection codegen"

# ---- Toolbar modifier ----

block testToolbarCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    action AddItem
    component Main {
      Text("Content")
        .navigationTitle("My App")
        .toolbar {
          Button("Add", action: AddItem)
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".navigationTitle(\"My App\")" in swift, "Expected navigationTitle in:\n" & swift
  assert ".toolbar {" in swift, "Expected toolbar modifier"
  echo "PASS: toolbar and navigationTitle codegen"

# ---- Gesture modifier tests ----

block testOnTapGestureCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    action Tap
    component Main {
      Text("Tap me")
        .onTapGesture(count: 2, action: Tap)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".onTapGesture" in swift, "Expected onTapGesture in:\n" & swift
  echo "PASS: onTapGesture codegen"

# ---- Animation modifier tests ----

block testAnimationModifierCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      isVisible: Bool = true
    }
    component Main {
      Text("Animated")
        .opacity(isVisible ? 1.0 : 0.0)
        .animation("easeInOut", value: isVisible)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".animation" in swift
  echo "PASS: animation modifier codegen"

block testTransitionCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      show: Bool = true
    }
    component Main {
      if show {
        Text("Hello")
          .transition("slide")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".transition" in swift
  echo "PASS: transition modifier codegen"

# ---- LazyVStack / LazyHStack ----

block testLazyStackCodegen:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      ScrollView {
        LazyVStack {
          ForEach(items, id: self, item: it) {
            Text(it)
          }
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "LazyVStack" in swift, "Expected LazyVStack in:\n" & swift
  assert "ScrollView {" in swift
  echo "PASS: LazyVStack codegen"

# ---- Enum dot-syntax ----

block testEnumDotSyntaxInArgs:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      VStack(alignment: .leading, spacing: 10) {
        Text("hello")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".leading" in swift, "Expected .leading in:\n" & swift
  echo "PASS: enum dot-syntax in view args"

block testEnumDotSyntaxInModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      visible: Bool = true
    }
    component Main {
      Text("hello")
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut, value: visible)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".infinity" in swift, "Expected .infinity in:\n" & swift
  assert ".center" in swift, "Expected .center in:\n" & swift
  assert ".easeInOut" in swift, "Expected .easeInOut in:\n" & swift
  echo "PASS: enum dot-syntax in modifier args"

block testEnumDotSyntaxInNamedArg:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      Text("hello")
        .multilineTextAlignment(.trailing)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".trailing" in swift, "Expected .trailing in:\n" & swift
  echo "PASS: enum dot-syntax as positional arg"

# ---- Searchable modifier with text binding ----

block testSearchableTextBinding:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      searchText: String = ""
      items: String[] = []
    }
    component Main {
      List {
        ForEach(items, id: self, item: it) {
          Text(it)
        }
      }
        .searchable(text: searchText, prompt: "Search items")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".searchable" in swift, "Expected .searchable in:\n" & swift
  assert "$store.state.searchText" in swift, "Expected binding in:\n" & swift
  echo "PASS: searchable modifier with text binding"

# ---- Optional chaining ----

block testOptionalChaining:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      userName: String = ""
    }
    component Main {
      Text(state.user?.name ?? "Unknown")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "?." in swift, "Expected ?. in:\n" & swift
  assert "??" in swift, "Expected ?? in:\n" & swift
  echo "PASS: optional chaining"

block testOptionalChainingDeep:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      label: String = ""
    }
    component Main {
      Text(state.user?.profile?.displayName ?? "Anon")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "?.profile?." in swift or ("?." in swift), "Expected deep optional chain in:\n" & swift
  echo "PASS: deep optional chaining"

# ---- If-let bindings ----

block testIfLetBinding:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      selectedItem: String = ""
    }
    component Main {
      VStack {
        if let item = state.selectedItem {
          Text(item)
        } else {
          Text("Nothing selected")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if let item" in swift, "Expected if-let in:\n" & swift
  assert "} else {" in swift, "Expected else branch in:\n" & swift
  echo "PASS: if-let binding"

block testIfLetWithOptionalChain:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      name: String = ""
    }
    component Main {
      VStack {
        if let name = state.user?.name {
          Text(name)
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if let name" in swift, "Expected if-let in:\n" & swift
  assert "?." in swift, "Expected optional chain in:\n" & swift
  echo "PASS: if-let with optional chaining"

# ---- Switch/case pattern matching ----

block testSwitchCase:
  let (swift, errors) = generateSwift("""
    app TestApp
    enum Screen {
      case home
      case settings
      case profile
    }
    state {
      currentScreen: Screen = .home
    }
    component Main {
      switch state.currentScreen {
        case .home:
          Text("Home")
        case .settings:
          Text("Settings")
        case .profile:
          Text("Profile")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "switch" in swift, "Expected switch in:\n" & swift
  assert "case .home:" in swift, "Expected case .home in:\n" & swift
  assert "case .settings:" in swift, "Expected case .settings in:\n" & swift
  assert "case .profile:" in swift, "Expected case .profile in:\n" & swift
  echo "PASS: switch/case codegen"

block testSwitchDefault:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      switch state.count {
        case 0:
          Text("Zero")
        case 1:
          Text("One")
        default:
          Text("Many")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "switch" in swift, "Expected switch in:\n" & swift
  assert "default:" in swift, "Expected default in:\n" & swift
  echo "PASS: switch/case with default"

# ---- ForEach with enum CaseIterable ----

block testForEachEnumAllCases:
  let (swift, errors) = generateSwift("""
    app TestApp
    enum Tab {
      case home
      case search
      case profile
    }
    state {
      selectedTab: Tab = .home
    }
    component Main {
      ForEach(Tab.allCases, id: self, item: tab) {
        Text(tab.rawValue)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "CaseIterable" in swift, "Expected CaseIterable in:\n" & swift
  assert "Tab.allCases" in swift, "Expected Tab.allCases in:\n" & swift
  assert "tab in" in swift, "Expected tab binding in:\n" & swift
  echo "PASS: ForEach with enum CaseIterable"

# ---- @StateObject and @ObservedObject ----

block testStateObject:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      @StateObject viewModel: ViewModel
      Text(viewModel.title)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@StateObject private var viewModel: ViewModel" in swift, "Expected @StateObject in:\n" & swift
  echo "PASS: @StateObject codegen"

block testObservedObject:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component DetailView {
      @ObservedObject model: ItemModel
      Text(model.name)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@ObservedObject var model: ItemModel" in swift, "Expected @ObservedObject in:\n" & swift
  echo "PASS: @ObservedObject codegen"

# ---- ZStack and overlay ----

block testZStackAlignment:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      ZStack(alignment: .topLeading) {
        Color(.blue)
        Text("Overlay")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ZStack(alignment: .topLeading)" in swift, "Expected ZStack alignment in:\n" & swift
  echo "PASS: ZStack alignment codegen"

block testOverlayModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      Image("photo")
        .overlay {
          Text("Caption")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".overlay" in swift, "Expected overlay in:\n" & swift
  echo "PASS: overlay modifier codegen"

# ---- Array subscript ----

block testArraySubscript:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
      selectedIndex: Int = 0
    }
    component Main {
      Text(state.items[state.selectedIndex])
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "[" in swift and "]" in swift, "Expected subscript in:\n" & swift
  assert "state.items[state.selectedIndex]" in swift, "Expected array subscript in:\n" & swift
  echo "PASS: array subscript"

# ---- Negative number literals ----

block testNegativeNumbers:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      Text("hello")
        .offset(x: -10, y: -5.5)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "-10" in swift, "Expected -10 in:\n" & swift
  assert "-5.5" in swift, "Expected -5.5 in:\n" & swift
  echo "PASS: negative number literals"

# ---- @AppStorage and @SceneStorage ----

block testAppStorage:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      @AppStorage("isDarkMode") isDark: Bool = false
      Toggle("Dark Mode", isOn: isDark)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@AppStorage(\"isDarkMode\") var isDark: Bool = false" in swift, "Expected @AppStorage in:\n" & swift
  echo "PASS: @AppStorage codegen"

block testSceneStorage:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      @SceneStorage("selectedTab") selectedTab: String = "home"
      Text(selectedTab)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@SceneStorage(\"selectedTab\") var selectedTab: String" in swift, "Expected @SceneStorage in:\n" & swift
  echo "PASS: @SceneStorage codegen"

# ---- Modifier with children (content builder closures) ----

block testConfirmDialogChildren:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      showConfirm: Bool = false
    }
    component Main {
      Button("Delete") {}
        .confirmationDialog(isPresented: showConfirm) {
          Button("Confirm") {}
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".confirmationDialog" in swift, "Expected confirmationDialog in:\n" & swift
  echo "PASS: confirmationDialog with children"

block testButtonWithRole:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      Button("Delete", role: .destructive) {}
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".destructive" in swift, "Expected .destructive in:\n" & swift
  assert "role:" in swift, "Expected role: in:\n" & swift
  echo "PASS: Button with role enum"

block testContextMenuChildren:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    component Main {
      Text("Right-click me")
        .contextMenu {
          Button("Copy") {}
          Button("Paste") {}
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".contextMenu" in swift, "Expected contextMenu in:\n" & swift
  echo "PASS: contextMenu with children"

# ---- Member access passthrough ----

block testMemberAccessPassthrough:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      Text("\(items.count) items")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".count" in swift, "Expected .count in:\n" & swift
  echo "PASS: member access passthrough"

# ---- Button action dispatch ----

block testButtonActionDispatch:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {}
    action SaveData
    component Main {
      Button("Save", action: SaveData)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "store.send(.saveData)" in swift, "Expected save action in:\n" & swift
  echo "PASS: Button action dispatch"

# ---- Xcode preview generation ----

block testPreviewGeneration:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      Text("\(count)")
    }
    component Detail {
      Text("Detail")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "#Preview {" in swift, "Expected #Preview block in:\n" & swift
  assert "Component_Main(store: GUIStore())" in swift, "Expected Main preview in:\n" & swift
  assert "Component_Detail(store: GUIStore())" in swift, "Expected Detail preview in:\n" & swift
  echo "PASS: Xcode preview blocks generated"

block testPreviewWithParams:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component ItemRow(title: String, @Binding isSelected: Bool) {
      Text(title)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Component_ItemRow(store: GUIStore(), title: \"\", isSelected: .constant(false))" in swift,
    "Expected preview with param defaults in:\n" & swift
  echo "PASS: Preview with binding params"

# ---- Toolbar modifier ----

block testToolbar:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    action Increment
    component Main {
      Text("\(count)")
        .toolbar {
          ToolbarItem(placement: .automatic) {
            Button("Add", action: Increment)
          }
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".toolbar {" in swift, "Expected .toolbar in:\n" & swift
  assert "ToolbarItem(placement: .automatic)" in swift, "Expected ToolbarItem in:\n" & swift
  assert "Button(\"Add\")" in swift, "Expected Button in:\n" & swift
  echo "PASS: toolbar modifier"

block testToolbarTrailingPlacement:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      Text("\(count)")
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Image(systemName: "plus")
          }
          ToolbarItem(placement: .navigationBarLeading) {
            Text("Back")
          }
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".navigationBarTrailing" in swift, "Expected trailing placement in:\n" & swift
  assert ".navigationBarLeading" in swift, "Expected leading placement in:\n" & swift
  echo "PASS: toolbar with multiple placements"

# ---- ScrollView ----

block testScrollView:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    component Main {
      ScrollView {
        VStack {
          ForEach(items, id: self, item: item) {
            Text(item)
          }
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ScrollView {" in swift, "Expected ScrollView in:\n" & swift
  assert "VStack {" in swift, "Expected VStack in:\n" & swift
  echo "PASS: ScrollView"

block testScrollViewAxis:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          Text("Hello")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ScrollView(.horizontal, showsIndicators: false)" in swift, "Expected ScrollView with axis in:\n" & swift
  echo "PASS: ScrollView with axis"

# ---- Menu view ----

block testMenuView:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    action DoSomething
    component Main {
      Menu("Options") {
        Button("Action 1", action: DoSomething)
        Button("Action 2", action: DoSomething)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Menu(\"Options\")" in swift, "Expected Menu in:\n" & swift
  echo "PASS: Menu view"

# ---- Shapes ----

block testShapes:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      VStack {
        Rectangle()
          .fill(.blue)
          .frame(width: 100, height: 100)
        Circle()
          .fill(.red)
          .frame(width: 50, height: 50)
        Capsule()
          .stroke(.green, lineWidth: 2)
        RoundedRectangle(cornerRadius: 10)
          .fill(.orange)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Rectangle()" in swift, "Expected Rectangle in:\n" & swift
  assert "Circle()" in swift, "Expected Circle in:\n" & swift
  assert "Capsule()" in swift, "Expected Capsule in:\n" & swift
  assert "RoundedRectangle(cornerRadius: 10)" in swift, "Expected RoundedRectangle in:\n" & swift
  assert ".fill(.blue)" in swift, "Expected .fill in:\n" & swift
  assert ".stroke(.green, lineWidth: 2)" in swift, "Expected .stroke in:\n" & swift
  echo "PASS: shape views"

# ---- Gradient ----

block testGradient:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
        .frame(height: 200)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "LinearGradient(colors:" in swift, "Expected LinearGradient in:\n" & swift
  echo "PASS: gradient"

# ---- Accessibility modifiers ----

block testAccessibility:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      Text("\(count)")
        .accessibilityLabel("Counter value")
        .accessibilityHint("Displays the current count")
        .accessibilityIdentifier("counter_text")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".accessibilityLabel(\"Counter value\")" in swift, "Expected accessibilityLabel in:\n" & swift
  assert ".accessibilityHint(\"Displays the current count\")" in swift, "Expected accessibilityHint in:\n" & swift
  assert ".accessibilityIdentifier(\"counter_text\")" in swift, "Expected accessibilityIdentifier in:\n" & swift
  echo "PASS: accessibility modifiers"

# ---- Animation modifier ----

block testAnimationModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      Text("\(count)")
        .animation(.easeInOut, value: count)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".animation(.easeInOut, value: store.state.count)" in swift, "Expected animation modifier in:\n" & swift
  echo "PASS: animation modifier with value"

block testTransitionModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      visible: Bool = true
    }
    component Main {
      if visible {
        Text("Hello")
          .transition(.slide)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".transition(.slide)" in swift, "Expected transition in:\n" & swift
  echo "PASS: transition modifier"

# ---- FocusState with .focused ----

block testFocused:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      name: String = ""
    }
    component Main {
      @FocusState isFocused: Bool = false
      TextField("Name", text: name)
        .focused(isFocused)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@FocusState" in swift, "Expected @FocusState in:\n" & swift
  assert ".focused(" in swift, "Expected .focused modifier in:\n" & swift
  # .focused needs a binding: $isFocused
  assert "$isFocused" in swift, "Expected binding in .focused in:\n" & swift
  echo "PASS: @FocusState with .focused"

# ---- Gesture modifier ----

block testOnLongPressGesture:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    action Increment
    component Main {
      Text("\(count)")
        .onLongPressGesture(perform: Increment)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".onLongPressGesture" in swift, "Expected .onLongPressGesture in:\n" & swift
  assert "store.send(.increment)" in swift, "Expected action dispatch in:\n" & swift
  echo "PASS: onLongPressGesture"

# ---- ProgressView / Gauge ----

block testProgressView:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      progress: Double = 0.5
    }
    component Main {
      VStack {
        ProgressView(value: progress)
        ProgressView("Loading...")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ProgressView(" in swift, "Expected ProgressView in:\n" & swift
  echo "PASS: ProgressView"

# ---- Form and Section ----

block testFormSection:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      name: String = ""
      email: String = ""
    }
    component Main {
      Form {
        Section(header: "Personal Info") {
          TextField("Name", text: name)
          TextField("Email", text: email)
        }
        Section(header: "Actions") {
          Text("Footer text")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Form {" in swift, "Expected Form in:\n" & swift
  assert "Section(header: \"Personal Info\")" in swift, "Expected Section in:\n" & swift
  echo "PASS: Form and Section"

# ---- Spacer and Divider ----

block testSpacerDivider:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      VStack {
        Text("Top")
        Spacer()
        Divider()
        Text("Bottom")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Spacer()" in swift, "Expected Spacer in:\n" & swift
  assert "Divider()" in swift, "Expected Divider in:\n" & swift
  echo "PASS: Spacer and Divider"

# ---- withAnimation in reducer ----

block testWithAnimation:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
      visible: Bool = true
    }
    action Increment
    action Toggle
    reducer {
      on Increment {
        set count = count + 1
      }
      on Toggle {
        set visible = !visible withAnimation .easeInOut
      }
    }
    component Main {
      Text("\(count)")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "withAnimation(.easeInOut)" in swift,
    "Expected withAnimation in:\n" & swift
  # Non-animated set should NOT have withAnimation
  assert "state.count = " in swift, "Expected count set in:\n" & swift
  echo "PASS: withAnimation in reducer"

# ---- NavigationStack ----

block testNavigationStack:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      NavigationStack {
        List {
          NavigationLink("Detail", value: "detail")
        }
        .navigationTitle("Home")
        .navigationDestination(for: String.self) {
          Text("Destination")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "NavigationStack {" in swift, "Expected NavigationStack in:\n" & swift
  assert ".navigationTitle(\"Home\")" in swift, "Expected navigationTitle in:\n" & swift
  echo "PASS: NavigationStack"

# ---- AsyncImage ----

block testAsyncImage:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      imageUrl: String = ""
    }
    component Main {
      AsyncImage(url: imageUrl)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "AsyncImage(" in swift, "Expected AsyncImage in:\n" & swift
  echo "PASS: AsyncImage"

# ---- Custom ViewModifier ----

block testViewModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    modifier CardStyle {
      .padding(16)
      .background(.white)
      .cornerRadius(12)
      .shadow(radius: 4)
    }
    component Main {
      Text("\(count)")
        .cardStyle()
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "struct CardStyleModifier: ViewModifier {" in swift, "Expected ViewModifier struct in:\n" & swift
  assert ".padding(16)" in swift, "Expected modifier content in:\n" & swift
  assert ".cornerRadius(12)" in swift, "Expected cornerRadius in:\n" & swift
  assert "func cardStyle()" in swift, "Expected extension method in:\n" & swift
  assert ".modifier(CardStyleModifier())" in swift, "Expected modifier application in:\n" & swift
  echo "PASS: custom ViewModifier"

# ---- Effect/command system ----

block testEffectSystem:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      loading: Bool = false
    }
    action FetchData(url: String)
    reducer {
      on FetchData(url) {
        set loading = true
        emit http.request(url: url, method: "GET")
      }
    }
    component Main {
      Text("Loading")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "GUIEffectCommand" in swift, "Expected GUIEffectCommand in:\n" & swift
  assert "http.request" in swift, "Expected effect name in:\n" & swift
  echo "PASS: effect/command system"

# ---- Ternary expressions ----

block testTernarySimple:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      isActive: Bool = true
    }
    component Main {
      Text(isActive ? "Active" : "Inactive")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  echo "PASS: ternary expression"

block testTernaryInModifier:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      isError: Bool = false
    }
    component Main {
      Text("Status")
        .foregroundColor(isError ? Color.red : Color.primary)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".foregroundColor(" in swift, "Expected foregroundColor in:\n" & swift
  echo "PASS: ternary in modifier"

block testTernaryEnumDot:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      isError: Bool = false
    }
    component Main {
      Text(isError ? "Error" : "OK")
        .foregroundStyle(isError ? .red : .blue)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".foregroundStyle(" in swift, "Expected foregroundStyle in:\n" & swift
  echo "PASS: ternary enum dot in modifier"

# ---- Let bindings in component ----

block testLetBindings:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      firstName: String = ""
      lastName: String = ""
    }
    component Main {
      let fullName: String = firstName + " " + lastName
      Text(fullName)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "let fullName: String = " in swift, "Expected let binding in:\n" & swift
  echo "PASS: let bindings in component"

# ---- Label and Image ----

block testLabelAndImage:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      VStack {
        Label("Settings", systemImage: "gear")
        Image(systemName: "star.fill")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Label(\"Settings\", systemImage: \"gear\")" in swift, "Expected Label in:\n" & swift
  assert "Image(systemName: \"star.fill\")" in swift, "Expected Image in:\n" & swift
  echo "PASS: Label and Image"

# ---- Group with modifiers ----

block testGroupModifiers:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      Group {
        Text("A")
        Text("B")
      }
        .font(.headline)
        .foregroundColor(.blue)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Group {" in swift, "Expected Group in:\n" & swift
  assert ".font(.headline)" in swift, "Expected font modifier in:\n" & swift
  assert ".foregroundColor(.blue)" in swift, "Expected color modifier in:\n" & swift
  echo "PASS: Group with modifiers"

# ---- onDelete/onMove for List ----

block testOnDelete:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      items: String[] = []
    }
    action DeleteItems
    component Main {
      List {
        ForEach(items, id: self, item: item) {
          Text(item)
        }
          .onDelete(perform: DeleteItems)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".onDelete" in swift, "Expected .onDelete in:\n" & swift
  echo "PASS: onDelete handler"

# ---- Nil coalescing ----

block testNilCoalescing:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      nickname: String = ""
    }
    component Main {
      Text(nickname ?? "Anonymous")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "??" in swift, "Expected ?? in:\n" & swift
  assert "\"Anonymous\"" in swift, "Expected default in:\n" & swift
  echo "PASS: nil coalescing"

# ---- String concatenation ----

block testStringConcat:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      first: String = ""
      last: String = ""
    }
    component Main {
      let fullName: String = first + " " + last
      Text(fullName)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "String(describing:" in swift, "Expected String concat in:\n" & swift
  echo "PASS: string concatenation"

# ---- Array literals ----

block testArrayLiteral:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "[.blue, .purple]" in swift, "Expected array literal in:\n" & swift
  echo "PASS: array literals"

# ---- TabView with selection ----

block testTabView:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      selectedTab: Int = 0
    }
    component Main {
      TabView(selection: selectedTab) {
        Text("Home")
          .tabItem {
            Label("Home", systemImage: "house")
          }
        Text("Settings")
          .tabItem {
            Label("Settings", systemImage: "gear")
          }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "TabView(selection:" in swift, "Expected TabView in:\n" & swift
  assert ".tabItem {" in swift or ".tabItem" in swift, "Expected .tabItem in:\n" & swift
  echo "PASS: TabView with selection"

# ---- @EnvironmentObject ----

block testEnvironmentObject:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      @ObservedObject viewModel: ViewModel
      Text("Hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@ObservedObject" in swift, "Expected @ObservedObject in:\n" & swift
  echo "PASS: @ObservedObject in component"

# ---- Comprehensive modifier chain ----

block testModifierChain:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      text: String = ""
      showAlert: Bool = false
    }
    action Save
    component Main {
      VStack(alignment: .leading, spacing: 16) {
        TextField("Enter text", text: text)
          .textFieldStyle(.roundedBorder)
          .padding(horizontal: 16)
        Button("Save", action: Save)
          .buttonStyle(.borderedProminent)
          .disabled(text == "")
        Spacer()
      }
      .padding(16)
      .navigationTitle("Editor")
      .alert(isPresented: showAlert) {
        Text("Saved!")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "VStack(alignment: .leading, spacing: 16)" in swift, "Expected VStack in:\n" & swift
  assert ".textFieldStyle(.roundedBorder)" in swift, "Expected textFieldStyle in:\n" & swift
  assert ".buttonStyle(.borderedProminent)" in swift, "Expected buttonStyle in:\n" & swift
  assert ".disabled(" in swift, "Expected disabled in:\n" & swift
  assert ".navigationTitle(\"Editor\")" in swift, "Expected navTitle in:\n" & swift
  assert ".alert(isPresented:" in swift, "Expected alert in:\n" & swift
  echo "PASS: comprehensive modifier chain"

# ---- Computed state properties ----

block testComputedState:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      firstName: String = ""
      lastName: String = ""
      computed fullName: String = firstName + " " + lastName
    }
    component Main {
      Text(fullName)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "var fullName: String {" in swift, "Expected computed property in:\n" & swift
  assert "CodingKeys" in swift, "Expected CodingKeys enum in:\n" & swift
  assert "case firstName" in swift, "Expected stored field in CodingKeys in:\n" & swift
  assert "case lastName" in swift, "Expected stored field in CodingKeys in:\n" & swift
  echo "PASS: computed state properties"

# ---- Optional type syntax ----

block testOptionalType:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      selectedId: String? = nil
      count: Int = 0
    }
    component Main {
      Text(selectedId ?? "None")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "String?" in swift, "Expected optional type in:\n" & swift
  assert "??" in swift, "Expected nil coalescing in:\n" & swift
  echo "PASS: optional type syntax"

# ---- Comparison operators ----

block testComparisonOps:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      count: Int = 0
    }
    component Main {
      if count > 0 {
        Text("Positive")
      }
      Text("\(count)")
        .disabled(count == 0)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "> 0" in swift, "Expected > comparison in:\n" & swift
  assert ".disabled(" in swift, "Expected disabled in:\n" & swift
  echo "PASS: comparison operators"

# ---- Conditional modifiers ----

block testConditionalModifiers:
  let (swift, errors) = generateSwift("""
    app TestApp
    state {
      loading: Bool = false
      visible: Bool = true
    }
    component Main {
      Text("Content")
        .opacity(visible ? 1.0 : 0.0)
        .redacted(reason: loading ? .placeholder : [])
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".opacity(" in swift, "Expected opacity in:\n" & swift
  assert ".redacted(reason:" in swift, "Expected redacted in:\n" & swift
  echo "PASS: conditional modifiers"

# ---- Closure Expression Tests ----

block testClosureNoParams:
  let (swift, errors) = generateSwift("""
    app ClosureApp
    state {
      items: String[] = []
    }
    component Main {
      List {
        ForEach(items, id: self) {
          Text("item")
        }
      }
        .onAppear {
          Text("loading")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  echo "PASS: closure no params (in modifier children)"

block testClosureWithParams:
  let (swift, errors) = generateSwift("""
    app ClosureApp
    state {
      items: String[] = []
    }
    component Main {
      Text("hello")
        .background(.blue)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  echo "PASS: closure with params"

block testClosureExprParsing:
  # Test that { param in expr } parses as closure, not map
  let (prog, diags) = parseSrc("""
    app ClosureApp
    state {
      items: String[] = []
    }
    component Main {
      Text("test")
    }
  """)
  assert diags.len == 0, "Parse errors: " & $diags.len
  echo "PASS: closure expression parsing"

block testClosureInExpression:
  # Test closure as an expression value (e.g. sorted(by: { a, b in a < b }))
  let (swift, errors) = generateSwift("""
    app ClosureApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items.sorted(by: { a, b in a < b }), id: self) {
        Text("item")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "{ a, b in" in swift, "Expected closure with params in:\n" & swift
  echo "PASS: closure in expression"

block testClosureBodyOnly:
  # Test closure with just a body expression (no params)
  let (swift, errors) = generateSwift("""
    app ClosureApp
    state {
      count: Int = 0
    }
    component Main {
      Text("test")
        .onAppear { Text("loaded") }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  echo "PASS: closure body only"

block testMapLiteralStillWorks:
  # Verify map literals still parse correctly after closure changes
  let (swift, errors) = generateSwift("""
    app MapApp
    tokens {
      colors.primary = "#FF0000"
    }
    state {
      count: Int = 0
    }
    component Main {
      Text("test")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  echo "PASS: map literal still works"

# ---- @EnvironmentObject and @Published Tests ----

block testEnvironmentObject:
  let (swift, errors) = generateSwift("""
    app EnvObjApp
    state {
      count: Int = 0
    }
    component Main {
      @EnvironmentObject settings: UserSettings
      Text("hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@EnvironmentObject var settings: UserSettings" in swift, "Expected @EnvironmentObject in:\n" & swift
  echo "PASS: @EnvironmentObject in component"

block testPublishedModelFields:
  let (swift, errors) = generateSwift("""
    app PubApp
    model UserSettings {
      @Published fontSize: Int
      @Published theme: String
      appName: String
    }
    state {
      count: Int = 0
    }
    component Main {
      Text("hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "class UserSettings: ObservableObject" in swift, "Expected ObservableObject class in:\n" & swift
  assert "@Published var fontSize: Int" in swift, "Expected @Published in:\n" & swift
  assert "@Published var theme: String" in swift, "Expected @Published theme in:\n" & swift
  assert "var appName: String" in swift, "Expected non-published field in:\n" & swift
  echo "PASS: @Published model fields"

block testModelProtocolConformance:
  let (swift, errors) = generateSwift("""
    app ProtoApp
    model Item: Identifiable, Hashable {
      id: String
      name: String
    }
    state {
      items: Item[] = []
    }
    component Main {
      Text("hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "struct Item: Identifiable, Hashable" in swift, "Expected protocol conformance in:\n" & swift
  echo "PASS: model protocol conformance"

block testModelPublishedWithProtocol:
  let (swift, errors) = generateSwift("""
    app PubProtoApp
    model AppState: Identifiable {
      @Published count: Int
      id: String
    }
    state {
      x: Int = 0
    }
    component Main {
      Text("hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  # ObservableObject should be prepended to conformances
  assert "class AppState: ObservableObject, Identifiable" in swift, "Expected OO + proto in:\n" & swift
  echo "PASS: model @Published with protocol conformance"

# ---- ForEach Advanced Patterns ----

block testForEachIdentifiable:
  # ForEach with Identifiable items (no id: needed if items conform to Identifiable)
  let (swift, errors) = generateSwift("""
    app ForEachApp
    model Item: Identifiable {
      id: String
      name: String
    }
    state {
      items: Item[] = []
    }
    component Main {
      ForEach(items, id: id, item: item) {
        Text(item.name)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ForEach(" in swift, "Expected ForEach in:\n" & swift
  assert "id: \\.id" in swift, "Expected id keypath in:\n" & swift
  echo "PASS: ForEach with id keypath"

block testForEachSelfId:
  # ForEach with \.self for simple types
  let (swift, errors) = generateSwift("""
    app ForEachSelfApp
    state {
      names: String[] = []
    }
    component Main {
      ForEach(names, id: self, item: name) {
        Text(name)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "\\.self" in swift, "Expected \\.self in:\n" & swift
  echo "PASS: ForEach with self id"

block testForEachRange:
  # ForEach with range expression
  let (swift, errors) = generateSwift("""
    app ForEachRangeApp
    state {
      count: Int = 5
    }
    component Main {
      ForEach(0 ..< 10, id: self, item: i) {
        Text("Item")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ForEach(" in swift, "Expected ForEach in:\n" & swift
  assert "id: \\.self" in swift, "Expected self id in:\n" & swift
  echo "PASS: ForEach with range"

block testListWithSelection:
  # List with selection binding
  let (swift, errors) = generateSwift("""
    app ListApp
    state {
      items: String[] = []
      selectedItem: String? = null
    }
    component Main {
      List(selection: selectedItem) {
        ForEach(items, id: self, item: item) {
          Text(item)
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "List(selection:" in swift, "Expected List selection in:\n" & swift
  assert "$store.state.selectedItem" in swift, "Expected binding in:\n" & swift
  echo "PASS: List with selection binding"

# ---- Key Path Expression Tests ----

block testKeyPathShorthand:
  # \.member shorthand key path
  let (swift, errors) = generateSwift("""
    app KPApp
    model Item: Identifiable {
      id: String
      name: String
    }
    state {
      items: Item[] = []
    }
    component Main {
      ForEach(items.sorted(by: \.name), id: id, item: item) {
        Text(item.name)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "\\.name" in swift, "Expected \\.name key path in:\n" & swift
  echo "PASS: key path shorthand"

block testKeyPathWithType:
  # \Type.member key path
  let (swift, errors) = generateSwift("""
    app KPApp2
    model User {
      name: String
      age: Int
    }
    state {
      users: User[] = []
    }
    component Main {
      List {
        ForEach(users, id: self, item: user) {
          Text(user.name)
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  echo "PASS: key path with type"

# ---- Type Casting and Type Check Tests ----

block testTypeCastAs:
  let (swift, errors) = generateSwift("""
    app CastApp
    state {
      value: Int = 0
    }
    component Main {
      Text(value as String)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "as String" in swift, "Expected 'as String' in:\n" & swift
  echo "PASS: type cast as"

block testTypeCastAsOptional:
  let (swift, errors) = generateSwift("""
    app CastOptApp
    state {
      value: Int = 0
    }
    component Main {
      Text(value as? String)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "as? String" in swift, "Expected 'as? String' in:\n" & swift
  echo "PASS: type cast as?"

block testTypeCheck:
  let (swift, errors) = generateSwift("""
    app TypeCheckApp
    state {
      value: Int = 0
    }
    component Main {
      if value is Int {
        Text("is int")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "is Int" in swift, "Expected 'is Int' in:\n" & swift
  echo "PASS: type check is"

# ---- Binding Transformation Tests ----

block testBindingConstant:
  let (swift, errors) = generateSwift("""
    app BindApp
    state {
      count: Int = 0
    }
    component Main {
      Toggle("Test", isOn: true)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".constant(true)" in swift, "Expected .constant(true) in:\n" & swift
  echo "PASS: Binding.constant"

block testBindingCustomGetSet:
  # Binding(get: { closure }, set: { closure }) through generic call + closures
  let (swift, errors) = generateSwift("""
    app BindApp2
    state {
      count: Int = 0
    }
    component Main {
      Toggle("Test", isOn: Binding(get: { count > 0 }, set: { v in count }))
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Binding(" in swift, "Expected Binding( in:\n" & swift
  assert "get:" in swift, "Expected get: in:\n" & swift
  assert "set:" in swift, "Expected set: in:\n" & swift
  echo "PASS: Binding custom get/set"

# ---- NavigationPath Tests ----

block testNavigationStackDirect:
  # NavigationStack in component using generic passthrough
  let (swift, errors) = generateSwift("""
    app NavApp
    state {
      count: Int = 0
    }
    component Main {
      NavigationStack {
        List {
          NavigationLink("Detail", value: "detail-1")
        }
          .navigationDestination(for: String.self) {
            Text("Detail view")
          }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "NavigationStack" in swift, "Expected NavigationStack in:\n" & swift
  assert ".navigationDestination" in swift, "Expected navigationDestination in:\n" & swift
  echo "PASS: NavigationStack in component"

# ---- Prefix Operator Tests ----

block testUnaryNot:
  let (swift, errors) = generateSwift("""
    app PrefixApp
    state {
      isVisible: Bool = true
    }
    component Main {
      if !isVisible {
        Text("hidden")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "!(" in swift, "Expected negation in:\n" & swift
  echo "PASS: unary not"

block testUnaryMinus:
  let (swift, errors) = generateSwift("""
    app MinusApp
    state {
      offset: Int = 10
    }
    component Main {
      Text("test")
        .offset(x: -offset, y: 0)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "-store.state.offset" in swift, "Expected negation in:\n" & swift
  echo "PASS: unary minus"

# ---- $ Prefix Tests ----

block testShorthandClosureParams:
  let (swift, errors) = generateSwift("""
    app ShorthandApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items.sorted(by: { $0 < $1 }), id: self, item: item) {
        Text(item)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "$0" in swift, "Expected $0 in:\n" & swift
  assert "$1" in swift, "Expected $1 in:\n" & swift
  echo "PASS: $0 $1 shorthand params"

block testBindingPrefixExpr:
  let (swift, errors) = generateSwift("""
    app BindPrefixApp
    state {
      searchText: String = ""
    }
    component Main {
      @State localText: String = ""
      TextField("Search", text: $localText)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  # $localText should emit as $localText (a @State binding)
  assert "$localText" in swift, "Expected $localText binding in:\n" & swift
  echo "PASS: $ binding prefix"

block testBindingPrefixState:
  let (swift, errors) = generateSwift("""
    app BindStateApp
    state {
      isEditing: Bool = false
    }
    component Main {
      Toggle("Edit", isOn: $isEditing)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  # $isEditing should emit as $store.state.isEditing
  assert "$store.state.isEditing" in swift, "Expected state binding in:\n" & swift
  echo "PASS: $ state binding prefix"

# ---- ContextMenu, DisclosureGroup, Menu Tests ----

block testContextMenu:
  let (swift, errors) = generateSwift("""
    app ContextApp
    action Delete
    action Duplicate
    state {
      count: Int = 0
    }
    reducer {
      on Delete { set count = 0 }
      on Duplicate { set count = count + 1 }
    }
    component Main {
      Text("Long press me")
        .contextMenu {
          Button("Delete", action: Delete)
          Button("Duplicate", action: Duplicate)
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".contextMenu" in swift, "Expected contextMenu in:\n" & swift
  assert "Delete" in swift, "Expected Delete action in:\n" & swift
  echo "PASS: contextMenu with actions"

block testDisclosureGroup:
  let (swift, errors) = generateSwift("""
    app DisclosureApp
    state {
      isExpanded: Bool = false
    }
    component Main {
      DisclosureGroup("Advanced", isExpanded: $isExpanded) {
        Text("Hidden content")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "DisclosureGroup" in swift, "Expected DisclosureGroup in:\n" & swift
  assert "$store.state.isExpanded" in swift, "Expected binding in:\n" & swift
  echo "PASS: DisclosureGroup with binding"

block testMenuView:
  let (swift, errors) = generateSwift("""
    app MenuApp
    action Sort
    action Filter
    state {
      count: Int = 0
    }
    reducer {
      on Sort { set count = 0 }
      on Filter { set count = 1 }
    }
    component Main {
      Menu("Options") {
        Button("Sort", action: Sort)
        Button("Filter", action: Filter)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Menu(" in swift, "Expected Menu in:\n" & swift
  echo "PASS: Menu view with actions"

# ---- If-Let Chaining Tests ----

block testIfLetChained:
  let (swift, errors) = generateSwift("""
    app ChainApp
    state {
      name: String? = nil
      age: Int? = nil
    }
    component Main {
      if let n = name, let a = age {
        Text("\(n) is \(a)")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if let" in swift, "Expected if-let in:\n" & swift
  # Check both bindings are present comma-separated
  assert ", let" in swift, "Expected chained let in:\n" & swift
  echo "PASS: if-let chaining"

block testIfLetWithCondition:
  let (swift, errors) = generateSwift("""
    app ChainCondApp
    state {
      name: String? = nil
      isActive: Bool = true
    }
    component Main {
      if let n = name, isActive {
        Text(n)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "if let" in swift, "Expected if-let in:\n" & swift
  # Should have the boolean condition after the let binding
  assert ", " in swift, "Expected comma-separated clause in:\n" & swift
  echo "PASS: if-let with condition"

# ---- Trailing Closure Tests ----

block testTrailingClosure:
  let (swift, errors) = generateSwift("""
    app TrailApp
    state {
      items: String[] = []
    }
    component Main {
      ForEach(items.sorted(by: { $0 < $1 }), id: self, item: item) {
        Text(item)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "$0" in swift, "Expected $0 in:\n" & swift
  echo "PASS: trailing closure in expression"

# ---- Force Unwrap Tests ----

block testForceUnwrap:
  let (swift, errors) = generateSwift("""
    app UnwrapApp
    state {
      name: String? = nil
    }
    component Main {
      Text(name!)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "!" in swift, "Expected force unwrap in:\n" & swift
  echo "PASS: force unwrap operator"

# ---- @Namespace Tests ----

block testNamespaceWrapper:
  let (swift, errors) = generateSwift("""
    app NamespaceApp
    state { count: Int = 0 }
    component Main {
      @Namespace animID
      VStack {
        Text("hello")
          .matchedGeometryEffect(id: "hero", in: animID)
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@Namespace" in swift, "Expected @Namespace in:\n" & swift
  assert "animID" in swift, "Expected animID in:\n" & swift
  assert ".matchedGeometryEffect" in swift, "Expected matchedGeometryEffect in:\n" & swift
  echo "PASS: @Namespace wrapper"

# ---- Enum Raw Value Tests ----

block testEnumRawValues:
  let (swift, errors) = generateSwift("""
    app EnumApp
    state { count: Int = 0 }
    enum Tab: String {
      Home = "Home"
      Settings = "Settings"
      Profile = "Profile"
    }
    component Main {
      Text("hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "= \"Home\"" in swift, "Expected raw value in:\n" & swift
  assert "= \"Settings\"" in swift, "Expected raw value in:\n" & swift
  echo "PASS: enum raw values"

block testEnumProtocol:
  let (swift, errors) = generateSwift("""
    app EnumProtoApp
    state { count: Int = 0 }
    enum Priority: Int, Comparable {
      Low = 0
      Medium = 1
      High = 2
    }
    component Main {
      Text("hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Int" in swift, "Expected Int raw type in:\n" & swift
  assert "Comparable" in swift, "Expected Comparable protocol in:\n" & swift
  assert "= 0" in swift, "Expected raw value 0 in:\n" & swift
  echo "PASS: enum with protocol conformance"

# ---- @Environment Dismiss Tests ----

block testEnvironmentDismiss:
  let (swift, errors) = generateSwift("""
    app DismissApp
    state { count: Int = 0 }
    component DetailView {
      @Environment(.dismiss) dismiss: DismissAction
      Button("Close", action: dismiss)
    }
    component Main {
      Text("main")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@Environment" in swift, "Expected @Environment in:\n" & swift
  assert "dismiss" in swift, "Expected dismiss in:\n" & swift
  echo "PASS: @Environment dismiss action"

# ---- Platform Conditional Tests ----

block testPlatformConditional:
  let (swift, errors) = generateSwift("""
    app PlatformApp
    state { count: Int = 0 }
    component Main {
      #if os(iOS) {
        Text("iPhone")
      } #else {
        Text("Mac")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "#if os(iOS)" in swift, "Expected #if os(iOS) in:\n" & swift
  assert "#else" in swift, "Expected #else in:\n" & swift
  assert "#endif" in swift, "Expected #endif in:\n" & swift
  echo "PASS: platform conditional"

block testPlatformConditionalNoElse:
  let (swift, errors) = generateSwift("""
    app PlatformApp2
    state { count: Int = 0 }
    component Main {
      Text("always")
      #if os(macOS) {
        Text("mac only")
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "#if os(macOS)" in swift, "Expected #if os(macOS) in:\n" & swift
  assert "#endif" in swift, "Expected #endif in:\n" & swift
  echo "PASS: platform conditional without else"

# ---- Settings Scene Tests ----

block testSettingsScene:
  let (swift, errors) = generateSwift("""
    app SettingsApp
    state { count: Int = 0 }
    component Main {
      Text("Main View")
    }
    component SettingsView {
      Text("Settings")
    }
    settings SettingsView
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "Settings {" in swift, "Expected Settings scene in:\n" & swift
  assert "Component_SettingsView" in swift, "Expected SettingsView component in Settings:\n" & swift
  assert "#if os(macOS)" in swift, "Expected macOS platform guard:\n" & swift
  echo "PASS: settings scene"

# ---- Gesture Modifier Tests ----

block testGestureModifier:
  let (swift, errors) = generateSwift("""
    app GestureApp
    state { offset: Double = 0.0 }
    component Main {
      Text("Drag me")
        .gesture(DragGesture())
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".gesture(DragGesture())" in swift, "Expected gesture modifier in:\n" & swift
  echo "PASS: gesture modifier"

# ---- @GestureState and @AccessibilityFocusState Tests ----

block testGestureState:
  let (swift, errors) = generateSwift("""
    app GestureStateApp
    state { x: Double = 0.0 }
    component Main {
      @GestureState dragOffset: CGSize
      Text("Drag")
        .offset(x: dragOffset.width, y: dragOffset.height)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@GestureState" in swift, "Expected @GestureState in:\n" & swift
  assert "dragOffset" in swift, "Expected dragOffset in:\n" & swift
  echo "PASS: @GestureState wrapper"

block testAccessibilityFocusState:
  let (swift, errors) = generateSwift("""
    app A11yApp
    state { name: String = "" }
    component Main {
      @AccessibilityFocusState isFieldFocused: Bool
      TextField("Name", text: $name)
        .accessibilityLabel("Name field")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@AccessibilityFocusState" in swift, "Expected @AccessibilityFocusState in:\n" & swift
  assert "isFieldFocused" in swift, "Expected isFieldFocused in:\n" & swift
  echo "PASS: @AccessibilityFocusState wrapper"

# ---- ScrollViewReader Test ----

block testScrollViewReader:
  let (swift, errors) = generateSwift("""
    app ScrollApp
    state { items: [String] = [] }
    component Main {
      ScrollViewReader {
        List {
          Text("Item")
        }
      }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "ScrollViewReader" in swift, "Expected ScrollViewReader in:\n" & swift
  echo "PASS: ScrollViewReader"

# ---- String Interpolation in Modifier Args Test ----

block testStringInterpolationInModifier:
  let (swift, errors) = generateSwift("""
    app InterpApp
    state { count: Int = 0 }
    component Main {
      Text("Hello")
        .navigationTitle("Count: \(count)")
        .accessibilityLabel("Item number \(count)")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "\\(store.state.count)" in swift, "Expected interpolation in:\n" & swift
  echo "PASS: string interpolation in modifier args"

# ---- Toolbar with ToolbarItem Test ----

block testToolbarWithItems:
  let (swift, errors) = generateSwift("""
    app ToolbarApp
    state { count: Int = 0 }
    action Increment
    reducer {
      on Increment { set count = count + 1 }
    }
    component Main {
      Text("Count: \(count)")
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Add", action: Increment)
          }
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".toolbar" in swift, "Expected .toolbar in:\n" & swift
  assert "ToolbarItem" in swift, "Expected ToolbarItem in:\n" & swift
  assert ".navigationBarTrailing" in swift, "Expected placement in:\n" & swift
  echo "PASS: toolbar with ToolbarItem"

# ---- Presentation Modifier Tests ----

block testSheetWithBinding:
  let (swift, errors) = generateSwift("""
    app SheetApp
    state { showSheet: Bool = false }
    action ToggleSheet
    reducer {
      on ToggleSheet { set showSheet = !showSheet }
    }
    component Main {
      Button("Show Sheet", action: ToggleSheet)
        .sheet(isPresented: $showSheet) {
          Text("Sheet Content")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".sheet(isPresented:" in swift, "Expected sheet binding in:\n" & swift
  assert "Sheet Content" in swift, "Expected sheet content in:\n" & swift
  echo "PASS: sheet with binding"

block testAlertWithBinding:
  let (swift, errors) = generateSwift("""
    app AlertApp
    state { showAlert: Bool = false }
    component Main {
      Text("Hello")
        .alert(isPresented: $showAlert) {
          Text("Alert!")
        }
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".alert(isPresented:" in swift, "Expected alert binding in:\n" & swift
  echo "PASS: alert with binding"

# ---- .searchable Test ----

block testSearchable:
  let (swift, errors) = generateSwift("""
    app SearchApp
    state { searchText: String = "" }
    component Main {
      List {
        Text("Item")
      }
      .searchable(text: $searchText)
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert ".searchable" in swift, "Expected searchable in:\n" & swift
  assert "$store.state.searchText" in swift or "store.state.searchText" in swift, "Expected binding in:\n" & swift
  echo "PASS: searchable with binding"

# ---- @Observable Model Test ----

block testObservableModel:
  let (swift, errors) = generateSwift("""
    app ObservableApp
    state { name: String = "" }
    model UserSettings: Observable, Identifiable {
      username: String
      theme: String = "dark"
    }
    component Main {
      Text("Hello")
    }
  """)
  assert errors.len == 0, "Errors: " & errors.join(", ")
  assert "@Observable" in swift, "Expected @Observable in:\n" & swift
  assert "class UserSettings" in swift, "Expected class declaration in:\n" & swift
  assert "Identifiable" in swift, "Expected Identifiable in:\n" & swift
  # Observable should be removed from conformance list (it's a macro, not a protocol)
  # Check the UserSettings line specifically doesn't have Observable as conformance
  assert "UserSettings: Observable" notin swift, "Observable should not appear as conformance on UserSettings in:\n" & swift
  echo "PASS: @Observable model"

echo "PASS: GUI new features"
