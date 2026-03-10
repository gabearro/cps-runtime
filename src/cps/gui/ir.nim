## GUI DSL normalized IR.
## Composes GuiProgram with derived maps for codegen.

import std/tables
import ./ast

type
  GuiIrProgram* = object
    program*: GuiProgram
    tokenTypeByKey*: Table[string, string]

# Forward GuiProgram fields for transparent access by codegen consumers.
template appName*(ir: GuiIrProgram): untyped = ir.program.appName
template loadedFiles*(ir: GuiIrProgram): untyped = ir.program.loadedFiles
template tokens*(ir: GuiIrProgram): untyped = ir.program.tokens
template models*(ir: GuiIrProgram): untyped = ir.program.models
template enums*(ir: GuiIrProgram): untyped = ir.program.enums
template stateFields*(ir: GuiIrProgram): untyped = ir.program.stateFields
template actions*(ir: GuiIrProgram): untyped = ir.program.actions
template reducerCases*(ir: GuiIrProgram): untyped = ir.program.reducerCases
template tabs*(ir: GuiIrProgram): untyped = ir.program.tabs
template stacks*(ir: GuiIrProgram): untyped = ir.program.stacks
template components*(ir: GuiIrProgram): untyped = ir.program.components
template viewModifiers*(ir: GuiIrProgram): untyped = ir.program.viewModifiers
template escapes*(ir: GuiIrProgram): untyped = ir.program.escapes
template bridge*(ir: GuiIrProgram): untyped = ir.program.bridge
template window*(ir: GuiIrProgram): untyped = ir.program.window
template settingsComponent*(ir: GuiIrProgram): untyped = ir.program.settingsComponent

proc buildIr*(sem: GuiSemanticProgram): GuiIrProgram =
  GuiIrProgram(program: sem.program, tokenTypeByKey: sem.tokenTypeByKey)
