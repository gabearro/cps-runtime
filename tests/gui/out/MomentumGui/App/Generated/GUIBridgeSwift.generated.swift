import Foundation

struct GUIBridgeDispatchResult {
  var status: Int32
  var statePatch: Data
  var effects: Data
  var emittedActions: Data
  var diagnostics: Data

  static var empty: GUIBridgeDispatchResult {
    GUIBridgeDispatchResult(status: 0, statePatch: Data(), effects: Data(), emittedActions: Data(), diagnostics: Data())
  }
}

final class GUIBridgeRuntime {
  func load(path: String) -> Bool { false }
  func unload() {}
  func maybeReload(path: String) {}
  func dispatch(payload: Data) -> GUIBridgeDispatchResult { .empty }
}
