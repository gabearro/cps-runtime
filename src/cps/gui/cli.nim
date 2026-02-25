## CLI wrapper for GUI DSL toolchain.

import std/[os, strutils]
import ../gui

proc usage(): string =
  """
Usage:
  nimble gui -- check <entry.gui> [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- generate <entry.gui> [--out <dir>] [--configuration Debug|Release] [--clean] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- build <entry.gui> [--out <dir>] [--configuration Debug|Release] [--derived-data <dir>] [--clean] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- run <entry.gui> [--out <dir>] [--configuration Debug|Release] [--derived-data <dir>] [--clean] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- dev <entry.gui> [--out <dir>] [--configuration Debug|Release] [--debounce <ms>] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- coverage [--backend swiftui] [--dialect v3] [--typed-only]
  nimble gui -- parity <left.(gui|nim)> <right.(gui|nim)> [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
  nimble gui -- emit <entry.nim> --out <entry.gui> [--module <name>]
  nimble gui -- run-nim <entry.nim> [--out <dir>] [--configuration Debug|Release] [--verbose] [--nim-bridge <path>] [--bridge-mode embedded|none] [--backend swiftui] [--platform macos,ios] [--unsupported-policy strict|warn-passthrough] [--dialect v3]
""".strip()

proc printDiagnostics(diagnostics: openArray[GuiDiagnostic]) =
  for d in diagnostics:
    echo d.formatDiagnostic()

type
  ParsedCli = object
    ok: bool
    cmd: string
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

proc isConfigLiteral(value: string): bool {.inline.} =
  let lowered = value.toLowerAscii()
  lowered == "debug" or lowered == "release"

proc parseCli(args: seq[string]): ParsedCli =
  result.ok = false
  result.outDir = "out"
  result.outGuiFile = ""
  result.configuration = gbcDebug
  result.bridgeMode = gbmEmbeddedDylib
  result.watch = true
  result.hotReload = true
  result.debounceMs = 500
  result.backend = gbkSwiftUI
  result.targets = defaultTargets()
  result.unsupportedPolicy = gupWarnPassthrough
  result.dialect = gdv3
  result.includePassthrough = true

  if args.len == 0:
    return

  result.cmd = args[0].toLowerAscii()
  if result.cmd notin ["check", "generate", "build", "run", "dev", "coverage", "parity", "emit", "run-nim"]:
    return

  var i = 1
  var positional: seq[string] = @[]
  while i < args.len:
    let arg = args[i]
    if arg == "--out":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        if result.cmd == "emit":
          result.outGuiFile = args[i]
        else:
          result.outDir = args[i]
    elif arg == "--configuration":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.configuration = parseBuildConfiguration(args[i])
    elif arg == "--bridge-mode":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.bridgeMode = parseBridgeMode(args[i])
    elif arg == "--derived-data":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.derivedDataPath = args[i]
    elif arg == "--nim-bridge":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.nimBridgeEntry = args[i]
    elif arg == "--module":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.moduleName = args[i]
    elif arg == "--backend":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.backend = parseBackendKind(args[i])
    elif arg == "--platform":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.targets = parseTargetPlatforms(args[i])
    elif arg == "--unsupported-policy":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.unsupportedPolicy = parseUnsupportedPolicy(args[i])
    elif arg == "--dialect":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        result.dialect = parseDialectVersion(args[i])
    elif arg == "--debounce":
      if i + 1 < args.len and not args[i + 1].startsWith("--"):
        inc i
        try:
          result.debounceMs = max(50, parseInt(args[i]))
        except ValueError:
          return
    elif arg == "--typed-only":
      result.includePassthrough = false
    elif arg == "--include-passthrough":
      result.includePassthrough = true
    elif arg == "--clean":
      result.clean = true
    elif arg == "--verbose":
      result.verbose = true
    elif arg == "--no-watch":
      result.watch = false
    elif arg == "--no-hot-reload":
      result.hotReload = false
    elif arg.startsWith("--"):
      return
    else:
      positional.add arg
    inc i

  if result.cmd != "coverage" and positional.len == 0:
    return

  if positional.len > 0:
    result.entryFile = positional[0]

  case result.cmd
  of "check":
    if positional.len > 1:
      return

  of "coverage":
    if positional.len > 0:
      return

  of "parity":
    if positional.len != 2:
      return
    result.secondEntryFile = positional[1]

  of "emit":
    var tail: seq[string] = @[]
    for idx in 1 ..< positional.len:
      tail.add positional[idx]

    if result.outGuiFile.len == 0 and tail.len > 0:
      result.outGuiFile = tail[0]
      tail.delete(0)

    if tail.len > 0:
      return

    if result.outGuiFile.len == 0:
      return

  of "run-nim":
    var tail: seq[string] = @[]
    for idx in 1 ..< positional.len:
      tail.add positional[idx]

    if result.outDir == "out" and tail.len > 0:
      result.outDir = tail[0]
      tail.delete(0)

    if tail.len > 0 and isConfigLiteral(tail[0]):
      result.configuration = parseBuildConfiguration(tail[0])
      tail.delete(0)

    if tail.len > 0:
      return

  else:
    var tail: seq[string] = @[]
    for idx in 1 ..< positional.len:
      tail.add positional[idx]

    if result.outDir == "out" and tail.len > 0:
      result.outDir = tail[0]
      tail.delete(0)

    if tail.len > 0 and isConfigLiteral(tail[0]):
      result.configuration = parseBuildConfiguration(tail[0])
      tail.delete(0)

    if result.cmd in ["build", "run"] and result.derivedDataPath.len == 0 and tail.len > 0:
      result.derivedDataPath = tail[0]
      tail.delete(0)

    if tail.len > 0:
      return

  result.ok = true

proc toCheckOptions(parsed: ParsedCli): GuiCheckOptions =
  GuiCheckOptions(
    backend: parsed.backend,
    targets: parsed.targets,
    unsupportedPolicy: parsed.unsupportedPolicy,
    dialect: parsed.dialect,
    verbose: parsed.verbose
  )

proc toGenerateOptions(parsed: ParsedCli): GuiGenerateOptions =
  GuiGenerateOptions(
    configuration: parsed.configuration,
    derivedDataPath: parsed.derivedDataPath,
    clean: parsed.clean,
    verbose: parsed.verbose,
    nimBridgeEntry: parsed.nimBridgeEntry,
    bridgeMode: parsed.bridgeMode,
    backend: parsed.backend,
    targets: parsed.targets,
    unsupportedPolicy: parsed.unsupportedPolicy,
    dialect: parsed.dialect
  )

proc toBuildOptions(parsed: ParsedCli): GuiBuildOptions =
  GuiBuildOptions(
    configuration: parsed.configuration,
    derivedDataPath: parsed.derivedDataPath,
    clean: parsed.clean,
    verbose: parsed.verbose,
    nimBridgeEntry: parsed.nimBridgeEntry,
    bridgeMode: parsed.bridgeMode,
    backend: parsed.backend,
    targets: parsed.targets,
    unsupportedPolicy: parsed.unsupportedPolicy,
    dialect: parsed.dialect
  )

proc toRunOptions(parsed: ParsedCli): GuiRunOptions =
  GuiRunOptions(
    configuration: parsed.configuration,
    derivedDataPath: parsed.derivedDataPath,
    clean: parsed.clean,
    verbose: parsed.verbose,
    keepAppOpen: true,
    nimBridgeEntry: parsed.nimBridgeEntry,
    bridgeMode: parsed.bridgeMode,
    backend: parsed.backend,
    targets: parsed.targets,
    unsupportedPolicy: parsed.unsupportedPolicy,
    dialect: parsed.dialect
  )

proc toDevOptions(parsed: ParsedCli): GuiDevOptions =
  GuiDevOptions(
    configuration: parsed.configuration,
    outDir: parsed.outDir,
    watch: parsed.watch,
    hotReload: parsed.hotReload,
    verbose: parsed.verbose,
    nimBridgeEntry: parsed.nimBridgeEntry,
    debounceMs: parsed.debounceMs,
    bridgeMode: parsed.bridgeMode,
    backend: parsed.backend,
    targets: parsed.targets,
    unsupportedPolicy: parsed.unsupportedPolicy,
    dialect: parsed.dialect
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
  for i in 0 ..< result.len:
    if result[i] in {'/', '\\', ':', '.', ' '}:
      result[i] = '_'
  if result.len == 0:
    result = "module"

proc compileEntrySignature(parsed: ParsedCli, entryPath: string): tuple[signature: string, diagnostics: seq[GuiDiagnostic]] =
  var sourcePath = entryPath
  if sourcePath.toLowerAscii().endsWith(".nim"):
    let emittedPath = normalizedPath(getTempDir() / ("gui_parity_" & safeTmpName(sourcePath) & ".gui"))
    let emitDiags = emitGuiFromNim(sourcePath, emittedPath, toEmitOptions(parsed))
    result.diagnostics.add emitDiags
    if emitDiags.hasErrors:
      return
    sourcePath = emittedPath

  let compileRes = compileGuiIr(
    sourcePath,
    GuiCompileOptions(
      backend: parsed.backend,
      targets: parsed.targets,
      unsupportedPolicy: parsed.unsupportedPolicy,
      dialect: parsed.dialect,
      verbose: parsed.verbose
    )
  )
  result.diagnostics.add compileRes.diagnostics
  result.signature = compileRes.irSignature

proc runGuiCli*(args: seq[string]): int =
  let parsed = parseCli(args)
  if not parsed.ok:
    echo usage()
    return 1

  case parsed.cmd
  of "check":
    let diags = checkGuiProject(parsed.entryFile, toCheckOptions(parsed))
    printDiagnostics(diags)
    if diags.hasErrors: 1 else: 0

  of "generate":
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
    if genRes.bridgeEnabled:
      echo "bridge: " & genRes.bridgeBuildScript
    for path in genRes.generatedFiles:
      if parsed.verbose:
        echo "generated: " & path
    0

  of "build":
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
    if buildRes.bridgeEnabled:
      echo "bridge dylib: " & buildRes.bridgeDylibPath
    if parsed.verbose and buildRes.command.len > 0:
      echo "command: " & buildRes.command
    0

  of "run":
    let runRes = runGuiProject(
      parsed.entryFile,
      parsed.outDir,
      toRunOptions(parsed)
    )

    printDiagnostics(runRes.diagnostics)
    if not runRes.success or runRes.diagnostics.hasErrors:
      return 1

    echo "app: " & runRes.appPath
    if runRes.bridgeEnabled:
      echo "bridge dylib: " & runRes.bridgeDylibPath
    if parsed.verbose and runRes.command.len > 0:
      echo "command: " & runRes.command
    0

  of "dev":
    let devRes = devGuiProject(
      parsed.entryFile,
      parsed.outDir,
      toDevOptions(parsed)
    )

    printDiagnostics(devRes.diagnostics)
    if not devRes.success or devRes.diagnostics.hasErrors:
      return 1

    echo "app: " & devRes.appPath
    if devRes.bridgeEnabled:
      echo "bridge dylib: " & devRes.bridgeDylibPath
    0

  of "coverage":
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

  of "parity":
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

  of "emit":
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

  of "run-nim":
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

  else:
    echo usage()
    1

when isMainModule:
  quit(runGuiCli(commandLineParams()))
