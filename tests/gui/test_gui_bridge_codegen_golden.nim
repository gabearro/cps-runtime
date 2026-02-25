import std/os
import cps/gui
import cps/gui/[ir, bridge_codegen_swift, bridge_codegen_nim]

const thisDir = currentSourcePath().parentDir()
const fixturePath = thisDir / "fixtures" / "macro_file.gui"
const goldenDir = thisDir / "golden"

let parsed = parseGuiProgram(fixturePath)
let sem = semanticCheck(parsed.program)
let diags = parsed.diagnostics & sem.diagnostics
assert not diags.hasErrors

let irProgram = buildIr(sem)
let header = emitBridgeHeader(irProgram)
let swiftWrapper = emitBridgeSwiftWrapper(irProgram)
let nimShim = emitBridgeNimShim(irProgram)

let expectedHeaderPath = goldenDir / "gui_bridge_header.expected.h"
let expectedSwiftPath = goldenDir / "gui_bridge_swift_wrapper.expected.swift"
let expectedNimPath = goldenDir / "gui_bridge_nim_wrapper.expected.nim"

assert fileExists(expectedHeaderPath)
assert fileExists(expectedSwiftPath)
assert fileExists(expectedNimPath)

assert readFile(expectedHeaderPath) == header
assert readFile(expectedSwiftPath) == swiftWrapper
assert readFile(expectedNimPath) == nimShim

echo "PASS: GUI bridge codegen golden"
