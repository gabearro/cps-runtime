## SwiftUI backend emitter wrapper.

import ../types
import ../ir
import ../swift_codegen
import ../xcodeproj_codegen

proc emitSwiftUiProject*(
  irProgram: GuiIrProgram,
  outputRoot: string,
  targets: openArray[GuiTargetPlatform],
  generatedFiles: var seq[string],
  diagnostics: var seq[GuiDiagnostic]
): tuple[projectPath: string, scheme: string, appDir: string] =
  var sawIOS = false
  for target in targets:
    if target == gtpIOS:
      sawIOS = true
      break

  if sawIOS:
    diagnostics.add mkDiagnostic(
      outputRoot,
      1,
      1,
      gsWarning,
      "iOS target generation is not implemented yet; generating macOS SwiftUI target only",
      "GUI_BACKEND_TARGET_FALLBACK"
    )

  let scaffold = emitXcodeProject(irProgram, outputRoot, generatedFiles, diagnostics)
  emitSwiftSources(irProgram, scaffold.appDir, generatedFiles, diagnostics)
  (scaffold.projectPath, scaffold.scheme, scaffold.appDir)
