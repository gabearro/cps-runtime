## GUI DSL types shared across lexer/parser/sema/codegen/runtime orchestration.

import std/strutils

type
  GuiSeverity* = enum
    gsError,
    gsWarning,
    gsInfo

  GuiBackendKind* = enum
    gbkSwiftUI

  GuiTargetPlatform* = enum
    gtpMacOS,
    gtpIOS

  GuiUnsupportedPolicy* = enum
    gupStrict,
    gupWarnPassthrough

  GuiDialectVersion* = enum
    gdv3

  GuiActionOwner* = enum
    gaoSwift,
    gaoNim,
    gaoBoth

  GuiBridgeMode* = enum
    gbmNone,
    gbmEmbeddedDylib

  GuiBuildConfiguration* = enum
    gbcDebug,
    gbcRelease

  # -- Source location --

  GuiSourcePos* = object
    file*: string
    line*: int
    col*: int

  GuiSourceRange* = object
    start*: GuiSourcePos
    stop*: GuiSourcePos

  # -- Diagnostics --

  GuiDiagnostic* = object
    file*: string
    line*: int
    col*: int
    severity*: GuiSeverity
    message*: string
    code*: string

  GuiBridgeDiagnostic* = object
    severity*: GuiSeverity
    message*: string
    code*: string
    detail*: string

  GuiAvailabilityDiagnostic* = object
    symbol*: string
    platform*: GuiTargetPlatform
    message*: string
    code*: string

  GuiParityDiagnostic* = object
    left*: string
    right*: string
    message*: string
    code*: string

  # -- Composable option groups --

  GuiCoreOptions* = object
    ## Shared compilation/analysis options present on every command.
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion
    verbose*: bool

  GuiCheckOptions* = GuiCoreOptions
    ## Check and compile use the same option set.

  GuiCompileOptions* = GuiCoreOptions

  GuiGenerateOptions* = object
    core*: GuiCoreOptions
    configuration*: GuiBuildConfiguration
    derivedDataPath*: string
    clean*: bool
    nimBridgeEntry*: string
    bridgeMode*: GuiBridgeMode

  GuiBuildOptions* = GuiGenerateOptions
    ## Build and generate share identical options.

  GuiRunOptions* = object
    core*: GuiCoreOptions
    configuration*: GuiBuildConfiguration
    derivedDataPath*: string
    clean*: bool
    keepAppOpen*: bool
    nimBridgeEntry*: string
    bridgeMode*: GuiBridgeMode

  GuiDevOptions* = object
    core*: GuiCoreOptions
    configuration*: GuiBuildConfiguration
    outDir*: string
    watch*: bool
    hotReload*: bool
    nimBridgeEntry*: string
    debounceMs*: int
    bridgeMode*: GuiBridgeMode

  GuiEmitOptions* = object
    moduleName*: string
    emitDir*: string
    verbose*: bool
    dialect*: GuiDialectVersion

  GuiCoverageOptions* = object
    backend*: GuiBackendKind
    dialect*: GuiDialectVersion
    includePassthrough*: bool

  GuiCoverageSymbol* = object
    name*: string
    kind*: string
    supportsMacOS*: bool
    supportsIOS*: bool
    minMacOS*: string
    minIOS*: string
    typed*: bool

  GuiCoverageReport* = object
    backend*: GuiBackendKind
    dialect*: GuiDialectVersion
    typedViewCount*: int
    typedModifierCount*: int
    passthroughEnabled*: bool
    symbols*: seq[GuiCoverageSymbol]
    diagnostics*: seq[GuiDiagnostic]

  # -- Bridge metadata (shared across result types) --

  GuiBridgeInfo* = object
    enabled*: bool
    buildScript*: string
    entry*: string
    dylibPath*: string

  # -- Result types --

  GuiCompileResult* = object
    appName*: string
    loadedFiles*: seq[string]
    irSignature*: string
    diagnostics*: seq[GuiDiagnostic]

  GuiGenerateResult* = object
    projectPath*: string
    scheme*: string
    generatedFiles*: seq[string]
    diagnostics*: seq[GuiDiagnostic]
    bridge*: GuiBridgeInfo

  GuiBuildResult* = object
    success*: bool
    projectPath*: string
    scheme*: string
    appPath*: string
    command*: string
    diagnostics*: seq[GuiDiagnostic]
    bridge*: GuiBridgeInfo

  GuiRunResult* = object
    success*: bool
    appPath*: string
    command*: string
    diagnostics*: seq[GuiDiagnostic]
    bridge*: GuiBridgeInfo

# -- Forwarding templates: transparent access to core fields through composition --

template backend*(opts: GuiGenerateOptions | GuiRunOptions | GuiDevOptions): GuiBackendKind =
  opts.core.backend

template targets*(opts: GuiGenerateOptions | GuiRunOptions | GuiDevOptions): seq[GuiTargetPlatform] =
  opts.core.targets

template unsupportedPolicy*(opts: GuiGenerateOptions | GuiRunOptions | GuiDevOptions): GuiUnsupportedPolicy =
  opts.core.unsupportedPolicy

template dialect*(opts: GuiGenerateOptions | GuiRunOptions | GuiDevOptions): GuiDialectVersion =
  opts.core.dialect

template verbose*(opts: GuiGenerateOptions | GuiRunOptions | GuiDevOptions): bool =
  opts.core.verbose

# -- Source helpers --

proc sourcePos*(file: string, line: int, col: int): GuiSourcePos {.inline.} =
  GuiSourcePos(file: file, line: line, col: col)

proc sourceRange*(
  file: string,
  startLine: int,
  startCol: int,
  endLine: int,
  endCol: int
): GuiSourceRange {.inline.} =
  GuiSourceRange(
    start: sourcePos(file, startLine, startCol),
    stop: sourcePos(file, endLine, endCol)
  )

proc noRange*(file = ""): GuiSourceRange {.inline.} =
  sourceRange(file, 1, 1, 1, 1)

proc rangeSpan*(a, b: GuiSourceRange): GuiSourceRange {.inline.} =
  ## Constructs a range from `a`'s start to `b`'s stop.
  sourceRange(a.start.file, a.start.line, a.start.col, b.stop.line, b.stop.col)

# -- Diagnostic helpers --

proc mkDiagnostic*(
  file: string,
  line: int,
  col: int,
  severity: GuiSeverity,
  message: string,
  code: string
): GuiDiagnostic {.inline.} =
  GuiDiagnostic(
    file: file,
    line: line,
    col: col,
    severity: severity,
    message: message,
    code: code
  )

proc mkDiagnostic*(
  range: GuiSourceRange,
  severity: GuiSeverity,
  message: string,
  code: string
): GuiDiagnostic {.inline.} =
  mkDiagnostic(
    range.start.file,
    range.start.line,
    range.start.col,
    severity,
    message,
    code
  )

proc isError*(d: GuiDiagnostic): bool {.inline.} =
  d.severity == gsError

proc hasErrors*(diagnostics: openArray[GuiDiagnostic]): bool {.inline.} =
  for d in diagnostics:
    if d.isError:
      return true
  false

proc severityText*(s: GuiSeverity): string {.inline.} =
  case s
  of gsError: "error"
  of gsWarning: "warning"
  of gsInfo: "info"

proc formatDiagnostic*(d: GuiDiagnostic): string =
  let fileText = if d.file.len > 0: d.file else: "<unknown>"
  result.add fileText
  result.add ':'
  result.addInt d.line
  result.add ':'
  result.addInt d.col
  result.add ": "
  result.add severityText(d.severity)
  if d.code.len > 0:
    result.add " ["
    result.add d.code
    result.add ']'
  result.add ": "
  result.add d.message

# -- Defaults --

proc defaultTargets*(): seq[GuiTargetPlatform] {.inline.} =
  @[gtpMacOS]

proc defaultCoreOptions*(): GuiCoreOptions {.inline.} =
  GuiCoreOptions(
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3,
    verbose: false
  )

proc defaultCheckOptions*(): GuiCheckOptions {.inline.} =
  defaultCoreOptions()

proc defaultCompileOptions*(): GuiCompileOptions {.inline.} =
  defaultCoreOptions()

proc defaultCoverageOptions*(): GuiCoverageOptions {.inline.} =
  GuiCoverageOptions(
    backend: gbkSwiftUI,
    dialect: gdv3,
    includePassthrough: true
  )

proc defaultGenerateOptions*(): GuiGenerateOptions =
  GuiGenerateOptions(
    core: defaultCoreOptions(),
    configuration: gbcDebug,
    bridgeMode: gbmEmbeddedDylib
  )

proc defaultBuildOptions*(): GuiBuildOptions {.inline.} =
  defaultGenerateOptions()

proc defaultRunOptions*(): GuiRunOptions =
  GuiRunOptions(
    core: defaultCoreOptions(),
    configuration: gbcDebug,
    keepAppOpen: true,
    bridgeMode: gbmEmbeddedDylib
  )

proc defaultDevOptions*(): GuiDevOptions =
  GuiDevOptions(
    core: defaultCoreOptions(),
    configuration: gbcDebug,
    outDir: "out",
    watch: true,
    hotReload: true,
    debounceMs: 500,
    bridgeMode: gbmEmbeddedDylib
  )

proc defaultEmitOptions*(): GuiEmitOptions {.inline.} =
  GuiEmitOptions(
    dialect: gdv3
  )

# -- Type conversion helpers --

proc toBuildOptions*(opts: GuiRunOptions): GuiBuildOptions {.inline.} =
  GuiBuildOptions(
    core: opts.core,
    configuration: opts.configuration,
    derivedDataPath: opts.derivedDataPath,
    clean: opts.clean,
    nimBridgeEntry: opts.nimBridgeEntry,
    bridgeMode: opts.bridgeMode
  )

proc toRunOptions*(opts: GuiDevOptions): GuiRunOptions {.inline.} =
  GuiRunOptions(
    core: opts.core,
    configuration: opts.configuration,
    keepAppOpen: true,
    nimBridgeEntry: opts.nimBridgeEntry,
    bridgeMode: opts.bridgeMode
  )

# -- Enum text/parse --

proc parseBuildConfiguration*(value: string): GuiBuildConfiguration {.inline.} =
  case value.toLowerAscii()
  of "release": gbcRelease
  else: gbcDebug

proc buildConfigurationText*(cfg: GuiBuildConfiguration): string {.inline.} =
  case cfg
  of gbcDebug: "Debug"
  of gbcRelease: "Release"

proc actionOwnerText*(owner: GuiActionOwner): string {.inline.} =
  case owner
  of gaoSwift: "swift"
  of gaoNim: "nim"
  of gaoBoth: "both"

proc parseActionOwner*(value: string): GuiActionOwner {.inline.} =
  case value.toLowerAscii()
  of "nim": gaoNim
  of "both": gaoBoth
  else: gaoSwift

proc bridgeModeText*(mode: GuiBridgeMode): string {.inline.} =
  case mode
  of gbmNone: "none"
  of gbmEmbeddedDylib: "embedded"

proc parseBridgeMode*(value: string): GuiBridgeMode {.inline.} =
  case value.toLowerAscii()
  of "none": gbmNone
  else: gbmEmbeddedDylib

proc backendKindText*(kind: GuiBackendKind): string {.inline.} =
  case kind
  of gbkSwiftUI: "swiftui"

proc parseBackendKind*(value: string): GuiBackendKind {.inline.} =
  case value.toLowerAscii()
  of "swiftui": gbkSwiftUI
  else: gbkSwiftUI

proc targetPlatformText*(platform: GuiTargetPlatform): string {.inline.} =
  case platform
  of gtpMacOS: "macos"
  of gtpIOS: "ios"

proc parseTargetPlatform*(value: string): GuiTargetPlatform {.inline.} =
  case value.toLowerAscii()
  of "ios", "iphoneos", "iphonesimulator": gtpIOS
  else: gtpMacOS

proc parseTargetPlatforms*(value: string): seq[GuiTargetPlatform] =
  if value.len == 0:
    return defaultTargets()
  for chunk in value.split(','):
    let item = chunk.strip()
    if item.len == 0:
      continue
    let parsed = parseTargetPlatform(item)
    if parsed notin result:
      result.add parsed
  if result.len == 0:
    result = defaultTargets()

proc targetPlatformsText*(targets: openArray[GuiTargetPlatform]): string =
  for i, target in targets:
    if i > 0: result.add ','
    result.add targetPlatformText(target)

proc unsupportedPolicyText*(policy: GuiUnsupportedPolicy): string {.inline.} =
  case policy
  of gupStrict: "strict"
  of gupWarnPassthrough: "warn-passthrough"

proc parseUnsupportedPolicy*(value: string): GuiUnsupportedPolicy {.inline.} =
  case value.toLowerAscii()
  of "strict": gupStrict
  else: gupWarnPassthrough

proc dialectVersionText*(dialect: GuiDialectVersion): string {.inline.} =
  case dialect
  of gdv3: "v3"

proc parseDialectVersion*(value: string): GuiDialectVersion {.inline.} =
  case value.toLowerAscii()
  of "v3", "3": gdv3
  else: gdv3
