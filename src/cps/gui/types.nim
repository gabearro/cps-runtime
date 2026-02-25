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

  GuiSourcePos* = object
    file*: string
    line*: int
    col*: int

  GuiSourceRange* = object
    start*: GuiSourcePos
    stop*: GuiSourcePos

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

  GuiBuildConfiguration* = enum
    gbcDebug,
    gbcRelease

  GuiCheckOptions* = object
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion
    verbose*: bool

  GuiCompileOptions* = object
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion
    verbose*: bool

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

  GuiCompileResult* = object
    appName*: string
    loadedFiles*: seq[string]
    irSignature*: string
    diagnostics*: seq[GuiDiagnostic]

  GuiGenerateOptions* = object
    configuration*: GuiBuildConfiguration
    derivedDataPath*: string
    clean*: bool
    verbose*: bool
    nimBridgeEntry*: string
    bridgeMode*: GuiBridgeMode
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion

  GuiBuildOptions* = object
    configuration*: GuiBuildConfiguration
    derivedDataPath*: string
    clean*: bool
    verbose*: bool
    nimBridgeEntry*: string
    bridgeMode*: GuiBridgeMode
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion

  GuiRunOptions* = object
    configuration*: GuiBuildConfiguration
    derivedDataPath*: string
    clean*: bool
    verbose*: bool
    keepAppOpen*: bool
    nimBridgeEntry*: string
    bridgeMode*: GuiBridgeMode
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion

  GuiDevOptions* = object
    configuration*: GuiBuildConfiguration
    outDir*: string
    watch*: bool
    hotReload*: bool
    verbose*: bool
    nimBridgeEntry*: string
    debounceMs*: int
    bridgeMode*: GuiBridgeMode
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy
    dialect*: GuiDialectVersion

  GuiEmitOptions* = object
    moduleName*: string
    emitDir*: string
    verbose*: bool
    dialect*: GuiDialectVersion

  GuiGenerateResult* = object
    projectPath*: string
    scheme*: string
    generatedFiles*: seq[string]
    diagnostics*: seq[GuiDiagnostic]
    bridgeEnabled*: bool
    bridgeBuildScript*: string
    bridgeEntry*: string
    bridgeDylibPath*: string

  GuiBuildResult* = object
    success*: bool
    projectPath*: string
    scheme*: string
    appPath*: string
    command*: string
    diagnostics*: seq[GuiDiagnostic]
    bridgeEnabled*: bool
    bridgeBuildScript*: string
    bridgeEntry*: string
    bridgeDylibPath*: string

  GuiRunResult* = object
    success*: bool
    appPath*: string
    command*: string
    diagnostics*: seq[GuiDiagnostic]
    bridgeEnabled*: bool
    bridgeDylibPath*: string

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

proc hasErrors*(diagnostics: openArray[GuiDiagnostic]): bool =
  for d in diagnostics:
    if d.isError:
      return true
  false

proc severityText*(s: GuiSeverity): string =
  case s
  of gsError:
    "error"
  of gsWarning:
    "warning"
  of gsInfo:
    "info"

proc formatDiagnostic*(d: GuiDiagnostic): string =
  let fileText = if d.file.len > 0: d.file else: "<unknown>"
  let codeText = if d.code.len > 0: " [" & d.code & "]" else: ""
  fileText & ":" & $d.line & ":" & $d.col & ": " &
    severityText(d.severity) & codeText & ": " & d.message

proc defaultTargets*(): seq[GuiTargetPlatform] =
  @[gtpMacOS]

proc defaultCheckOptions*(): GuiCheckOptions =
  GuiCheckOptions(
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3,
    verbose: false
  )

proc defaultCompileOptions*(): GuiCompileOptions =
  GuiCompileOptions(
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3,
    verbose: false
  )

proc defaultCoverageOptions*(): GuiCoverageOptions =
  GuiCoverageOptions(
    backend: gbkSwiftUI,
    dialect: gdv3,
    includePassthrough: true
  )

proc defaultGenerateOptions*(): GuiGenerateOptions =
  GuiGenerateOptions(
    configuration: gbcDebug,
    derivedDataPath: "",
    clean: false,
    verbose: false,
    nimBridgeEntry: "",
    bridgeMode: gbmEmbeddedDylib,
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3
  )

proc defaultBuildOptions*(): GuiBuildOptions =
  GuiBuildOptions(
    configuration: gbcDebug,
    derivedDataPath: "",
    clean: false,
    verbose: false,
    nimBridgeEntry: "",
    bridgeMode: gbmEmbeddedDylib,
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3
  )

proc defaultRunOptions*(): GuiRunOptions =
  GuiRunOptions(
    configuration: gbcDebug,
    derivedDataPath: "",
    clean: false,
    verbose: false,
    keepAppOpen: true,
    nimBridgeEntry: "",
    bridgeMode: gbmEmbeddedDylib,
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3
  )

proc defaultDevOptions*(): GuiDevOptions =
  GuiDevOptions(
    configuration: gbcDebug,
    outDir: "out",
    watch: true,
    hotReload: true,
    verbose: false,
    nimBridgeEntry: "",
    debounceMs: 500,
    bridgeMode: gbmEmbeddedDylib,
    backend: gbkSwiftUI,
    targets: defaultTargets(),
    unsupportedPolicy: gupWarnPassthrough,
    dialect: gdv3
  )

proc defaultEmitOptions*(): GuiEmitOptions =
  GuiEmitOptions(
    moduleName: "",
    emitDir: "",
    verbose: false,
    dialect: gdv3
  )

proc parseBuildConfiguration*(value: string): GuiBuildConfiguration =
  case value.toLowerAscii()
  of "release":
    gbcRelease
  else:
    gbcDebug

proc buildConfigurationText*(cfg: GuiBuildConfiguration): string =
  case cfg
  of gbcDebug:
    "Debug"
  of gbcRelease:
    "Release"

proc actionOwnerText*(owner: GuiActionOwner): string =
  case owner
  of gaoSwift:
    "swift"
  of gaoNim:
    "nim"
  of gaoBoth:
    "both"

proc parseActionOwner*(value: string): GuiActionOwner =
  case value.toLowerAscii()
  of "nim":
    gaoNim
  of "both":
    gaoBoth
  else:
    gaoSwift

proc bridgeModeText*(mode: GuiBridgeMode): string =
  case mode
  of gbmNone:
    "none"
  of gbmEmbeddedDylib:
    "embedded"

proc parseBridgeMode*(value: string): GuiBridgeMode =
  case value.toLowerAscii()
  of "none":
    gbmNone
  else:
    gbmEmbeddedDylib

proc backendKindText*(kind: GuiBackendKind): string =
  case kind
  of gbkSwiftUI:
    "swiftui"

proc parseBackendKind*(value: string): GuiBackendKind =
  case value.toLowerAscii()
  of "swiftui":
    gbkSwiftUI
  else:
    gbkSwiftUI

proc targetPlatformText*(platform: GuiTargetPlatform): string =
  case platform
  of gtpMacOS:
    "macos"
  of gtpIOS:
    "ios"

proc parseTargetPlatform*(value: string): GuiTargetPlatform =
  case value.toLowerAscii()
  of "ios", "iphoneos", "iphonesimulator":
    gtpIOS
  else:
    gtpMacOS

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
  var parts: seq[string] = @[]
  for target in targets:
    parts.add targetPlatformText(target)
  parts.join(",")

proc unsupportedPolicyText*(policy: GuiUnsupportedPolicy): string =
  case policy
  of gupStrict:
    "strict"
  of gupWarnPassthrough:
    "warn-passthrough"

proc parseUnsupportedPolicy*(value: string): GuiUnsupportedPolicy =
  case value.toLowerAscii()
  of "strict":
    gupStrict
  else:
    gupWarnPassthrough

proc dialectVersionText*(dialect: GuiDialectVersion): string =
  case dialect
  of gdv3:
    "v3"

proc parseDialectVersion*(value: string): GuiDialectVersion =
  case value.toLowerAscii()
  of "v3", "3":
    gdv3
  else:
    gdv3
