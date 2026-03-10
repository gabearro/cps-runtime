## CLI wrapper for GUI DSL toolchain.

import std/[os, strutils]
import ../gui

type
  GuiCliCommand = enum
    gccCheck = "check"
    gccGenerate = "generate"
    gccBuild = "build"
    gccRun = "run"
    gccDev = "dev"
    gccCoverage = "coverage"
    gccParity = "parity"
    gccEmit = "emit"
    gccRunNim = "run-nim"

const UsageText = """
Usage:
  nimble gui -- check <entry.gui> [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- generate <entry.gui> [--out <dir>] [--configuration Debug|Release] [--clean] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- build <entry.gui> [--out <dir>] [--configuration Debug|Release] [--derived-data <dir>] [--clean] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- run <entry.gui> [--out <dir>] [--configuration Debug|Release] [--derived-data <dir>] [--clean] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- dev <entry.gui> [--out <dir>] [--configuration Debug|Release] [--debounce <ms>] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- coverage [--backend swiftui] [--dialect v3] [--typed-only]
  nimble gui -- parity <left.(gui|nim)> <right.(gui|nim)> [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- emit <entry.nim> --out <entry.gui> [--module <name>]
  nimble gui -- run-nim <entry.nim> [--out <dir>] [--configuration Debug|Release] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]"""

proc printDiagnostics(diagnostics: openArray[GuiDiagnostic]) =
  for d in diagnostics:
    echo d.formatDiagnostic()

type
  ParsedCli = object
    error: string
    cmd: GuiCliCommand
    entryFile: string
    secondEntryFile: string
    outDir: string
    outGuiFile: string
    configuration: GuiBuildConfiguration
    bridgeMode: GuiBridgeMode
    derivedDataPath: string
    nimBridgeEntry: string
    moduleName: string
    clean: bool
    verbose: bool
    watch: bool
    hotReload: bool
    debounceMs: int
    backend: GuiBackendKind
    targets: seq[GuiTargetPlatform]
    unsupportedPolicy: GuiUnsupportedPolicy
    dialect: GuiDialectVersion
    includePassthrough: bool

proc ok(p: ParsedCli): bool {.inline.} = p.error.len == 0

proc coreOpts(p: ParsedCli): GuiCoreOptions {.inline.} =
  GuiCoreOptions(
    backend: p.backend,
    targets: p.targets,
    unsupportedPolicy: p.unsupportedPolicy,
    dialect: p.dialect,
    verbose: p.verbose
  )

proc isConfigLiteral(value: string): bool {.inline.} =
  cmpIgnoreCase(value, "debug") == 0 or cmpIgnoreCase(value, "release") == 0

proc parseCommand(s: string): tuple[cmd: GuiCliCommand, ok: bool] =
  case s.toLowerAscii()
  of "check": (gccCheck, true)
  of "generate": (gccGenerate, true)
  of "build": (gccBuild, true)
  of "run": (gccRun, true)
  of "dev": (gccDev, true)
  of "coverage": (gccCoverage, true)
  of "parity": (gccParity, true)
  of "emit": (gccEmit, true)
  of "run-nim": (gccRunNim, true)
  else: (gccCheck, false)

proc nextArg(args: seq[string], i: var int): string =
  ## Consume the next argument if it exists and is not a flag.
  if i + 1 < args.len and not args[i + 1].startsWith("--"):
    inc i
    args[i]
  else:
    ""

proc parseTailArgs(tail: openArray[string], parsed: var ParsedCli, allowDerivedData: bool) =
  ## Parse optional trailing positional args: [outDir] [configuration] [derivedDataPath].
  var idx = 0
  if parsed.outDir == "out" and idx < tail.len:
    parsed.outDir = tail[idx]
    inc idx
  if idx < tail.len and isConfigLiteral(tail[idx]):
    parsed.configuration = parseBuildConfiguration(tail[idx])
    inc idx
  if allowDerivedData and parsed.derivedDataPath.len == 0 and idx < tail.len:
    parsed.derivedDataPath = tail[idx]
    inc idx
  if idx < tail.len:
    parsed.error = "unexpected argument: " & tail[idx]

proc parseCli(args: seq[string]): ParsedCli =
  result = ParsedCli(
    outDir: "out",
    configuration: gbcDebug,
    bridgeMode: gbmEmbeddedDylib,
    watch: true,
    hotReload: true,
    debounceMs: 500,
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3,
    includePassthrough: true
  )

  if args.len == 0:
    result.error = "no command specified"
    return

  let (cmd, cmdOk) = parseCommand(args[0])
  if not cmdOk:
    result.error = "unknown command: " & args[0]
    return
  result.cmd = cmd

  var i = 1
  var positional: seq[string] = @[]
  while i < args.len:
    let arg = args[i]
    case arg
    of "--out":
      let val = nextArg(args, i)
      if val.len > 0:
        if result.cmd == gccEmit: result.outGuiFile = val
        else: result.outDir = val
    of "--configuration":
      let val = nextArg(args, i)
      if val.len > 0: result.configuration = parseBuildConfiguration(val)
    of "--bridge-mode":
      let val = nextArg(args, i)
      if val.len > 0: result.bridgeMode = parseBridgeMode(val)
    of "--derived-data":
      let val = nextArg(args, i)
      if val.len > 0: result.derivedDataPath = val
    of "--nim-bridge":
      let val = nextArg(args, i)
      if val.len > 0: result.nimBridgeEntry = val
    of "--module":
      let val = nextArg(args, i)
      if val.len > 0: result.moduleName = val
    of "--backend":
      let val = nextArg(args, i)
      if val.len > 0: result.backend = parseBackendKind(val)
    of "--platform":
      let val = nextArg(args, i)
      if val.len > 0: result.targets = parseTargetPlatforms(val)
    of "--unsupported-policy":
      let val = nextArg(args, i)
      if val.len > 0: result.unsupportedPolicy = parseUnsupportedPolicy(val)
    of "--dialect":
      let val = nextArg(args, i)
      if val.len > 0: result.dialect = parseDialectVersion(val)
    of "--debounce":
      let val = nextArg(args, i)
      if val.len > 0:
        try: result.debounceMs = max(50, parseInt(val))
        except ValueError:
          result.error = "invalid debounce value: " & val
          return
    of "--typed-only": result.includePassthrough = false
    of "--include-passthrough": result.includePassthrough = true
    of "--clean": result.clean = true
    of "--verbose": result.verbose = true
    of "--no-watch": result.watch = false
    of "--no-hot-reload": result.hotReload = false
    else:
      if arg.startsWith("--"):
        result.error = "unknown flag: " & arg
        return
      positional.add arg
    inc i

  if result.cmd != gccCoverage and positional.len == 0:
    result.error = $result.cmd & " requires an entry file"
    return

  if positional.len > 0:
    result.entryFile = positional[0]

  let tail = if positional.len > 1: positional[1..^1] else: @[]

  case result.cmd
  of gccCheck:
    if tail.len > 0:
      result.error = "check takes exactly one entry file"

  of gccCoverage:
    if positional.len > 0:
      result.error = "coverage takes no positional arguments"

  of gccParity:
    if positional.len != 2:
      result.error = "parity requires exactly two entry files"
    else:
      result.secondEntryFile = positional[1]

  of gccEmit:
    var tidx = 0
    if result.outGuiFile.len == 0 and tidx < tail.len:
      result.outGuiFile = tail[tidx]
      inc tidx
    if tidx < tail.len:
      result.error = "unexpected argument: " & tail[tidx]
    elif result.outGuiFile.len == 0:
      result.error = "emit requires --out <file>"

  of gccRunNim, gccGenerate, gccDev:
    parseTailArgs(tail, result, allowDerivedData = false)

  of gccBuild, gccRun:
    parseTailArgs(tail, result, allowDerivedData = true)

proc toCheckOptions(parsed: ParsedCli): GuiCheckOptions {.inline.} =
  parsed.coreOpts

proc toGenerateOptions(parsed: ParsedCli): GuiGenerateOptions =
  GuiGenerateOptions(
    core: parsed.coreOpts,
    configuration: parsed.configuration,
    derivedDataPath: parsed.derivedDataPath,
    clean: parsed.clean,
    nimBridgeEntry: parsed.nimBridgeEntry,
    bridgeMode: parsed.bridgeMode
  )

proc toBuildOptions(parsed: ParsedCli): GuiBuildOptions {.inline.} =
  parsed.toGenerateOptions()

proc toRunOptions(parsed: ParsedCli): GuiRunOptions =
  GuiRunOptions(
    core: parsed.coreOpts,
    configuration: parsed.configuration,
    derivedDataPath: parsed.derivedDataPath,
    clean: parsed.clean,
    keepAppOpen: true,
    nimBridgeEntry: parsed.nimBridgeEntry,
    bridgeMode: parsed.bridgeMode
  )

proc toDevOptions(parsed: ParsedCli): GuiDevOptions =
  GuiDevOptions(
    core: parsed.coreOpts,
    configuration: parsed.configuration,
    outDir: parsed.outDir,
    watch: parsed.watch,
    hotReload: parsed.hotReload,
    nimBridgeEntry: parsed.nimBridgeEntry,
    debounceMs: parsed.debounceMs,
    bridgeMode: parsed.bridgeMode
  )

proc toEmitOptions(parsed: ParsedCli): GuiEmitOptions =
  GuiEmitOptions(
    moduleName: parsed.moduleName,
    emitDir: "",
    verbose: parsed.verbose,
    dialect: parsed.dialect
  )

proc safeTmpName(path: string): string =
  result = path
  for c in result.mitems:
    if c in {'/', '\\', ':', '.', ' '}: c = '_'
  if result.len == 0: result = "module"

proc compileEntrySignature(parsed: ParsedCli, entryPath: string): tuple[signature: string, diagnostics: seq[GuiDiagnostic]] =
  var sourcePath = entryPath
  if sourcePath.toLowerAscii().endsWith(".nim"):
    let emittedPath = normalizedPath(getTempDir() / ("gui_parity_" & safeTmpName(sourcePath) & ".gui"))
    let emitDiags = emitGuiFromNim(sourcePath, emittedPath, toEmitOptions(parsed))
    result.diagnostics.add emitDiags
    if emitDiags.hasErrors:
      return
    sourcePath = emittedPath

  let compileRes = compileGuiIr(sourcePath, parsed.coreOpts)
  result.diagnostics.add compileRes.diagnostics
  result.signature = compileRes.irSignature

proc runGuiCli*(args: seq[string]): int =
  let parsed = parseCli(args)
  if not parsed.ok:
    echo "error: " & parsed.error
    echo ""
    echo UsageText
    return 1

  case parsed.cmd
  of gccCheck:
    let diags = checkGuiProject(parsed.entryFile, toCheckOptions(parsed))
    printDiagnostics(diags)
    if diags.hasErrors: 1 else: 0

  of gccGenerate:
    let genRes = generateGuiProject(
      parsed.entryFile,
      parsed.outDir,
      toGenerateOptions(parsed)
    )

    printDiagnostics(genRes.diagnostics)
    if genRes.diagnostics.hasErrors:
      return 1

    echo "project: " & genRes.projectPath
    echo "scheme: " & genRes.scheme
    if genRes.bridge.enabled:
      echo "bridge: " & genRes.bridge.buildScript
    for path in genRes.generatedFiles:
      if parsed.verbose:
        echo "generated: " & path
    0

  of gccBuild:
    let buildRes = buildGuiProject(
      parsed.entryFile,
      parsed.outDir,
      toBuildOptions(parsed)
    )

    printDiagnostics(buildRes.diagnostics)
    if not buildRes.success or buildRes.diagnostics.hasErrors:
      return 1

    echo "project: " & buildRes.projectPath
    echo "scheme: " & buildRes.scheme
    echo "app: " & buildRes.appPath
    if buildRes.bridge.enabled:
      echo "bridge dylib: " & buildRes.bridge.dylibPath
    if parsed.verbose and buildRes.command.len > 0:
      echo "command: " & buildRes.command
    0

  of gccRun:
    let runRes = runGuiProject(
      parsed.entryFile,
      parsed.outDir,
      toRunOptions(parsed)
    )

    printDiagnostics(runRes.diagnostics)
    if not runRes.success or runRes.diagnostics.hasErrors:
      return 1

    echo "app: " & runRes.appPath
    if runRes.bridge.enabled:
      echo "bridge dylib: " & runRes.bridge.dylibPath
    if parsed.verbose and runRes.command.len > 0:
      echo "command: " & runRes.command
    0

  of gccDev:
    let devRes = devGuiProject(
      parsed.entryFile,
      parsed.outDir,
      toDevOptions(parsed)
    )

    printDiagnostics(devRes.diagnostics)
    if not devRes.success or devRes.diagnostics.hasErrors:
      return 1

    echo "app: " & devRes.appPath
    if devRes.bridge.enabled:
      echo "bridge dylib: " & devRes.bridge.dylibPath
    0

  of gccCoverage:
    let report = listSwiftUiCoverage(
      GuiCoverageOptions(
        backend: parsed.backend,
        dialect: parsed.dialect,
        includePassthrough: parsed.includePassthrough
      )
    )
    printDiagnostics(report.diagnostics)
    if report.diagnostics.hasErrors:
      return 1

    echo "backend: " & backendKindText(report.backend)
    echo "dialect: " & dialectVersionText(report.dialect)
    echo "typed views: " & $report.typedViewCount
    echo "typed modifiers: " & $report.typedModifierCount
    echo "passthrough: " & (if report.passthroughEnabled: "enabled" else: "disabled")
    if parsed.verbose:
      for symbol in report.symbols:
        if not report.passthroughEnabled and not symbol.typed:
          continue
        let targets =
          block:
            var parts: seq[string] = @[]
            if symbol.supportsMacOS:
              parts.add "macOS " & symbol.minMacOS
            if symbol.supportsIOS:
              parts.add "iOS " & symbol.minIOS
            if parts.len == 0: "n/a" else: parts.join(", ")
        echo symbol.kind & " " & symbol.name & " [" & targets & "]"
    0

  of gccParity:
    let left = compileEntrySignature(parsed, parsed.entryFile)
    let right = compileEntrySignature(parsed, parsed.secondEntryFile)
    let combinedDiags = left.diagnostics & right.diagnostics
    printDiagnostics(combinedDiags)
    if combinedDiags.hasErrors:
      return 1

    if left.signature == right.signature:
      echo "parity: ok"
      if parsed.verbose:
        echo "signature: " & left.signature
      return 0

    echo "parity: mismatch"
    if parsed.verbose:
      echo "left: " & parsed.entryFile
      echo "right: " & parsed.secondEntryFile
      echo "left signature:"
      echo left.signature
      echo "right signature:"
      echo right.signature
    1

  of gccEmit:
    let emitDiags = emitGuiFromNim(
      parsed.entryFile,
      parsed.outGuiFile,
      toEmitOptions(parsed)
    )

    printDiagnostics(emitDiags)
    if emitDiags.hasErrors:
      return 1

    echo "emitted: " & parsed.outGuiFile
    0

  of gccRunNim:
    let emittedPath = normalizedPath(parsed.outDir / "nim_inline_emitted.gui")
    let emitDiags = emitGuiFromNim(
      parsed.entryFile,
      emittedPath,
      toEmitOptions(parsed)
    )

    printDiagnostics(emitDiags)
    if emitDiags.hasErrors:
      return 1

    let runRes = runGuiProject(
      emittedPath,
      parsed.outDir,
      toRunOptions(parsed)
    )

    printDiagnostics(runRes.diagnostics)
    if not runRes.success or runRes.diagnostics.hasErrors:
      return 1

    echo "app: " & runRes.appPath
    0

when isMainModule:
  quit(runGuiCli(commandLineParams()))
