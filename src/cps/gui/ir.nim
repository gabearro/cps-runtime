## GUI DSL normalized IR.
## v1 keeps IR intentionally close to AST while providing explicit derived maps for codegen.

import std/tables
import ./ast

type
  GuiIrProgram* = object
    appName*: string
    loadedFiles*: seq[string]
    tokens*: seq[GuiTokenDecl]
    tokenTypeByKey*: Table[string, string]
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
    settingsComponent*: string

proc buildIr*(sem: GuiSemanticProgram): GuiIrProgram =
  result.appName = sem.program.appName
  result.loadedFiles = sem.program.loadedFiles
  result.tokens = sem.program.tokens
  result.tokenTypeByKey = sem.tokenTypeByKey
  result.models = sem.program.models
  result.enums = sem.program.enums
  result.stateFields = sem.program.stateFields
  result.actions = sem.program.actions
  result.reducerCases = sem.program.reducerCases
  result.tabs = sem.program.tabs
  result.stacks = sem.program.stacks
  result.components = sem.program.components
  result.viewModifiers = sem.program.viewModifiers
  result.escapes = sem.program.escapes
  result.bridge = sem.program.bridge
  result.window = sem.program.window
  result.settingsComponent = sem.program.settingsComponent
