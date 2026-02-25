## Xcode project scaffold emitter for generated GUI SwiftUI apps.

import std/[os, strutils, strformat]
import ./types
import ./ir

proc sanitizeAppName(name: string): string =
  var text = ""
  for c in name:
    if c.isAlphaNumeric:
      text.add c
  if text.len == 0:
    return "GuiApp"
  if text[0].isDigit:
    text = "Gui" & text
  text

proc toBundleId(appName: string): string =
  var lowered = appName.toLowerAscii()
  lowered = lowered.multiReplace((" ", ""), ("_", ""), ("-", ""))
  if lowered.len == 0:
    lowered = "guiapp"
  "dev.cps." & lowered

proc writeText(path: string, content: string, generatedFiles: var seq[string]) =
  createDir(path.parentDir())
  writeFile(path, content)
  generatedFiles.add path

proc projectPbxproj(appName: string): string =
  let bundleId = toBundleId(appName)
  fmt"""
// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
		A10000000000000000000001 /* GUI.generated.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A20000000000000000000001 /* GUI.generated.swift */; }};
		A10000000000000000000002 /* GUIRuntime.generated.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A20000000000000000000002 /* GUIRuntime.generated.swift */; }};
		A10000000000000000000003 /* GUIBridgeSwift.generated.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A20000000000000000000004 /* GUIBridgeSwift.generated.swift */; }};
		A10000000000000000000004 /* GUICustomSources.generated.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A20000000000000000000005 /* GUICustomSources.generated.swift */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A20000000000000000000001 /* GUI.generated.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GUI.generated.swift; sourceTree = "<group>"; }};
		A20000000000000000000002 /* GUIRuntime.generated.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GUIRuntime.generated.swift; sourceTree = "<group>"; }};
		A20000000000000000000003 /* {appName}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {appName}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		A20000000000000000000004 /* GUIBridgeSwift.generated.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GUIBridgeSwift.generated.swift; sourceTree = "<group>"; }};
		A20000000000000000000005 /* GUICustomSources.generated.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GUICustomSources.generated.swift; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		A30000000000000000000001 /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A40000000000000000000001 = {{
			isa = PBXGroup;
			children = (
				A40000000000000000000002 /* App */,
				A40000000000000000000006 /* Products */,
			);
			sourceTree = "<group>";
		}};
		A40000000000000000000002 /* App */ = {{
			isa = PBXGroup;
			children = (
				A40000000000000000000003 /* Generated */,
				A40000000000000000000004 /* Custom */,
				A40000000000000000000005 /* Resources */,
			);
			path = App;
			sourceTree = "<group>";
		}};
		A40000000000000000000003 /* Generated */ = {{
			isa = PBXGroup;
			children = (
				A20000000000000000000001 /* GUI.generated.swift */,
				A20000000000000000000002 /* GUIRuntime.generated.swift */,
				A20000000000000000000004 /* GUIBridgeSwift.generated.swift */,
				A20000000000000000000005 /* GUICustomSources.generated.swift */,
			);
			path = Generated;
			sourceTree = "<group>";
		}};
		A40000000000000000000004 /* Custom */ = {{
			isa = PBXGroup;
			children = (
			);
			path = Custom;
			sourceTree = "<group>";
		}};
		A40000000000000000000005 /* Resources */ = {{
			isa = PBXGroup;
			children = (
			);
			path = Resources;
			sourceTree = "<group>";
		}};
		A40000000000000000000006 /* Products */ = {{
			isa = PBXGroup;
			children = (
				A20000000000000000000003 /* {appName}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A50000000000000000000001 /* {appName} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = A80000000000000000000002 /* Build configuration list for PBXNativeTarget \"{appName}\" */;
			buildPhases = (
				A70000000000000000000003 /* Build Nim Bridge */,
				A70000000000000000000002 /* Sources */,
				A70000000000000000000001 /* Resources */,
				A30000000000000000000001 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = {appName};
			productName = {appName};
			productReference = A20000000000000000000003 /* {appName}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A60000000000000000000001 /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					A50000000000000000000001 = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = A80000000000000000000001 /* Build configuration list for PBXProject \"{appName}\" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A40000000000000000000001;
			productRefGroup = A40000000000000000000006 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A50000000000000000000001 /* {appName} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		A70000000000000000000001 /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
		A70000000000000000000003 /* Build Nim Bridge */ = {{
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
			);
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/bash;
			shellScript = "if [ -x \"$SRCROOT/Bridge/Nim/build_bridge.sh\" ]; then\n  \"$SRCROOT/Bridge/Nim/build_bridge.sh\"\nfi\nBRIDGE_DIR=\"$SRCROOT/Bridge/Nim\"\nDEST_DIR=\"$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH\"\nmkdir -p \"$DEST_DIR\"\nif [ -f \"$BRIDGE_DIR/libgui_bridge_latest.dylib\" ]; then\n  cp -f \"$BRIDGE_DIR/libgui_bridge_latest.dylib\" \"$DEST_DIR/libgui_bridge_latest.dylib\"\nelif [ -f \"$BRIDGE_DIR/libgui_bridge_latest.so\" ]; then\n  cp -f \"$BRIDGE_DIR/libgui_bridge_latest.so\" \"$DEST_DIR/libgui_bridge_latest.so\"\nfi";
		}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		A70000000000000000000002 /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A10000000000000000000001 /* GUI.generated.swift in Sources */,
				A10000000000000000000002 /* GUIRuntime.generated.swift in Sources */,
				A10000000000000000000003 /* GUIBridgeSwift.generated.swift in Sources */,
				A10000000000000000000004 /* GUICustomSources.generated.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		A90000000000000000000001 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 6.0;
			}};
			name = Debug;
		}};
		A90000000000000000000002 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 6.0;
			}};
			name = Release;
		}};
		A90000000000000000000003 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = {appName};
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "{bundleId}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
			}};
			name = Debug;
		}};
		A90000000000000000000004 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = {appName};
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_NSPrincipalClass = NSApplication;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "{bundleId}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A80000000000000000000001 /* Build configuration list for PBXProject \"{appName}\" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A90000000000000000000001 /* Debug */,
				A90000000000000000000002 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		A80000000000000000000002 /* Build configuration list for PBXNativeTarget \"{appName}\" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A90000000000000000000003 /* Debug */,
				A90000000000000000000004 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = A60000000000000000000001 /* Project object */;
}}
"""

proc schemeXml(appName: string): string =
  fmt"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "A50000000000000000000001"
               BuildableName = "{appName}.app"
               BlueprintName = "{appName}"
               ReferencedContainer = "container:{appName}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A50000000000000000000001"
            BuildableName = "{appName}.app"
            BlueprintName = "{appName}"
            ReferencedContainer = "container:{appName}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A50000000000000000000001"
            BuildableName = "{appName}.app"
            BlueprintName = "{appName}"
            ReferencedContainer = "container:{appName}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

proc emitXcodeProject*(
  ir: GuiIrProgram,
  outRoot: string,
  generatedFiles: var seq[string],
  diagnostics: var seq[GuiDiagnostic]
): tuple[appName: string, appDir: string, projectPath: string, scheme: string] =
  let appName = sanitizeAppName(if ir.appName.len > 0: ir.appName else: "GuiApp")
  let appDir = outRoot / appName
  let projectPath = appDir / (appName & ".xcodeproj")
  let generatedDir = appDir / "App" / "Generated"
  let customDir = appDir / "App" / "Custom"
  let resourcesDir = appDir / "App" / "Resources"
  let schemeDir = projectPath / "xcshareddata" / "xcschemes"

  createDir(appDir)
  createDir(projectPath)
  createDir(generatedDir)
  createDir(customDir)
  createDir(resourcesDir)
  createDir(schemeDir)

  let pbxprojPath = projectPath / "project.pbxproj"
  writeText(pbxprojPath, projectPbxproj(appName), generatedFiles)

  let schemePath = schemeDir / (appName & ".xcscheme")
  writeText(schemePath, schemeXml(appName), generatedFiles)

  result = (appName, appDir, projectPath, appName)
