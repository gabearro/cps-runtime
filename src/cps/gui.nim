## CPS GUI - DSL parser + SwiftUI code generation + xcodebuild orchestration.

import std/[os, strutils, sequtils, osproc]
import cps/gui/types
import cps/gui/ast
import cps/gui/lexer
import cps/gui/parser
import cps/gui/sema
import cps/gui/ir
import cps/gui/ir_v2
import cps/gui/backend/core
import cps/gui/backend/availability
import cps/gui/bridge_runtime
import cps/gui/devwatch

export types
export ast
export lexer
export parser
export sema
export ir
export ir_v2

proc mergeDiagnostics(parts: openArray[seq[GuiDiagnostic]]): seq[GuiDiagnostic] =
  for chunk in parts:
    result.add chunk

proc toSemaOptions(opts: GuiCompileOptions): GuiSemaOptions =
  GuiSemaOptions(
    backend: opts.backend,
    targets: opts.targets,
    unsupportedPolicy: opts.unsupportedPolicy
  )

proc toCompileOptions(opts: GuiCheckOptions): GuiCompileOptions =
  GuiCompileOptions(
    backend: opts.backend,
    targets: opts.targets,
    unsupportedPolicy: opts.unsupportedPolicy,
    dialect: opts.dialect,
    verbose: opts.verbose
  )

proc toCompileOptions(opts: GuiGenerateOptions): GuiCompileOptions =
  GuiCompileOptions(
    backend: opts.backend,
    targets: opts.targets,
    unsupportedPolicy: opts.unsupportedPolicy,
    dialect: opts.dialect,
    verbose: opts.verbose
  )

proc sanitizeAppName(name: string): string =
  var sanitized = ""
  for c in name:
    if c.isAlphaNumeric:
      sanitized.add c
  if sanitized.len == 0:
    sanitized = "GuiApp"
  if sanitized[0].isDigit:
    sanitized = "Gui" & sanitized
  sanitized

proc resolveOutputRoot(outDir: string): string =
  if outDir.len == 0:
    normalizedPath(getCurrentDir() / "out")
  elif outDir.isAbsolute:
    normalizedPath(outDir)
  else:
    normalizedPath(getCurrentDir() / outDir)

proc compileGuiIr*(
  entryFile: string,
  opts: GuiCompileOptions
): GuiCompileResult =
  let normalizedEntry = normalizedPath(entryFile)
  let parsed = parseGuiProgram(normalizedEntry)
  let sem = semanticCheck(parsed.program, toSemaOptions(opts))
  result.diagnostics = mergeDiagnostics([parsed.diagnostics, sem.diagnostics])
  result.loadedFiles = parsed.program.loadedFiles

  if result.diagnostics.hasErrors:
    return

  let irProgram = buildIrV2(sem)
  result.appName = sanitizeAppName(
    if parsed.program.appName.len > 0: parsed.program.appName else: normalizedEntry.splitFile.name
  )
  result.irSignature = canonicalIrSignature(irProgram)

proc checkGuiProject*(
  entryFile: string,
  opts: GuiCheckOptions = defaultCheckOptions()
): seq[GuiDiagnostic] =
  let compileRes = compileGuiIr(entryFile, toCompileOptions(opts))
  compileRes.diagnostics

proc listSwiftUiCoverage*(
  opts: GuiCoverageOptions = defaultCoverageOptions()
): GuiCoverageReport =
  case opts.backend
  of gbkSwiftUI:
    coverageReportForSwiftUi(opts)

proc generateGuiProject*(
  entryFile: string,
  outDir: string,
  opts: GuiGenerateOptions
): GuiGenerateResult =
  let normalizedEntry = normalizedPath(entryFile)
  let parsed = parseGuiProgram(normalizedEntry)
  let sem = semanticCheck(parsed.program, toSemaOptions(toCompileOptions(opts)))

  result.diagnostics = mergeDiagnostics([parsed.diagnostics, sem.diagnostics])
  if result.diagnostics.hasErrors:
    return

  let irProgram = buildIr(sem)
  var generatedFiles: seq[string] = @[]
  var diagnostics = result.diagnostics

  let outputRoot = resolveOutputRoot(outDir)

  createDir(outputRoot)

  let appName = sanitizeAppName(parsed.program.appName)

  let appDir = outputRoot / appName
  if opts.clean and dirExists(appDir):
    try:
      removeDir(appDir)
    except CatchableError as e:
      diagnostics.add mkDiagnostic(appDir, 1, 1, gsError, "failed to clean output dir: " & e.msg, "GUI_GEN_CLEAN")

  let backendEmit = emitBackendProject(
    opts.backend,
    irProgram,
    outputRoot,
    opts.targets,
    generatedFiles,
    diagnostics
  )

  let bridgeArtifacts = emitBridgeArtifacts(
    irProgram,
    normalizedEntry,
    backendEmit.appDir,
    normalizedPath(getCurrentDir()),
    opts.nimBridgeEntry,
    opts.bridgeMode,
    generatedFiles,
    diagnostics
  )

  result.projectPath = backendEmit.projectPath
  result.scheme = backendEmit.scheme
  result.generatedFiles = generatedFiles.deduplicate()
  result.diagnostics = diagnostics
  result.bridgeEnabled = bridgeArtifacts.enabled
  result.bridgeBuildScript = bridgeArtifacts.buildScriptPath
  result.bridgeEntry = bridgeArtifacts.entryFile
  result.bridgeDylibPath = bridgeArtifacts.dylibLatestPath

proc runCommand(
  cmd: string,
  diagnostics: var seq[GuiDiagnostic],
  codeOnFail: string
): tuple[ok: bool, output: string] =
  let output = execCmdEx(cmd)
  if output.exitCode != 0:
    diagnostics.add mkDiagnostic(
      "",
      1,
      1,
      gsError,
      "command failed (" & $output.exitCode & "): " & cmd & "\n" & output.output,
      codeOnFail
    )
    return (false, output.output)
  (true, output.output)

proc isGuiAppRunning(appPath: string): bool =
  if appPath.len == 0:
    return false
  let execName = appPath.splitFile.name
  if execName.len == 0:
    return false
  let execPath = appPath / "Contents" / "MacOS" / execName
  if not fileExists(execPath):
    return false
  let probe = execCmdEx("pgrep -f " & quoteShell(execPath))
  probe.exitCode == 0

proc buildGuiProject*(
  entryFile: string,
  outDir: string,
  opts: GuiBuildOptions
): GuiBuildResult =
  let gen = generateGuiProject(
    entryFile,
    outDir,
    GuiGenerateOptions(
      configuration: opts.configuration,
      derivedDataPath: opts.derivedDataPath,
      clean: opts.clean,
      verbose: opts.verbose,
      nimBridgeEntry: opts.nimBridgeEntry,
      bridgeMode: opts.bridgeMode,
      backend: opts.backend,
      targets: opts.targets,
      unsupportedPolicy: opts.unsupportedPolicy,
      dialect: opts.dialect
    )
  )

  result.projectPath = gen.projectPath
  result.scheme = gen.scheme
  result.diagnostics = gen.diagnostics
  result.bridgeEnabled = gen.bridgeEnabled
  result.bridgeBuildScript = gen.bridgeBuildScript
  result.bridgeEntry = gen.bridgeEntry
  result.bridgeDylibPath = gen.bridgeDylibPath

  if result.diagnostics.hasErrors:
    return

  if gen.bridgeEnabled:
    var diags = result.diagnostics
    let bridgeOk = compileBridge(
      GuiBridgeArtifacts(
        enabled: gen.bridgeEnabled,
        entryFile: gen.bridgeEntry,
        buildScriptPath: gen.bridgeBuildScript,
        dylibLatestPath: gen.bridgeDylibPath
      ),
      diags,
      opts.verbose
    )
    result.diagnostics = diags
    if not bridgeOk:
      return

  when not defined(macosx):
    result.diagnostics.add mkDiagnostic(
      "",
      1,
      1,
      gsError,
      "build/run commands are only supported on macOS",
      "GUI_BUILD_PLATFORM"
    )
    return

  var derived = opts.derivedDataPath
  if derived.len == 0:
    let appRoot = gen.projectPath.parentDir()
    derived = appRoot / ".derivedData"

  createDir(derived)

  let configuration = buildConfigurationText(opts.configuration)
  let command =
    "xcodebuild -project " & quoteShell(gen.projectPath) &
    " -scheme " & quoteShell(gen.scheme) &
    " -configuration " & quoteShell(configuration) &
    " -derivedDataPath " & quoteShell(derived) &
    " build"

  result.command = command
  var diags = result.diagnostics
  let cmdResult = runCommand(command, diags, "GUI_BUILD_XCODEBUILD")
  result.diagnostics = diags
  if not cmdResult.ok:
    return

  let appPath = derived / "Build" / "Products" / configuration / (gen.scheme & ".app")
  if appPath.dirExists:
    result.appPath = appPath
    result.success = true
    return

  for path in walkDirRec(derived):
    if path.endsWith(".app") and path.extractFilename() == gen.scheme & ".app":
      result.appPath = path
      result.success = true
      return

  result.diagnostics.add mkDiagnostic(
    "",
    1,
    1,
    gsError,
    "build finished but app bundle was not found under derived data",
    "GUI_BUILD_APP_NOT_FOUND"
  )

proc runGuiProject*(
  entryFile: string,
  outDir: string,
  opts: GuiRunOptions
): GuiRunResult =
  let build = buildGuiProject(
    entryFile,
    outDir,
    GuiBuildOptions(
      configuration: opts.configuration,
      derivedDataPath: opts.derivedDataPath,
      clean: opts.clean,
      verbose: opts.verbose,
      nimBridgeEntry: opts.nimBridgeEntry,
      bridgeMode: opts.bridgeMode,
      backend: opts.backend,
      targets: opts.targets,
      unsupportedPolicy: opts.unsupportedPolicy,
      dialect: opts.dialect
    )
  )

  result.diagnostics = build.diagnostics
  result.appPath = build.appPath
  result.bridgeEnabled = build.bridgeEnabled
  result.bridgeDylibPath = build.bridgeDylibPath
  if result.diagnostics.hasErrors or not build.success:
    return

  when not defined(macosx):
    result.diagnostics.add mkDiagnostic(
      "",
      1,
      1,
      gsError,
      "run command is only supported on macOS",
      "GUI_RUN_PLATFORM"
    )
    return

  let openCmd =
    if opts.keepAppOpen:
      "open " & quoteShell(build.appPath)
    else:
      "open -W " & quoteShell(build.appPath)
  result.command = openCmd

  var diags = result.diagnostics
  let openResult = runCommand(openCmd, diags, "GUI_RUN_OPEN")
  result.diagnostics = diags
  result.success = openResult.ok

proc emitGuiFromNim*(
  nimEntry: string,
  outGuiFile: string,
  opts: GuiEmitOptions
): seq[GuiDiagnostic] =
  let srcPath = normalizedPath(nimEntry)
  if not fileExists(srcPath):
    result.add mkDiagnostic(srcPath, 1, 1, gsError, "Nim entry file not found", "GUI_EMIT_SOURCE")
    return

  var content = ""
  try:
    content = readFile(srcPath)
  except CatchableError as e:
    result.add mkDiagnostic(srcPath, 1, 1, gsError, "failed to read Nim entry: " & e.msg, "GUI_EMIT_READ")
    return

  proc skipSpaces(text: string, idx: var int) =
    while idx < text.len and text[idx] in {' ', '\t', '\r', '\n'}:
      inc idx

  proc parseQuotedString(text: string, startIdx: int): tuple[ok: bool, value: string] =
    if startIdx >= text.len or text[startIdx] != '"':
      return (false, "")
    var i = startIdx + 1
    while i < text.len:
      if text[i] == '"' and text[i - 1] != '\\':
        return (true, text[(startIdx + 1) ..< i])
      inc i
    (false, "")

  proc extractGuiFilePath(text: string): string =
    var probe = text.find("guiFile(")
    while probe >= 0:
      var i = probe + "guiFile(".len
      while i < text.len and text[i] != ',' and text[i] != ')':
        inc i
      if i < text.len and text[i] == ',':
        inc i
        skipSpaces(text, i)
        let parsed = parseQuotedString(text, i)
        if parsed.ok:
          return parsed.value
      probe = text.find("guiFile(", probe + 1)
    ""

  proc extractInlineDsl(text: string): tuple[ok: bool, value: string] =
    let tripleStart = text.find("\"\"\"")
    if tripleStart < 0:
      return (false, "")
    let tripleEnd = text.find("\"\"\"", tripleStart + 3)
    if tripleEnd < 0:
      return (false, "")
    (true, text[(tripleStart + 3) ..< tripleEnd])

  var dslText = ""
  let guiFileRef = extractGuiFilePath(content)
  if guiFileRef.len > 0:
    let refPath =
      if guiFileRef.isAbsolute:
        normalizedPath(guiFileRef)
      else:
        normalizedPath(srcPath.parentDir() / guiFileRef)
    if not fileExists(refPath):
      result.add mkDiagnostic(srcPath, 1, 1, gsError, "guiFile macro references missing file: " & refPath, "GUI_EMIT_GUIFILE_REF")
      return
    try:
      dslText = readFile(refPath)
    except CatchableError as e:
      result.add mkDiagnostic(refPath, 1, 1, gsError, "failed to read guiFile source: " & e.msg, "GUI_EMIT_GUIFILE_READ")
      return
  else:
    let extracted = extractInlineDsl(content)
    if not extracted.ok:
      result.add mkDiagnostic(
        srcPath,
        1,
        1,
        gsError,
        "emit expects guiFile(...) or a triple-quoted guiBlock/guiBuild/guiInline payload",
        "GUI_EMIT_PARSE"
      )
      return
    dslText = extracted.value
  let outPath =
    if outGuiFile.isAbsolute:
      normalizedPath(outGuiFile)
    elif opts.emitDir.len > 0:
      normalizedPath(opts.emitDir / outGuiFile)
    else:
      normalizedPath(getCurrentDir() / outGuiFile)

  try:
    createDir(outPath.parentDir())
    writeFile(outPath, dslText.strip() & "\n")
  except CatchableError as e:
    result.add mkDiagnostic(outPath, 1, 1, gsError, "failed to write emitted .gui file: " & e.msg, "GUI_EMIT_WRITE")
    return

  let parsed = parseGuiProgram(outPath)
  result.add parsed.diagnostics
  let sem = semanticCheck(parsed.program)
  result.add sem.diagnostics

proc devGuiProject*(
  entry: string,
  outDir: string,
  opts: GuiDevOptions
): GuiRunResult =
  let normalizedEntry = normalizedPath(entry)

  proc toRunOptions(): GuiRunOptions =
    GuiRunOptions(
      configuration: opts.configuration,
      derivedDataPath: "",
      clean: false,
      verbose: opts.verbose,
      keepAppOpen: true,
      nimBridgeEntry: opts.nimBridgeEntry,
      bridgeMode: opts.bridgeMode,
      backend: opts.backend,
      targets: opts.targets,
      unsupportedPolicy: opts.unsupportedPolicy,
      dialect: opts.dialect
    )

  proc collectWatchFiles(): seq[string] =
    let parsed = parseGuiProgram(normalizedEntry)
    result.add parsed.program.loadedFiles

    if opts.nimBridgeEntry.len > 0:
      if opts.nimBridgeEntry.isAbsolute:
        result.add normalizedPath(opts.nimBridgeEntry)
      else:
        result.add normalizedPath(getCurrentDir() / opts.nimBridgeEntry)
    elif parsed.program.bridge.nimEntry.len > 0:
      if parsed.program.bridge.nimEntry.isAbsolute:
        result.add normalizedPath(parsed.program.bridge.nimEntry)
      else:
        result.add normalizedPath(normalizedEntry.parentDir() / parsed.program.bridge.nimEntry)
    else:
      result.add normalizedPath(normalizedEntry.parentDir() / "bridge.nim")

    result = result.deduplicate()

  result = runGuiProject(
    entry,
    outDir,
    toRunOptions()
  )
  if result.diagnostics.hasErrors or not result.success:
    return

  if not (opts.watch and opts.hotReload):
    return

  var watchState = initWatchState(collectWatchFiles())
  let sleepMs = if opts.debounceMs > 0: opts.debounceMs else: 500

  while true:
    sleep(sleepMs)

    when defined(macosx):
      if not isGuiAppRunning(result.appPath):
        result.diagnostics.add mkDiagnostic(
          result.appPath,
          1,
          1,
          gsInfo,
          "GUI app closed; stopping dev loop",
          "GUI_DEV_APP_EXIT"
        )
        break

    let files = collectWatchFiles()
    if not hasWatchChanges(watchState, files):
      continue

    let rerun = runGuiProject(entry, outDir, toRunOptions())
    result = rerun
    if rerun.diagnostics.hasErrors:
      # Keep watch loop alive so a follow-up fix can recover.
      discard
