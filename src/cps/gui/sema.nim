## GUI DSL semantic checks and light typing.

import std/[tables, sets, strutils]
import ./types
import ./ast
import ./backend/availability

const
  builtinTypesArray = ["Int", "Double", "String", "Bool", "Color", "Any", "Void", "Array", "Dictionary", "Tuple", "Set", "Result", "Range"]

  coreModifierAllowlistArray = [
    # Layout
    "padding", "frame", "fixedSize", "aspectRatio", "layoutPriority", "zIndex",
    "offset", "scaleEffect", "rotationEffect", "ignoresSafeArea",
    "safeAreaInset", "containerRelativeFrame",
    # Appearance
    "background", "foregroundColor", "foregroundStyle", "backgroundStyle",
    "font", "fontWeight", "multilineTextAlignment", "lineLimit", "minimumScaleFactor",
    "opacity", "hidden", "tint", "border", "cornerRadius", "shadow",
    "clipShape", "clipped", "overlay", "mask", "stroke", "strokeBorder",
    # Visual effects
    "blur", "brightness", "contrast", "saturation", "grayscale",
    "hueRotation", "colorMultiply", "colorInvert", "redacted", "unredacted",
    # Animation
    "animation", "transition", "contentTransition",
    # Accessibility
    "accessibilityLabel", "accessibilityHint", "accessibilityValue",
    "accessibilityElement", "accessibilityAddTraits", "accessibilityRemoveTraits",
    "accessibilityIdentifier", "accessibilityInputLabels",
    "accessibilityAction", "accessibilityRepresentation",
    "accessibilityHeading", "accessibilityHidden", "accessibilitySortPriority",
    "help",
    # Gestures & interaction
    "onTapGesture", "onLongPressGesture", "onDrag", "onDrop",
    "gesture", "highPriorityGesture", "simultaneousGesture",
    "onAppear", "onDisappear", "onChange", "onSubmit", "onKeyPress",
    "disabled", "allowsHitTesting", "focusable", "focused",
    "sensoryFeedback",
    # Matched geometry
    "matchedGeometryEffect",
    # Presentation
    "sheet", "fullScreenCover", "alert", "confirmationDialog", "popover",
    "interactiveDismissDisabled", "presentationDetents", "presentationDragIndicator",
    # Style
    "buttonStyle", "textFieldStyle", "toggleStyle", "listStyle", "pickerStyle",
    "scrollContentBackground", "preferredColorScheme", "controlSize",
    # Navigation
    "searchable", "toolbar", "navigationTitle", "navigationSubtitle",
    "toolbarBackground", "toolbarColorScheme", "toolbarTitleDisplayMode",
    "navigationSplitViewStyle", "navigationDestination",
    # List modifiers
    "labelsHidden", "listRowSeparator", "listRowSeparatorTint", "listRowInsets", "listRowBackground",
    "swipeActions", "contextMenu", "badge",
    "onDelete", "onMove", "deleteDisabled", "moveDisabled",
    # Scroll
    "scrollIndicators", "scrollDismissesKeyboard",
    "scrollTargetBehavior", "scrollPosition",
    # Tags & selection
    "tag", "textSelection",
    # Async
    "task", "refreshable",
    # Files
    "fileImporter", "fileExporter",
    # Keyboard
    "keyboardShortcut",
    # Grid
    "gridCellColumns", "gridColumnAlignment", "gridCellAnchor",
    # Environment
    "environment",
    # Additional commonly used modifiers
    "id", "tabItem", "onReceive",
    "hoverEffect", "onHover", "onContinuousHover",
    "navigationBarBackButtonHidden", "navigationBarTitleDisplayMode",
    "compositingGroup", "drawingGroup",
    "allowsTightening", "truncationMode", "textCase",
    "autocapitalization", "disableAutocorrection",
    "keyboardType", "submitLabel", "textContentType",
    "scrollTargetLayout",
    "contentShape", "focusedValue", "defaultFocus",
    "digitalCrownRotation", "handlesExternalEvents",
    "inspector",
    "navigationSplitViewColumnWidth",
    "renameAction", "focusScope",
    "defaultAppStorage",
    "statusBarHidden", "persistentSystemOverlays",
    "defersSystemGestures",
    "dynamicTypeSize", "imageScale",
    "symbolVariant", "symbolRenderingMode", "symbolEffect",
    "contentTransition", "phaseAnimator", "keyframeAnimator",
    "sensoryFeedback", "typeSelectEquivalent",
    "scrollTargetBehavior", "scrollPosition", "scrollIndicators",
    "inspector", "inspectorColumnWidth",
    "accentColor",
    "flipsForRightToLeftLayoutDirection",
    "scenePadding",
    "privacySensitive",
    "headerProminence", "listSectionSeparator",
    # Text styling
    "bold", "italic", "underline", "strikethrough",
    "fontDesign", "fontWidth", "lineSpacing", "kerning", "tracking",
    "monospacedDigit", "baselineOffset",
    # Geometry
    "contentMargins", "safeAreaPadding",
    # Scroll
    "scrollClipDisabled", "scrollBounceBehavior",
    # Style
    "datePickerStyle", "gaugeStyle",
    "progressViewStyle", "groupBoxStyle",
    "labelStyle", "formStyle", "tableStyle",
    # Material
    "backgroundMaterial",
    # Container
    "containerBackground", "containerShape",
    # Misc
    "allowedDynamicRange",
    "typesettingLanguage", "monospaced",
    # Window and scene
    "windowResizability", "windowStyle", "windowToolbarStyle",
    "defaultSize", "windowMinSize", "windowMaxSize",
    # Menu and toolbar
    "menuStyle", "menuIndicator", "menuOrder",
    "toolbarRole", "toolbarVisibility",
    # Drag and drop
    "draggable", "dropDestination",
    # Selection
    "selectionDisabled",
    # Focus
    "focusEffectDisabled",
    # Scroll
    "scrollTargetLayout", "scrollTransition",
    # List
    "listSectionSeparatorTint", "listItemTint",
    "alternatingRowBackgrounds",
    # Table
    "tableColumnHeaders", "tableStyle",
    # Badge
    "badgeProminence"
  ]

  effectCommands = [
    "timer.once", "timer.interval", "timer.debounce",
    "http.request", "stream.sse", "stream.ws", "stream.httpChunked",
    "persist.defaults", "persist.file",
    "keychain.add", "keychain.query", "keychain.update", "keychain.delete"
  ]

  keychainTypedKeys = [
    "service", "account", "value", "accessGroup", "synchronizable",
    "label", "description", "comment", "generic", "attrs", "queryAttrs"
  ]

type
  GuiSemaOptions* = object
    backend*: GuiBackendKind
    targets*: seq[GuiTargetPlatform]
    unsupportedPolicy*: GuiUnsupportedPolicy

proc defaultSemaOptions*(): GuiSemaOptions =
  let defaults = defaultCheckOptions()
  GuiSemaOptions(
    backend: defaults.backend,
    targets: defaults.targets,
    unsupportedPolicy: defaults.unsupportedPolicy
  )

type
  SemaContext = object
    tokenTypes: Table[string, string]
    componentNames: HashSet[string]
    stateTypes: Table[string, string]
    actionNames: HashSet[string]
    semaOpts: GuiSemaOptions

proc checkDuplicate(
  diagnostics: var seq[GuiDiagnostic],
  seen: var HashSet[string],
  name: string,
  range: GuiSourceRange,
  what: string,
  code: string
) {.inline.} =
  if name in seen:
    diagnostics.add mkDiagnostic(range, gsError, "duplicate " & what & " '" & name & "'", code)
  seen.incl name

proc collectExprTokenRefs(e: GuiExpr, outRefs: var seq[(string, GuiSourceRange)])

proc collectExprTokenRefs(e: GuiExpr, outRefs: var seq[(string, GuiSourceRange)]) =
  if e.isNil:
    return

  case e.kind
  of geTokenRef:
    outRefs.add (tokenKey(e.tokenGroup, e.tokenName), e.range)
  of geBinary:
    collectExprTokenRefs(e.left, outRefs)
    collectExprTokenRefs(e.right, outRefs)
  of geCall:
    collectExprTokenRefs(e.callee, outRefs)
    for arg in e.args:
      collectExprTokenRefs(arg, outRefs)
    for arg in e.namedArgs:
      collectExprTokenRefs(arg.value, outRefs)
  of geMember:
    collectExprTokenRefs(e.left, outRefs)
  of geSubscript:
    collectExprTokenRefs(e.left, outRefs)
    collectExprTokenRefs(e.right, outRefs)
  of geArrayLit:
    for item in e.items:
      collectExprTokenRefs(item, outRefs)
  of geMapLit:
    for entry in e.entries:
      collectExprTokenRefs(entry.value, outRefs)
  of geInterpolatedString:
    for expr in e.expressions:
      collectExprTokenRefs(expr, outRefs)
  of geClosure:
    collectExprTokenRefs(e.closureBody, outRefs)
  of geKeyPath:
    discard
  of geTypeCast, geTypeCheck:
    collectExprTokenRefs(e.left, outRefs)
  of geForceUnwrap:
    collectExprTokenRefs(e.left, outRefs)
  of geBindingPrefix, geShorthandParam:
    discard
  else:
    discard

proc validateExprTokenRefs(
  diagnostics: var seq[GuiDiagnostic],
  expr: GuiExpr,
  tokenTypes: Table[string, string]
) =
  var refs: seq[(string, GuiSourceRange)]
  collectExprTokenRefs(expr, refs)
  for r in refs:
    if r[0] notin tokenTypes:
      diagnostics.add mkDiagnostic(r[1], gsError, "unknown token reference '" & r[0] & "'", "GUI_SEMA_TOKEN_REF")

proc inferLiteralType(expr: GuiExpr): string =
  if expr.isNil:
    return "Any"
  case expr.kind
  of geStringLit, geInterpolatedString:
    "String"
  of geIntLit:
    "Int"
  of geFloatLit:
    "Double"
  of geBoolLit:
    "Bool"
  of geNullLit:
    "Any"
  else:
    "Any"

proc inferTokenType(group: string, valueExpr: GuiExpr): string =
  if group == "color":
    return "Color"
  if group == "spacing":
    if valueExpr != nil and valueExpr.kind in {geIntLit, geFloatLit}:
      return "Double"
    return "Double"
  inferLiteralType(valueExpr)

proc inferExprType(
  expr: GuiExpr,
  localTypes: Table[string, string],
  stateTypes: Table[string, string],
  tokenTypes: Table[string, string],
  actionNames: HashSet[string]
): string =
  if expr.isNil:
    return "Any"

  case expr.kind
  of geStringLit, geInterpolatedString:
    "String"
  of geIntLit:
    "Int"
  of geFloatLit:
    "Double"
  of geBoolLit:
    "Bool"
  of geNullLit:
    "Any"
  of geTokenRef:
    let key = tokenKey(expr.tokenGroup, expr.tokenName)
    if key in tokenTypes:
      tokenTypes[key]
    else:
      "Any"
  of geIdent:
    if expr.ident in localTypes:
      localTypes[expr.ident]
    elif expr.ident in stateTypes:
      stateTypes[expr.ident]
    elif expr.ident in actionNames:
      "Action"
    else:
      "Any"
  of geMember:
    "Any"
  of geCall:
    let calleePath = memberPath(expr.callee)
    if calleePath.len > 0:
      let name = calleePath[^1]
      if name in actionNames:
        return "Action"
      if name == "not" and expr.args.len == 1:
        return "Bool"
      if name == "select" and expr.args.len == 3:
        let whenTrueType = inferExprType(expr.args[1], localTypes, stateTypes, tokenTypes, actionNames)
        let whenFalseType = inferExprType(expr.args[2], localTypes, stateTypes, tokenTypes, actionNames)
        if whenTrueType == whenFalseType:
          return whenTrueType
        return "Any"
    "Any"
  of geArrayLit:
    "Array"
  of geMapLit:
    "Map"
  of geEnumValue:
    "Any"
  of geSubscript:
    "Any"
  of geClosure:
    "Closure"
  of geKeyPath:
    "KeyPath"
  of geTypeCast:
    expr.ident  # The target type
  of geTypeCheck:
    "Bool"
  of geBindingPrefix:
    "Binding"
  of geShorthandParam:
    "Any"
  of geForceUnwrap:
    let inner = inferExprType(expr.left, localTypes, stateTypes, tokenTypes, actionNames)
    if inner.endsWith("?"):
      inner[0..^2]  # Strip the ? for unwrapped type
    else:
      inner
  of geBinary:
    let lt = inferExprType(expr.left, localTypes, stateTypes, tokenTypes, actionNames)
    let rt = inferExprType(expr.right, localTypes, stateTypes, tokenTypes, actionNames)
    case expr.op
    of "+":
      if lt == "String" or rt == "String":
        "String"
      elif lt == "Double" or rt == "Double":
        "Double"
      elif lt == "Int" and rt == "Int":
        "Int"
      else:
        "Any"
    of "-", "*", "/":
      if lt == "Double" or rt == "Double":
        "Double"
      elif lt == "Int" and rt == "Int":
        "Int"
      else:
        "Any"
    of "==", "!=", "<", "<=", ">", ">=", "&&", "||":
      "Bool"
    of "??":
      if lt != "Any":
        lt
      else:
        rt
    of "...", "..<":
      "Range"
    else:
      "Any"

proc exprActionRefName(expr: GuiExpr): string =
  if expr.isNil:
    return ""

  case expr.kind
  of geIdent:
    expr.ident
  of geCall:
    let path = memberPath(expr.callee)
    if path.len > 0:
      path[^1]
    else:
      ""
  of geMember:
    let path = memberPath(expr)
    if path.len > 0:
      path[^1]
    else:
      ""
  else:
    ""

proc getNamedArg(args: openArray[GuiNamedArg], name: string): GuiExpr =
  for arg in args:
    if arg.name == name:
      return arg.value
  nil

proc namedArgExists(args: openArray[GuiNamedArg], name: string): bool =
  for arg in args:
    if arg.name == name:
      return true
  false

proc isNumericType(typ: string): bool {.inline.} =
  typ in ["Int", "Double", "Any"]

proc isBoolType(typ: string): bool {.inline.} =
  typ in ["Bool", "Any"]

proc isColorType(typ: string): bool {.inline.} =
  typ in ["Color", "Any"]

proc isArrayTypeName(typ: string): bool {.inline.} =
  typ.endsWith("[]")

proc baseTypeName(typ: string): string =
  result = typ.strip()
  while result.endsWith("[]") or result.endsWith("?"):
    if result.endsWith("[]"):
      result = result[0 ..< result.len - 2].strip()
    elif result.endsWith("?"):
      result = result[0 ..< result.len - 1].strip()

  if result.startsWith("[") and result.endsWith("]"):
    if result.contains(":"):
      return "Dictionary"
    return "Array"

  if result.startsWith("(") and result.endsWith(")"):
    return "Tuple"

  let genericPos = result.find('<')
  if genericPos > 0 and result.endsWith(">"):
    result = result[0 ..< genericPos].strip()

proc validateAvailability(
  diagnostics: var seq[GuiDiagnostic],
  range: GuiSourceRange,
  kind: string,
  symbolName: string,
  semaOpts: GuiSemaOptions
) =
  let lookup = symbolLookup(kind, symbolName)
  if not lookup.known:
    return

  for target in semaOpts.targets:
    if not supportsTarget(lookup.symbol, target):
      let targetText = targetPlatformText(target)
      let minVersion =
        case target
        of gtpMacOS:
          lookup.symbol.minMacOS
        of gtpIOS:
          lookup.symbol.minIOS
      diagnostics.add mkDiagnostic(
        range,
        gsError,
        kind & " '" & symbolName & "' is unavailable on " & targetText &
          " (first supported: " & minVersion & ")",
        "GUI_SEMA_AVAILABILITY"
      )

proc validateModifierDecl(
  diagnostics: var seq[GuiDiagnostic],
  modDecl: GuiModifierDecl,
  localTypes: Table[string, string],
  ctx: SemaContext
) =
  var seenNamed: HashSet[string]
  for arg in modDecl.namedArgs:
    if arg.name in seenNamed:
      diagnostics.add mkDiagnostic(
        arg.range,
        gsError,
        "duplicate modifier argument '" & arg.name & "'",
        "GUI_SEMA_MODIFIER_ARG_DUP"
      )
    seenNamed.incl arg.name

  template argType(expr: GuiExpr): string =
    inferExprType(expr, localTypes, ctx.stateTypes, ctx.tokenTypes, ctx.actionNames)

  case modDecl.name
  of "frame":
    if modDecl.args.len > 0:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier 'frame' accepts named arguments only",
        "GUI_SEMA_MODIFIER_ARG"
      )
    let allowed = [
      "width", "height",
      "minWidth", "idealWidth", "maxWidth",
      "minHeight", "idealHeight", "maxHeight",
      "alignment"
    ]
    for arg in modDecl.namedArgs:
      if arg.name notin allowed:
        diagnostics.add mkDiagnostic(
          arg.range,
          gsError,
          "unknown frame argument '" & arg.name & "'",
          "GUI_SEMA_MODIFIER_ARG"
        )
      elif arg.name != "alignment":
        let typ = argType(arg.value)
        if not isNumericType(typ):
          diagnostics.add mkDiagnostic(
            arg.range,
            gsError,
            "frame argument '" & arg.name & "' must be numeric",
            "GUI_SEMA_MODIFIER_ARG_TYPE"
          )

  of "padding":
    if modDecl.args.len > 2:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier 'padding' accepts at most two positional arguments",
        "GUI_SEMA_MODIFIER_ARG"
      )
    if modDecl.args.len == 1 and not isNumericType(argType(modDecl.args[0])):
      diagnostics.add mkDiagnostic(
        modDecl.args[0].range,
        gsError,
        "padding value must be numeric",
        "GUI_SEMA_MODIFIER_ARG_TYPE"
      )
    let allowed = ["top", "bottom", "leading", "trailing", "horizontal", "vertical", "all"]
    for arg in modDecl.namedArgs:
      if arg.name notin allowed:
        diagnostics.add mkDiagnostic(
          arg.range,
          gsError,
          "unknown padding argument '" & arg.name & "'",
          "GUI_SEMA_MODIFIER_ARG"
        )
      elif not isNumericType(argType(arg.value)):
        diagnostics.add mkDiagnostic(
          arg.range,
          gsError,
          "padding argument '" & arg.name & "' must be numeric",
          "GUI_SEMA_MODIFIER_ARG_TYPE"
        )

  of "opacity", "cornerRadius", "layoutPriority", "zIndex", "minimumScaleFactor":
    if modDecl.namedArgs.len > 0 or modDecl.args.len != 1:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier '" & modDecl.name & "' expects exactly one positional argument",
        "GUI_SEMA_MODIFIER_ARG"
      )
    elif not isNumericType(argType(modDecl.args[0])):
      diagnostics.add mkDiagnostic(
        modDecl.args[0].range,
        gsError,
        "modifier '" & modDecl.name & "' expects a numeric value",
        "GUI_SEMA_MODIFIER_ARG_TYPE"
      )

  of "lineLimit":
    if modDecl.namedArgs.len > 0 or modDecl.args.len != 1:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier 'lineLimit' expects exactly one positional argument",
        "GUI_SEMA_MODIFIER_ARG"
      )
    else:
      let typ = argType(modDecl.args[0])
      if typ notin ["Int", "Any"]:
        diagnostics.add mkDiagnostic(
          modDecl.args[0].range,
          gsError,
          "lineLimit expects an Int value",
          "GUI_SEMA_MODIFIER_ARG_TYPE"
        )

  of "hidden":
    if modDecl.namedArgs.len > 0 or modDecl.args.len > 1:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier 'hidden' accepts zero or one bool argument",
        "GUI_SEMA_MODIFIER_ARG"
      )
    elif modDecl.args.len == 1 and not isBoolType(argType(modDecl.args[0])):
      diagnostics.add mkDiagnostic(
        modDecl.args[0].range,
        gsError,
        "hidden argument must be Bool",
        "GUI_SEMA_MODIFIER_ARG_TYPE"
      )

  of "disabled":
    if modDecl.namedArgs.len > 0 or modDecl.args.len != 1:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier 'disabled' expects exactly one bool argument",
        "GUI_SEMA_MODIFIER_ARG"
      )
    elif not isBoolType(argType(modDecl.args[0])):
      diagnostics.add mkDiagnostic(
        modDecl.args[0].range,
        gsError,
        "disabled argument must be Bool",
        "GUI_SEMA_MODIFIER_ARG_TYPE"
      )

  of "foregroundColor", "tint":
    if modDecl.namedArgs.len > 0 or modDecl.args.len != 1:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier '" & modDecl.name & "' expects exactly one positional argument",
        "GUI_SEMA_MODIFIER_ARG"
      )
    elif not isColorType(argType(modDecl.args[0])):
      diagnostics.add mkDiagnostic(
        modDecl.args[0].range,
        gsError,
        "modifier '" & modDecl.name & "' expects a Color value",
        "GUI_SEMA_MODIFIER_ARG_TYPE"
      )

  of "shadow":
    if modDecl.args.len > 1:
      diagnostics.add mkDiagnostic(
        modDecl.range,
        gsError,
        "modifier 'shadow' accepts at most one positional argument",
        "GUI_SEMA_MODIFIER_ARG"
      )
    if modDecl.args.len == 1 and not isNumericType(argType(modDecl.args[0])):
      diagnostics.add mkDiagnostic(
        modDecl.args[0].range,
        gsError,
        "shadow positional argument must be numeric",
        "GUI_SEMA_MODIFIER_ARG_TYPE"
      )
    let allowed = ["color", "radius", "x", "y"]
    for arg in modDecl.namedArgs:
      if arg.name notin allowed:
        diagnostics.add mkDiagnostic(
          arg.range,
          gsError,
          "unknown shadow argument '" & arg.name & "'",
          "GUI_SEMA_MODIFIER_ARG"
        )
      else:
        let typ = argType(arg.value)
        let valid =
          if arg.name == "color":
            isColorType(typ)
          else:
            isNumericType(typ)
        if not valid:
          diagnostics.add mkDiagnostic(
            arg.range,
            gsError,
            "shadow argument '" & arg.name & "' has invalid type",
            "GUI_SEMA_MODIFIER_ARG_TYPE"
          )
  else:
    discard

proc isKnownKeychainAttributeName(name: string): bool =
  if name in keychainTypedKeys:
    return true
  # Full keychain pass-through is accepted for any official SecItem-style key.
  name.startsWith("kSec")

proc validateKeychainAttributeMap(
  diagnostics: var seq[GuiDiagnostic],
  expr: GuiExpr,
  contextRange: GuiSourceRange
) =
  if expr.isNil:
    return
  if expr.kind != geMapLit:
    diagnostics.add mkDiagnostic(
      contextRange,
      gsError,
      "keychain attrs must be a map literal",
      "GUI_SEMA_KEYCHAIN_ATTRS"
    )
    return

  for entry in expr.entries:
    if not isKnownKeychainAttributeName(entry.key):
      diagnostics.add mkDiagnostic(
        entry.range,
        gsError,
        "unknown keychain attribute '" & entry.key & "'",
        "GUI_SEMA_KEYCHAIN_ATTR"
      )

proc ensureRequiredArg(
  diagnostics: var seq[GuiDiagnostic],
  stmt: GuiReducerStmt,
  argName: string
) =
  if not namedArgExists(stmt.commandArgs, argName):
    diagnostics.add mkDiagnostic(
      stmt.range,
      gsError,
      "missing required argument '" & argName & "' for command " & stmt.commandName,
      "GUI_SEMA_COMMAND_ARG"
    )

proc validateEmitCommand(
  diagnostics: var seq[GuiDiagnostic],
  stmt: GuiReducerStmt,
  actionNames: HashSet[string]
) =
  if stmt.commandName notin effectCommands:
    diagnostics.add mkDiagnostic(
      stmt.range,
      gsError,
      "unknown effect command '" & stmt.commandName & "'",
      "GUI_SEMA_COMMAND"
    )
    return

  var seenNames: HashSet[string]
  for arg in stmt.commandArgs:
    if arg.name in seenNames:
      diagnostics.add mkDiagnostic(arg.range, gsError, "duplicate command argument '" & arg.name & "'", "GUI_SEMA_COMMAND_ARG_DUP")
    seenNames.incl arg.name

  case stmt.commandName
  of "timer.once":
    ensureRequiredArg(diagnostics, stmt, "ms")
    ensureRequiredArg(diagnostics, stmt, "action")
  of "timer.interval":
    ensureRequiredArg(diagnostics, stmt, "ms")
    ensureRequiredArg(diagnostics, stmt, "action")
  of "timer.debounce":
    ensureRequiredArg(diagnostics, stmt, "id")
    ensureRequiredArg(diagnostics, stmt, "ms")
    ensureRequiredArg(diagnostics, stmt, "action")
  of "http.request":
    ensureRequiredArg(diagnostics, stmt, "method")
    ensureRequiredArg(diagnostics, stmt, "url")
  of "stream.sse":
    ensureRequiredArg(diagnostics, stmt, "url")
    ensureRequiredArg(diagnostics, stmt, "onEvent")
  of "stream.ws":
    ensureRequiredArg(diagnostics, stmt, "url")
    ensureRequiredArg(diagnostics, stmt, "onMessage")
  of "stream.httpChunked":
    ensureRequiredArg(diagnostics, stmt, "url")
    ensureRequiredArg(diagnostics, stmt, "onChunk")
  of "persist.defaults":
    ensureRequiredArg(diagnostics, stmt, "key")
    ensureRequiredArg(diagnostics, stmt, "value")
  of "persist.file":
    ensureRequiredArg(diagnostics, stmt, "key")
    ensureRequiredArg(diagnostics, stmt, "value")
  of "keychain.add":
    ensureRequiredArg(diagnostics, stmt, "service")
    ensureRequiredArg(diagnostics, stmt, "account")
    ensureRequiredArg(diagnostics, stmt, "value")
  of "keychain.query":
    ensureRequiredArg(diagnostics, stmt, "service")
    ensureRequiredArg(diagnostics, stmt, "account")
  of "keychain.update":
    ensureRequiredArg(diagnostics, stmt, "service")
    ensureRequiredArg(diagnostics, stmt, "account")
    ensureRequiredArg(diagnostics, stmt, "value")
  of "keychain.delete":
    ensureRequiredArg(diagnostics, stmt, "service")
    ensureRequiredArg(diagnostics, stmt, "account")
  else:
    discard

  for actionArgName in ["action", "onSuccess", "onError", "onEvent", "onMessage", "onChunk", "onComplete", "onOpen", "onClose"]:
    let actionExpr = getNamedArg(stmt.commandArgs, actionArgName)
    if actionExpr != nil:
      let actionName = exprActionRefName(actionExpr)
      if actionName.len == 0 or actionName notin actionNames:
        diagnostics.add mkDiagnostic(
          actionExpr.range,
          gsError,
          "argument '" & actionArgName & "' must reference a declared action",
          "GUI_SEMA_COMMAND_ACTION"
        )

  if stmt.commandName.startsWith("keychain."):
    let attrsExpr = getNamedArg(stmt.commandArgs, "attrs")
    if attrsExpr != nil:
      validateKeychainAttributeMap(diagnostics, attrsExpr, attrsExpr.range)
    let queryAttrsExpr = getNamedArg(stmt.commandArgs, "queryAttrs")
    if queryAttrsExpr != nil:
      validateKeychainAttributeMap(diagnostics, queryAttrsExpr, queryAttrsExpr.range)

proc collectUiTokensAndValidate(
  diagnostics: var seq[GuiDiagnostic],
  node: GuiUiNode,
  localTypes: Table[string, string],
  ctx: SemaContext
) =
  if node.isNil:
    return

  template recurse(n: GuiUiNode) =
    collectUiTokensAndValidate(diagnostics, n, localTypes, ctx)

  if node.isConditional:
    validateExprTokenRefs(diagnostics, node.condition, ctx.tokenTypes)
    for child in node.children: recurse(child)
    for elifNode in node.elseIfBranches: recurse(elifNode)
    for elseChild in node.elseChildren: recurse(elseChild)
    return

  if node.isPlatformConditional:
    for child in node.children: recurse(child)
    for child in node.platformElseChildren: recurse(child)
    return

  if node.isSwitch:
    validateExprTokenRefs(diagnostics, node.switchExpr, ctx.tokenTypes)
    for c in node.cases:
      for child in c.body: recurse(child)
    return

  let nodeLeaf =
    if node.name.contains('.'):
      node.name.split('.')[^1]
    else:
      node.name

  let knownView = symbolLookup("view", nodeLeaf)
  let allowPassthroughView =
    ctx.semaOpts.unsupportedPolicy == gupWarnPassthrough and node.name.startsWith("SwiftUI.")

  if nodeLeaf notin ctx.componentNames and not knownView.known:
    if allowPassthroughView:
      diagnostics.add mkDiagnostic(
        node.range,
        gsWarning,
        "view '" & node.name & "' is not typed-covered; forwarding via passthrough",
        "GUI_SEMA_PASSTHROUGH_VIEW"
      )
    else:
      diagnostics.add mkDiagnostic(
        node.range,
        gsError,
        "unknown component/view '" & node.name & "'",
        "GUI_SEMA_COMPONENT_REF"
      )
  elif knownView.known:
    validateAvailability(diagnostics, node.range, "view", nodeLeaf, ctx.semaOpts)

  if nodeLeaf == "ForEach":
    var hasItems = node.args.len > 0
    for arg in node.namedArgs:
      if arg.name == "items":
        hasItems = true
      elif arg.name in ["item", "index"]:
        if arg.value.kind != geIdent:
          diagnostics.add mkDiagnostic(
            arg.range,
            gsError,
            "ForEach argument '" & arg.name & "' must be an identifier",
            "GUI_SEMA_FOREACH_BIND"
          )
    if not hasItems:
      diagnostics.add mkDiagnostic(
        node.range,
        gsError,
        "ForEach requires an items argument (positional or named)",
        "GUI_SEMA_FOREACH_ITEMS"
      )

  if nodeLeaf == "NavigationSplitView":
    if node.children.len notin [2, 3]:
      diagnostics.add mkDiagnostic(
        node.range,
        gsError,
        "NavigationSplitView requires exactly 2 or 3 child blocks",
        "GUI_SEMA_SPLIT_VIEW_ARITY"
      )

  for arg in node.args:
    validateExprTokenRefs(diagnostics, arg, ctx.tokenTypes)
  for arg in node.namedArgs:
    validateExprTokenRefs(diagnostics, arg.value, ctx.tokenTypes)

  for modDecl in node.modifiers:
    let knownMod = symbolLookup("modifier", modDecl.name)
    if not knownMod.known:
      if ctx.semaOpts.unsupportedPolicy == gupWarnPassthrough:
        diagnostics.add mkDiagnostic(
          modDecl.range,
          gsWarning,
          "modifier '" & modDecl.name & "' is not typed-covered; forwarding via passthrough",
          "GUI_SEMA_PASSTHROUGH_MODIFIER"
        )
      else:
        diagnostics.add mkDiagnostic(
          modDecl.range,
          gsError,
          "modifier '" & modDecl.name & "' is not in the typed SwiftUI coverage set",
          "GUI_SEMA_MODIFIER"
        )
    else:
      validateAvailability(diagnostics, modDecl.range, "modifier", modDecl.name, ctx.semaOpts)
      if modDecl.name in coreModifierAllowlistArray:
        validateModifierDecl(diagnostics, modDecl, localTypes, ctx)

    for arg in modDecl.args:
      validateExprTokenRefs(diagnostics, arg, ctx.tokenTypes)
    for arg in modDecl.namedArgs:
      validateExprTokenRefs(diagnostics, arg.value, ctx.tokenTypes)

    for modChild in modDecl.children:
      recurse(modChild)

  for child in node.children:
    recurse(child)

proc semanticCheck*(
  program: GuiProgram,
  opts: GuiSemaOptions = defaultSemaOptions()
): GuiSemanticProgram =
  result.program = program

  if program.appName.len == 0:
    result.diagnostics.add mkDiagnostic(
      program.entryFile,
      1,
      1,
      gsError,
      "exactly one app declaration is required",
      "GUI_SEMA_APP"
    )

  var componentNames: HashSet[string]
  for component in program.components:
    checkDuplicate(result.diagnostics, componentNames, component.name, component.range, "component", "GUI_SEMA_COMPONENT_DUP")
  # Include view names extracted from escape Swift files
  for viewName in program.escapeViewNames:
    componentNames.incl viewName

  var actionByName: Table[string, GuiActionDecl]
  var actionNames: HashSet[string]
  var requiresBridge = false
  for action in program.actions:
    checkDuplicate(result.diagnostics, actionNames, action.name, action.range, "action", "GUI_SEMA_ACTION_DUP")
    actionByName[action.name] = action
    if action.owner in {gaoNim, gaoBoth}:
      requiresBridge = true

  if requiresBridge and program.bridge.nimEntry.len == 0:
    result.diagnostics.add mkDiagnostic(
      program.entryFile,
      1,
      1,
      gsWarning,
      "actions owned by Nim/Both are declared but no bridge.nimEntry is defined; pass --nim-bridge at build/run time",
      "GUI_SEMA_BRIDGE_MISSING"
    )

  if program.bridge.nimEntry.len > 0 and not program.bridge.nimEntry.toLowerAscii().endsWith(".nim"):
    result.diagnostics.add mkDiagnostic(
      program.bridge.range,
      gsError,
      "bridge.nimEntry must point to a .nim file",
      "GUI_SEMA_BRIDGE_ENTRY"
    )

  var stateTypeByName: Table[string, string]
  var stateNameSet: HashSet[string]
  for field in program.stateFields:
    checkDuplicate(result.diagnostics, stateNameSet, field.name, field.range, "state field", "GUI_SEMA_STATE_DUP")
    stateTypeByName[field.name] = field.typ

  var modelNames: HashSet[string]
  for model in program.models:
    checkDuplicate(result.diagnostics, modelNames, model.name, model.range, "model", "GUI_SEMA_MODEL_DUP")

  var enumNames: HashSet[string]
  for enumDecl in program.enums:
    checkDuplicate(result.diagnostics, enumNames, enumDecl.name, enumDecl.range, "enum", "GUI_SEMA_ENUM_DUP")

  for field in program.stateFields:
    let baseType = baseTypeName(field.typ)
    if baseType notin builtinTypesArray and baseType notin modelNames and baseType notin enumNames:
      result.diagnostics.add mkDiagnostic(
        field.range,
        gsError,
        "unknown state type '" & field.typ & "'",
        "GUI_SEMA_STATE_TYPE"
      )

  var tokenKeySet: HashSet[string]
  for tokenDecl in program.tokens:
    let key = tokenDecl.tokenKey
    checkDuplicate(result.diagnostics, tokenKeySet, key, tokenDecl.range, "token", "GUI_SEMA_TOKEN_DUP")
    result.tokenTypeByKey[key] = inferTokenType(tokenDecl.group, tokenDecl.value)

  for field in program.stateFields:
    validateExprTokenRefs(result.diagnostics, field.defaultValue, result.tokenTypeByKey)

  # Reducer checks.
  for reducerCase in program.reducerCases:
    if reducerCase.actionName notin actionByName:
      result.diagnostics.add mkDiagnostic(
        reducerCase.range,
        gsError,
        "reducer references unknown action '" & reducerCase.actionName & "'",
        "GUI_SEMA_REDUCER_ACTION"
      )
      continue

    let actionDecl = actionByName[reducerCase.actionName]
    if reducerCase.bindNames.len > 0 and reducerCase.bindNames.len != actionDecl.params.len:
      result.diagnostics.add mkDiagnostic(
        reducerCase.range,
        gsError,
        "reducer binding count mismatch for action '" & reducerCase.actionName & "'",
        "GUI_SEMA_REDUCER_BIND"
      )

    var localTypes: Table[string, string]
    if reducerCase.bindNames.len > 0:
      for i, bindName in reducerCase.bindNames:
        localTypes[bindName] = actionDecl.params[i].typ
    else:
      for param in actionDecl.params:
        localTypes[param.name] = param.typ

    for stmt in reducerCase.statements:
      case stmt.kind
      of grsSet:
        if stmt.fieldName notin stateTypeByName:
          result.diagnostics.add mkDiagnostic(
            stmt.range,
            gsError,
            "set references unknown state field '" & stmt.fieldName & "'",
            "GUI_SEMA_SET_FIELD"
          )
        else:
          let expectedType = stateTypeByName[stmt.fieldName]
          let actualType = inferExprType(stmt.valueExpr, localTypes, stateTypeByName, result.tokenTypeByKey, actionNames)
          if actualType != "Any" and actualType != expectedType:
            if not (expectedType == "Double" and actualType == "Int"):
              if not (isArrayTypeName(expectedType) and actualType == "Array"):
                result.diagnostics.add mkDiagnostic(
                  stmt.range,
                  gsError,
                  "type mismatch for state field '" & stmt.fieldName & "': expected " & expectedType & ", got " & actualType,
                  "GUI_SEMA_SET_TYPE"
                )

          validateExprTokenRefs(result.diagnostics, stmt.valueExpr, result.tokenTypeByKey)

      of grsEmit:
        validateEmitCommand(result.diagnostics, stmt, actionNames)
        for arg in stmt.commandArgs:
          validateExprTokenRefs(result.diagnostics, arg.value, result.tokenTypeByKey)

  # Navigation checks.
  var stackNames: HashSet[string]
  for stackDecl in program.stacks:
    checkDuplicate(result.diagnostics, stackNames, stackDecl.name, stackDecl.range, "stack", "GUI_SEMA_STACK_DUP")

    var routeIds: HashSet[string]
    for route in stackDecl.routes:
      checkDuplicate(result.diagnostics, routeIds, route.id, route.range, "route id", "GUI_SEMA_ROUTE_DUP")
      if route.component notin componentNames:
        result.diagnostics.add mkDiagnostic(route.range, gsError, "route references unknown component '" & route.component & "'", "GUI_SEMA_ROUTE_COMPONENT")

  for tabDecl in program.tabs:
    if tabDecl.rootComponent.len == 0:
      result.diagnostics.add mkDiagnostic(tabDecl.range, gsError, "tab must specify root component", "GUI_SEMA_TAB_ROOT")
    elif tabDecl.rootComponent notin componentNames:
      result.diagnostics.add mkDiagnostic(tabDecl.range, gsError, "tab references unknown root component '" & tabDecl.rootComponent & "'", "GUI_SEMA_TAB_COMPONENT")

    if tabDecl.stack.len > 0 and tabDecl.stack notin stackNames:
      result.diagnostics.add mkDiagnostic(tabDecl.range, gsError, "tab references unknown stack '" & tabDecl.stack & "'", "GUI_SEMA_TAB_STACK")

  # Component bodies.
  let ctx = SemaContext(
    tokenTypes: result.tokenTypeByKey,
    componentNames: componentNames,
    stateTypes: stateTypeByName,
    actionNames: actionNames,
    semaOpts: opts
  )
  for component in program.components:
    var componentLocalTypes: Table[string, string]
    for param in component.params:
      componentLocalTypes[param.name] = param.typ
    for ls in component.localState:
      componentLocalTypes[ls.name] = ls.typ
    for eb in component.envBindings:
      componentLocalTypes[eb.localName] = eb.typ
    for lb in component.letBindings:
      componentLocalTypes[lb.name] = if lb.typ.len > 0: lb.typ else: "Any"

    for node in component.body:
      collectUiTokensAndValidate(result.diagnostics, node, componentLocalTypes, ctx)

  # Escape declarations are relative-path strings; only shape checks here.
  for esc in program.escapes:
    if esc.swiftFile.len == 0:
      result.diagnostics.add mkDiagnostic(esc.range, gsError, "escape swiftFile path cannot be empty", "GUI_SEMA_ESCAPE")

  # Window config checks.
  let win = program.window

  template winDimCheck(hasField: bool, value: float64, name: string) =
    if hasField and value <= 0:
      result.diagnostics.add mkDiagnostic(win.range, gsError, "window." & name & " must be > 0", "GUI_SEMA_WINDOW_DIM")

  template winRangeCheck(hasA, hasB: bool, valA, valB: float64, nameA, nameB, relation: string) =
    if hasA and hasB and valA > valB:
      result.diagnostics.add mkDiagnostic(win.range, gsError,
        "window." & nameA & " cannot be " & relation & " window." & nameB, "GUI_SEMA_WINDOW_RANGE")

  winDimCheck(win.hasWidth, win.width, "width")
  winDimCheck(win.hasHeight, win.height, "height")
  winDimCheck(win.hasMinWidth, win.minWidth, "minWidth")
  winDimCheck(win.hasMinHeight, win.minHeight, "minHeight")
  winDimCheck(win.hasMaxWidth, win.maxWidth, "maxWidth")
  winDimCheck(win.hasMaxHeight, win.maxHeight, "maxHeight")

  winRangeCheck(win.hasMinWidth, win.hasMaxWidth, win.minWidth, win.maxWidth, "minWidth", "maxWidth", "greater than")
  winRangeCheck(win.hasMinHeight, win.hasMaxHeight, win.minHeight, win.maxHeight, "minHeight", "maxHeight", "greater than")
  winRangeCheck(win.hasWidth, win.hasMinWidth, win.minWidth, win.width, "width", "minWidth", "smaller than")
  winRangeCheck(win.hasHeight, win.hasMinHeight, win.minHeight, win.height, "height", "minHeight", "smaller than")
  winRangeCheck(win.hasWidth, win.hasMaxWidth, win.width, win.maxWidth, "width", "maxWidth", "greater than")
  winRangeCheck(win.hasHeight, win.hasMaxHeight, win.height, win.maxHeight, "height", "maxHeight", "greater than")
