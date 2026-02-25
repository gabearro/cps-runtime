## Bridge artifact orchestration and optional bridge compilation.

import std/[os, osproc]
import ./types
import ./ir
import ./bridge_codegen_swift
import ./bridge_codegen_nim

type
  GuiBridgeArtifacts* = object
    enabled*: bool
    entryFile*: string
    generatedDir*: string
    nimDir*: string
    headerPath*: string
    swiftWrapperPath*: string
    appSwiftWrapperPath*: string
    nimShimPath*: string
    buildScriptPath*: string
    bridgeImplPath*: string
    dylibLatestPath*: string

proc actionNeedsBridge(irProgram: GuiIrProgram): bool =
  for action in irProgram.actions:
    if action.owner in {gaoNim, gaoBoth}:
      return true
  false

proc resolveBridgeEntry*(entryFile: string, irProgram: GuiIrProgram, overrideEntry: string): string =
  if overrideEntry.len > 0:
    if overrideEntry.isAbsolute:
      return normalizedPath(overrideEntry)
    return normalizedPath(getCurrentDir() / overrideEntry)

  if irProgram.bridge.nimEntry.len > 0:
    let base = entryFile.parentDir()
    if irProgram.bridge.nimEntry.isAbsolute:
      return normalizedPath(irProgram.bridge.nimEntry)
    return normalizedPath(base / irProgram.bridge.nimEntry)

  let inferred = normalizedPath(entryFile.parentDir() / "bridge.nim")
  if fileExists(inferred):
    return inferred

  ""

proc writeText(path: string, content: string, generatedFiles: var seq[string]) =
  createDir(path.parentDir())
  writeFile(path, content)
  generatedFiles.add path

proc ensureExecutable(path: string, diagnostics: var seq[GuiDiagnostic]) =
  try:
    when defined(posix):
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  except CatchableError as e:
    diagnostics.add mkDiagnostic(path, 1, 1, gsWarning, "failed to set executable permission: " & e.msg, "GUI_BRIDGE_CHMOD")

proc emitBridgeArtifacts*(
  irProgram: GuiIrProgram,
  entryFile: string,
  appDir: string,
  repoRoot: string,
  overrideEntry: string,
  bridgeMode: GuiBridgeMode,
  generatedFiles: var seq[string],
  diagnostics: var seq[GuiDiagnostic]
): GuiBridgeArtifacts =
  if bridgeMode == gbmNone:
    return

  if not actionNeedsBridge(irProgram):
    return

  let bridgeEntry = resolveBridgeEntry(entryFile, irProgram, overrideEntry)
  if bridgeEntry.len == 0:
    diagnostics.add mkDiagnostic(
      entryFile,
      1,
      1,
      gsError,
      "Nim-owned actions require a bridge entry; set bridge { nimEntry: ... } or pass --nim-bridge",
      "GUI_BRIDGE_ENTRY_MISSING"
    )
    return

  result.enabled = true
  result.entryFile = bridgeEntry
  result.generatedDir = appDir / "Bridge" / "Generated"
  result.nimDir = appDir / "Bridge" / "Nim"
  result.headerPath = result.generatedDir / "GUIBridge.generated.h"
  result.swiftWrapperPath = result.generatedDir / "GUIBridgeSwift.generated.swift"
  result.appSwiftWrapperPath = appDir / "App" / "Generated" / "GUIBridgeSwift.generated.swift"
  result.nimShimPath = result.generatedDir / "GUIBridgeNim.generated.nim"
  result.buildScriptPath = result.nimDir / "build_bridge.sh"
  result.bridgeImplPath = result.nimDir / "bridge_impl.nim"
  let dylibExt = when defined(macosx): "dylib" else: "so"
  result.dylibLatestPath = result.nimDir / ("libgui_bridge_latest." & dylibExt)

  createDir(result.generatedDir)
  createDir(result.nimDir)

  writeText(result.headerPath, emitBridgeHeader(irProgram), generatedFiles)
  writeText(result.swiftWrapperPath, emitBridgeSwiftWrapper(irProgram), generatedFiles)
  writeText(result.appSwiftWrapperPath, emitBridgeSwiftWrapper(irProgram), generatedFiles)
  writeText(result.nimShimPath, emitBridgeNimShim(irProgram), generatedFiles)
  writeText(result.buildScriptPath, emitBridgeBuildScript(repoRoot, bridgeEntry), generatedFiles)
  ensureExecutable(result.buildScriptPath, diagnostics)

  if not fileExists(result.bridgeImplPath):
    writeText(result.bridgeImplPath, emitBridgeImplTemplate(irProgram), generatedFiles)

proc compileBridge*(
  artifacts: GuiBridgeArtifacts,
  diagnostics: var seq[GuiDiagnostic],
  verbose: bool
): bool =
  if not artifacts.enabled:
    return true

  let cmd = "GUI_BRIDGE_ENTRY=" & quoteShell(artifacts.entryFile) & " " & quoteShell(artifacts.buildScriptPath)
  let res = execCmdEx(cmd)
  if verbose:
    echo res.output

  if res.exitCode != 0:
    diagnostics.add mkDiagnostic(
      artifacts.buildScriptPath,
      1,
      1,
      gsError,
      "bridge build failed: " & cmd & "\n" & res.output,
      "GUI_BRIDGE_BUILD"
    )
    return false

  true
