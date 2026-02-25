import std/os
import cps/gui
import cps/gui/macros
import cps/gui/ir_v2

const thisDir = currentSourcePath().parentDir()
const fixturePath = thisDir / "fixtures" / "macro_file.gui"

guiFile(FileMacroModule, "fixtures/macro_file.gui")

let checkDiags = checkFileMacroModuleGui()
assert checkDiags.len == 0

let parsed = parseGuiProgram(fixturePath)
let sem = semanticCheck(parsed.program)
let allDiags = parsed.diagnostics & sem.diagnostics
assert not allDiags.hasErrors

let expectedSig = canonicalIrSignature(buildIrV2(sem))
assert FileMacroModuleGuiIrSignature() == expectedSig

var actionValue: FileMacroModuleGuiAction = gaIncrement
assert ord(actionValue) == 0

echo "PASS: GUI macro guiFile"
