## GUI backend interface dispatch.

import ../types
import ../ir
import ./swiftui_codegen

type
  GuiBackendEmitResult* = object
    projectPath*: string
    scheme*: string
    appDir*: string

proc emitBackendProject*(
  backend: GuiBackendKind,
  irProgram: GuiIrProgram,
  outputRoot: string,
  targets: openArray[GuiTargetPlatform],
  generatedFiles: var seq[string],
  diagnostics: var seq[GuiDiagnostic]
): GuiBackendEmitResult =
  case backend
  of gbkSwiftUI:
    let emitted = emitSwiftUiProject(irProgram, outputRoot, targets, generatedFiles, diagnostics)
    result.projectPath = emitted.projectPath
    result.scheme = emitted.scheme
    result.appDir = emitted.appDir
