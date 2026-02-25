import std/[os, strutils]
import cps/gui
import cps/gui/[ir, swift_codegen, xcodeproj_codegen]

let entry = "examples/gui/app.gui"
let parsed = parseGuiProgram(entry)
let sem = semanticCheck(parsed.program)
let allDiags = parsed.diagnostics & sem.diagnostics
assert not allDiags.hasErrors

let irProgram = buildIr(sem)

let outRoot = getTempDir() / "cps_gui_codegen_golden"
if dirExists(outRoot):
  removeDir(outRoot)
createDir(outRoot)

var generatedFiles: seq[string] = @[]
var diagnostics: seq[GuiDiagnostic] = @[]

let scaffold = emitXcodeProject(irProgram, outRoot, generatedFiles, diagnostics)
emitSwiftSources(irProgram, scaffold.appDir, generatedFiles, diagnostics)
assert not diagnostics.hasErrors

let generatedMain = scaffold.appDir / "App" / "Generated" / "GUI.generated.swift"
let generatedRuntime = scaffold.appDir / "App" / "Generated" / "GUIRuntime.generated.swift"
assert fileExists(generatedMain)
assert fileExists(generatedRuntime)
assert fileExists(scaffold.projectPath / "project.pbxproj")

let expectedMain = "tests/gui/golden/gui_generated.expected.swift"
assert fileExists(expectedMain)
let actual = readFile(generatedMain)
let expected = readFile(expectedMain)
assert actual == expected

echo "PASS: GUI codegen golden"
