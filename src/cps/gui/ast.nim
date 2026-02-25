## GUI DSL AST structures.

import std/tables
import ./types

type
  GuiExprKind* = enum
    geIdent,
    geStringLit,
    geIntLit,
    geFloatLit,
    geBoolLit,
    geNullLit,
    geMember,
    geBinary,
    geCall,
    geArrayLit,
    geMapLit,
    geTokenRef,
    geInterpolatedString,
    geEnumValue,      # .leading, .center, .easeInOut etc. (Swift enum dot-syntax)
    geSubscript,      # array[index] or dict[key]
    geClosure,        # { params in body } or { body } — Swift closure expression
    geKeyPath,        # \Type.member or \.member — Swift key path expression
    geTypeCast,       # expr as Type, expr as? Type, expr as! Type
    geTypeCheck,      # expr is Type
    geBindingPrefix,  # $identifier — Swift binding prefix (emits $ in Swift)
    geShorthandParam, # $0, $1 etc. — Swift shorthand closure parameters
    geForceUnwrap     # expr! — Swift force unwrap

  GuiExpr* = ref object
    kind*: GuiExprKind
    range*: GuiSourceRange
    ident*: string
    strVal*: string
    intVal*: int64
    floatVal*: float64
    boolVal*: bool
    left*: GuiExpr
    right*: GuiExpr
    op*: string
    isOptional*: bool  # geMember: optional chaining (expr?.member)
    callee*: GuiExpr
    args*: seq[GuiExpr]
    namedArgs*: seq[GuiNamedArg]
    items*: seq[GuiExpr]
    entries*: seq[GuiMapEntry]
    tokenGroup*: string
    tokenName*: string
    # geInterpolatedString: interleaved literal parts and expression parts
    # parts has len = expressions.len + 1 (literal before each expr, plus trailing)
    parts*: seq[string]
    expressions*: seq[GuiExpr]
    # geClosure: { params in body } or { body }
    closureParams*: seq[string]  # parameter names (empty for parameterless closures)
    closureBody*: GuiExpr        # body expression
    # geKeyPath: \Type.member or \.member
    keyPathRoot*: string         # root type (empty for shorthand \.member)
    keyPathMembers*: seq[string] # member chain

  GuiNamedArg* = object
    name*: string
    value*: GuiExpr
    range*: GuiSourceRange

  GuiMapEntry* = object
    key*: string
    value*: GuiExpr
    range*: GuiSourceRange

  GuiParamDecl* = object
    name*: string
    typ*: string
    isBinding*: bool   # @Binding parameter
    range*: GuiSourceRange

  GuiFieldDecl* = object
    name*: string
    typ*: string
    defaultValue*: GuiExpr
    isComputed*: bool    # computed property (getter only, no storage)
    isPublished*: bool   # @Published field (for ObservableObject models)
    range*: GuiSourceRange

  GuiModelDecl* = object
    name*: string
    fields*: seq[GuiFieldDecl]
    protocols*: seq[string]  # protocol conformances (e.g. Identifiable, Hashable)
    range*: GuiSourceRange

  GuiEnumCaseDecl* = object
    name*: string
    params*: seq[GuiParamDecl]
    rawValue*: GuiExpr          # raw value: case home = "Home"
    range*: GuiSourceRange

  GuiEnumDecl* = object
    name*: string
    rawType*: string            # raw type: enum Tab: String { ... }
    protocols*: seq[string]     # protocol conformance: CaseIterable, etc.
    cases*: seq[GuiEnumCaseDecl]
    range*: GuiSourceRange

  GuiActionDecl* = object
    name*: string
    params*: seq[GuiParamDecl]
    owner*: GuiActionOwner
    range*: GuiSourceRange

  GuiTokenDecl* = object
    group*: string
    name*: string
    value*: GuiExpr
    range*: GuiSourceRange

  GuiModifierDecl* = object
    name*: string
    args*: seq[GuiExpr]
    namedArgs*: seq[GuiNamedArg]
    children*: seq[GuiUiNode]
    range*: GuiSourceRange

  GuiIfLetClause* = object
    isBinding*: bool       # true = let binding, false = boolean condition
    bindName*: string      # for binding: the variable name
    bindExpr*: GuiExpr     # for binding: the expression; for condition: the bool expr
    range*: GuiSourceRange

  GuiUiNode* = ref object
    name*: string
    args*: seq[GuiExpr]
    namedArgs*: seq[GuiNamedArg]
    children*: seq[GuiUiNode]
    modifiers*: seq[GuiModifierDecl]
    range*: GuiSourceRange
    # Conditional view support (if/else if/else chains)
    isConditional*: bool
    condition*: GuiExpr                 # if condition
    elseIfBranches*: seq[GuiUiNode]     # else-if nodes (each has isConditional=true)
    elseChildren*: seq[GuiUiNode]       # else branch children
    # If-let binding: if let name = expr { ... } or chained: if let a = x, let b = y { ... }
    isIfLet*: bool
    letName*: string       # single binding (backward compat)
    letExpr*: GuiExpr      # single binding (backward compat)
    ifLetClauses*: seq[GuiIfLetClause]  # chained bindings and conditions
    # Platform conditional: #if os(iOS) { ... } #else { ... }
    isPlatformConditional*: bool
    platformCondition*: string  # e.g. "os(iOS)", "os(macOS)", "targetEnvironment(simulator)"
    platformElseChildren*: seq[GuiUiNode]
    # Switch/case pattern matching
    isSwitch*: bool
    switchExpr*: GuiExpr
    cases*: seq[GuiSwitchCase]

  GuiSwitchCase* = object
    patterns*: seq[GuiExpr]   # case patterns (.home, .settings, etc)
    letBindings*: seq[string] # associated value bindings: case .detail(let id)
    isDefault*: bool          # default/else case
    body*: seq[GuiUiNode]
    range*: GuiSourceRange

  GuiReducerStmtKind* = enum
    grsSet,
    grsEmit

  GuiReducerStmt* = object
    kind*: GuiReducerStmtKind
    fieldName*: string
    valueExpr*: GuiExpr
    commandName*: string
    commandArgs*: seq[GuiNamedArg]
    animationExpr*: GuiExpr  # withAnimation(.easeInOut) wrapper
    range*: GuiSourceRange

  GuiReducerCase* = object
    actionName*: string
    bindNames*: seq[string]
    statements*: seq[GuiReducerStmt]
    range*: GuiSourceRange

  GuiTabDecl* = object
    id*: string
    rootComponent*: string
    stack*: string
    range*: GuiSourceRange

  GuiRouteDecl* = object
    id*: string
    component*: string
    range*: GuiSourceRange

  GuiStackDecl* = object
    name*: string
    routes*: seq[GuiRouteDecl]
    range*: GuiSourceRange

  GuiEscapeDecl* = object
    swiftFile*: string
    range*: GuiSourceRange

  GuiBridgeDecl* = object
    nimEntry*: string
    range*: GuiSourceRange

  GuiWindowDecl* = object
    width*: float64
    height*: float64
    minWidth*: float64
    minHeight*: float64
    maxWidth*: float64
    maxHeight*: float64
    hasWidth*: bool
    hasHeight*: bool
    hasMinWidth*: bool
    hasMinHeight*: bool
    hasMaxWidth*: bool
    hasMaxHeight*: bool
    title*: string
    hasTitle*: bool
    closeAppOnLastWindowClose*: bool
    hasClosePolicy*: bool
    showTitleBar*: bool
    hasShowTitleBar*: bool
    range*: GuiSourceRange

  GuiPropertyWrapper* = enum
    gpwState,             # @State
    gpwFocusState,        # @FocusState
    gpwGestureState,      # @GestureState
    gpwStateObject,       # @StateObject
    gpwObservedObject,    # @ObservedObject
    gpwEnvironmentObject, # @EnvironmentObject
    gpwAppStorage,        # @AppStorage("key")
    gpwSceneStorage,      # @SceneStorage("key")
    gpwNamespace,          # @Namespace
    gpwAccessibilityFocusState  # @AccessibilityFocusState

  GuiLocalStateDecl* = object
    name*: string
    typ*: string
    wrapper*: GuiPropertyWrapper
    storageKey*: string  # For @AppStorage/@SceneStorage: the key string
    defaultValue*: GuiExpr
    range*: GuiSourceRange

  GuiLetBinding* = object
    name*: string
    typ*: string     # optional explicit type; empty = inferred
    value*: GuiExpr
    range*: GuiSourceRange

  GuiParamKind* = enum
    gpkNormal,    # regular value param
    gpkBinding    # @Binding param

  GuiComponentDecl* = object
    name*: string
    params*: seq[GuiParamDecl]
    localState*: seq[GuiLocalStateDecl]
    envBindings*: seq[GuiEnvBinding]
    letBindings*: seq[GuiLetBinding]
    body*: seq[GuiUiNode]
    range*: GuiSourceRange

  GuiEnvBinding* = object
    localName*: string
    keyPath*: string   # e.g. "colorScheme", "dismiss"
    typ*: string
    range*: GuiSourceRange

  GuiViewModifierDecl* = object
    name*: string
    modifiers*: seq[GuiModifierDecl]
    range*: GuiSourceRange

  GuiProgram* = object
    entryFile*: string
    loadedFiles*: seq[string]
    appName*: string
    includes*: seq[string]
    tokens*: seq[GuiTokenDecl]
    models*: seq[GuiModelDecl]
    enums*: seq[GuiEnumDecl]
    stateFields*: seq[GuiFieldDecl]
    actions*: seq[GuiActionDecl]
    reducerCases*: seq[GuiReducerCase]
    tabs*: seq[GuiTabDecl]
    stacks*: seq[GuiStackDecl]
    components*: seq[GuiComponentDecl]
    viewModifiers*: seq[GuiViewModifierDecl]
    escapes*: seq[GuiEscapeDecl]
    bridge*: GuiBridgeDecl
    window*: GuiWindowDecl
    settingsComponent*: string  # optional: component name for macOS Settings scene

  GuiSemanticProgram* = object
    program*: GuiProgram
    diagnostics*: seq[GuiDiagnostic]
    tokenTypeByKey*: Table[string, string]

proc exprIdent*(name: string, range = noRange()): GuiExpr =
  GuiExpr(kind: geIdent, ident: name, range: range)

proc exprString*(value: string, range = noRange()): GuiExpr =
  GuiExpr(kind: geStringLit, strVal: value, range: range)

proc exprInt*(value: int64, range = noRange()): GuiExpr =
  GuiExpr(kind: geIntLit, intVal: value, range: range)

proc exprFloat*(value: float64, range = noRange()): GuiExpr =
  GuiExpr(kind: geFloatLit, floatVal: value, range: range)

proc exprBool*(value: bool, range = noRange()): GuiExpr =
  GuiExpr(kind: geBoolLit, boolVal: value, range: range)

proc exprNull*(range = noRange()): GuiExpr =
  GuiExpr(kind: geNullLit, range: range)

proc tokenKey*(groupName: string, tokenName: string): string {.inline.} =
  groupName & "." & tokenName

proc tokenKey*(d: GuiTokenDecl): string {.inline.} =
  tokenKey(d.group, d.name)

proc isLiteral*(e: GuiExpr): bool =
  if e.isNil:
    return false
  e.kind in {geStringLit, geIntLit, geFloatLit, geBoolLit, geNullLit}

proc memberPath*(e: GuiExpr): seq[string] =
  if e.isNil:
    return @[]
  case e.kind
  of geIdent:
    @[e.ident]
  of geMember:
    let left = memberPath(e.left)
    if left.len == 0:
      @[]
    else:
      var parts = left
      parts.add e.ident
      parts
  of geTokenRef:
    @["token", e.tokenGroup, e.tokenName]
  else:
    @[]
