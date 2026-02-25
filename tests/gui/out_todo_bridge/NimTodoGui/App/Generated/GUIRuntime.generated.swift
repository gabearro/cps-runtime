import Foundation
import SwiftUI
import Security

enum GUIAnyValue {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case action(GUIAction)
  case object([String: GUIAnyValue])
  case array([GUIAnyValue])
  case null

  static func from(_ value: String) -> GUIAnyValue { .string(value) }
  static func from(_ value: Int) -> GUIAnyValue { .int(value) }
  static func from(_ value: Int64) -> GUIAnyValue { .int(Int(value)) }
  static func from(_ value: Double) -> GUIAnyValue { .double(value) }
  static func from(_ value: Float) -> GUIAnyValue { .double(Double(value)) }
  static func from(_ value: Bool) -> GUIAnyValue { .bool(value) }
  static func from(_ value: [String: GUIAnyValue]) -> GUIAnyValue { .object(value) }
  static func from(_ value: [GUIAnyValue]) -> GUIAnyValue { .array(value) }
  static func from(_ value: [String: String]) -> GUIAnyValue {
    var mapped: [String: GUIAnyValue] = [:]
    for (k, v) in value { mapped[k] = .string(v) }
    return .object(mapped)
  }
  static func from<T>(_ value: T?) -> GUIAnyValue {
    guard let value else { return .null }
    if let cast = value as? String { return .string(cast) }
    if let cast = value as? Int { return .int(cast) }
    if let cast = value as? Int64 { return .int(Int(cast)) }
    if let cast = value as? Double { return .double(cast) }
    if let cast = value as? Float { return .double(Double(cast)) }
    if let cast = value as? Bool { return .bool(cast) }
    if let cast = value as? GUIAction { return .action(cast) }
    if let cast = value as? [String: Any] {
      var mapped: [String: GUIAnyValue] = [:]
      for (k, v) in cast { mapped[k] = GUIAnyValue.from(v) }
      return .object(mapped)
    }
    if let cast = value as? [Any] {
      return .array(cast.map { GUIAnyValue.from($0) })
    }
    return .string(String(describing: value))
  }

  var stringValue: String? {
    if case let .string(v) = self { return v }
    return nil
  }

  var intValue: Int? {
    switch self {
    case let .int(v): return v
    case let .double(v): return Int(v)
    case let .string(v): return Int(v)
    default: return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case let .double(v): return v
    case let .int(v): return Double(v)
    case let .string(v): return Double(v)
    default: return nil
    }
  }

  var boolValue: Bool? {
    switch self {
    case let .bool(v): return v
    case let .string(v):
      switch v.lowercased() {
      case "true", "1", "yes", "on": return true
      case "false", "0", "no", "off": return false
      default: return nil
      }
    default:
      return nil
    }
  }

  var actionValue: GUIAction? {
    if case let .action(v) = self { return v }
    return nil
  }

  var objectValue: [String: GUIAnyValue]? {
    if case let .object(v) = self { return v }
    return nil
  }

  var arrayValue: [GUIAnyValue]? {
    if case let .array(v) = self { return v }
    return nil
  }
}

struct GUIEffectCommand {
  let name: String
  let args: [String: GUIAnyValue]
}

func guiColor(_ hexOrName: String) -> Color {
  let value = hexOrName.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.hasPrefix("#") {
    let hex = String(value.dropFirst())
    let scanner = Scanner(string: hex)
    var rgb: UInt64 = 0
    if scanner.scanHexInt64(&rgb) {
      switch hex.count {
      case 6:
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
      case 8:
        let r = Double((rgb >> 24) & 0xFF) / 255.0
        let g = Double((rgb >> 16) & 0xFF) / 255.0
        let b = Double((rgb >> 8) & 0xFF) / 255.0
        let a = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
      default:
        break
      }
    }
  }
  return Color(value)
}

@MainActor
final class GUIRuntime {
  private unowned let store: GUIStore
  private var timerTasks: [String: Task<Void, Never>] = [:]
  private var streamTasks: [String: Task<Void, Never>] = [:]
  private var websocketTasks: [String: URLSessionWebSocketTask] = [:]
  private let bridgeRuntime = GUIBridgeRuntime()
  private var bridgeTimeoutMs = 250

  init(store: GUIStore) {
    self.store = store
  }

  func shutdown() {
    for (_, task) in timerTasks {
      task.cancel()
    }
    timerTasks.removeAll()

    for (_, task) in streamTasks {
      task.cancel()
    }
    streamTasks.removeAll()

    for (_, socket) in websocketTasks {
      socket.cancel(with: .goingAway, reason: nil)
    }
    websocketTasks.removeAll()

    bridgeRuntime.unload()
  }

  func enqueue(_ commands: [GUIEffectCommand]) {
    for command in commands {
      run(command)
    }
  }

  private func run(_ command: GUIEffectCommand) {
    switch command.name {
    case "timer.once":
      runTimerOnce(command.args)
    case "timer.interval":
      runTimerInterval(command.args)
    case "timer.debounce":
      runTimerDebounce(command.args)
    case "http.request":
      runHttpRequest(command.args)
    case "stream.sse":
      runSse(command.args)
    case "stream.ws":
      runWebSocket(command.args)
    case "stream.httpChunked":
      runHttpChunked(command.args)
    case "persist.defaults":
      runPersistDefaults(command.args)
    case "persist.file":
      runPersistFile(command.args)
    case "keychain.add":
      runKeychainAdd(command.args)
    case "keychain.query":
      runKeychainQuery(command.args)
    case "keychain.update":
      runKeychainUpdate(command.args)
    case "keychain.delete":
      runKeychainDelete(command.args)
    case "bridge.dispatch":
      runBridgeDispatch(command.args)
    default:
      break
    }
  }

  private func sendAction(_ value: GUIAnyValue?) {
    guard let action = value?.actionValue else { return }
    store.send(action)
  }

  private func runTimerOnce(_ args: [String: GUIAnyValue]) {
    let ms = args["ms"]?.intValue ?? 0
    let action = args["action"]
    Task {
      if ms > 0 {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      }
      await MainActor.run {
        self.sendAction(action)
      }
    }
  }

  private func runTimerInterval(_ args: [String: GUIAnyValue]) {
    let id = args["id"]?.stringValue ?? UUID().uuidString
    let ms = max(1, args["ms"]?.intValue ?? 1000)
    let action = args["action"]
    timerTasks[id]?.cancel()
    timerTasks[id] = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        await MainActor.run {
          self.sendAction(action)
        }
      }
    }
  }

  private func runTimerDebounce(_ args: [String: GUIAnyValue]) {
    let id = args["id"]?.stringValue ?? "default"
    let ms = max(1, args["ms"]?.intValue ?? 300)
    let action = args["action"]
    timerTasks[id]?.cancel()
    timerTasks[id] = Task {
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      await MainActor.run {
        self.sendAction(action)
      }
    }
  }

  private func runHttpRequest(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = (args["method"]?.stringValue ?? "GET").uppercased()

    if let headers = args["headers"]?.objectValue {
      for (k, v) in headers {
        if let value = v.stringValue {
          request.setValue(value, forHTTPHeaderField: k)
        }
      }
    }

    if let body = args["body"] {
      request.httpBody = dataFromAnyValue(body)
      if request.value(forHTTPHeaderField: "Content-Type") == nil {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
    }

    Task {
      do {
        _ = try await URLSession.shared.data(for: request)
        await MainActor.run {
          self.sendAction(args["onSuccess"])
        }
      } catch {
        await MainActor.run {
          self.sendAction(args["onError"])
        }
      }
    }
  }

  private func runSse(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }
    let taskId = args["id"]?.stringValue ?? UUID().uuidString

    streamTasks[taskId]?.cancel()
    streamTasks[taskId] = Task {
      var request = URLRequest(url: url)
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

      do {
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        await MainActor.run { self.sendAction(args["onOpen"]) }

        var dataBuffer = ""
        for try await line in bytes.lines {
          if Task.isCancelled { break }
          if line.isEmpty {
            if !dataBuffer.isEmpty {
              await MainActor.run { self.sendAction(args["onEvent"]) }
              dataBuffer = ""
            }
            continue
          }
          if line.hasPrefix("data:") {
            dataBuffer += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
          }
        }
      } catch {
        await MainActor.run { self.sendAction(args["onError"]) }
      }
    }
  }

  private func runWebSocket(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }

    let id = args["id"]?.stringValue ?? UUID().uuidString
    websocketTasks[id]?.cancel(with: .goingAway, reason: nil)

    let ws = URLSession.shared.webSocketTask(with: url)
    websocketTasks[id] = ws
    ws.resume()
    sendAction(args["onOpen"])

    func receiveLoop() {
      ws.receive { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          Task { @MainActor in
            self.sendAction(args["onMessage"])
          }
          receiveLoop()
        case .failure:
          Task { @MainActor in
            self.sendAction(args["onError"])
            self.sendAction(args["onClose"])
          }
        }
      }
    }

    receiveLoop()
  }

  private func runHttpChunked(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }

    let taskId = args["id"]?.stringValue ?? UUID().uuidString
    streamTasks[taskId]?.cancel()
    streamTasks[taskId] = Task {
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      do {
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        for try await _ in bytes {
          if Task.isCancelled { break }
          await MainActor.run { self.sendAction(args["onChunk"]) }
        }
        await MainActor.run { self.sendAction(args["onComplete"]) }
      } catch {
        await MainActor.run { self.sendAction(args["onError"]) }
      }
    }
  }

  private func runBridgeDispatch(_ args: [String: GUIAnyValue]) {
    guard let action = args["action"]?.actionValue else {
      return
    }

    guard let bridgePath = resolveBridgeDylibPath() else {
      logBridge("warning", "bridge dylib not found; skipping Nim-owned action", code: "GUI_BRIDGE_DYLIB_MISSING")
      return
    }

    let actionTag = UInt32(args["actionTag"]?.intValue ?? Int(guiActionTag(action)))
    let payload = makeBridgePayload(actionTag: actionTag, state: store.state)
    let correlation = UUID().uuidString
    let timeoutMs = bridgeTimeoutMs

    Task.detached { [weak self] in
      guard let self else { return }
      let started = Date()

      await MainActor.run {
        self.bridgeRuntime.maybeReload(path: bridgePath)
        if !self.bridgeRuntime.load(path: bridgePath) {
          self.logBridge("error", "failed to load bridge function table", code: "GUI_BRIDGE_ABI_MISMATCH")
        }
      }

      let result = await MainActor.run { self.bridgeRuntime.dispatch(payload: payload) }
      let elapsedMs = Date().timeIntervalSince(started) * 1000.0
      if elapsedMs > Double(timeoutMs) {
        await MainActor.run {
          self.logBridge("warning", "bridge dispatch exceeded timeout (\(Int(elapsedMs))ms)", code: "GUI_BRIDGE_TIMEOUT")
        }
      }

      if !result.diagnostics.isEmpty,
         let text = String(data: result.diagnostics, encoding: .utf8) {
        await MainActor.run {
          self.logBridge("info", "[\(correlation)] " + text, code: "GUI_BRIDGE_DIAGNOSTIC")
        }
      }

      if !result.statePatch.isEmpty {
        await MainActor.run {
          self.applyBridgeStatePatch(result.statePatch)
        }
      }

      let emittedTags = await MainActor.run {
        self.decodeBridgeActionTags(result.emittedActions)
      }
      if !emittedTags.isEmpty {
        await MainActor.run {
          for tag in emittedTags {
            if let emittedAction = guiActionFromTag(tag) {
              self.store.send(emittedAction)
            } else {
              self.logBridge("warning", "bridge emitted unsupported action tag \(tag)", code: "GUI_BRIDGE_EMIT_TAG")
            }
          }
        }
      }
    }
  }

  private func makeBridgePayload(actionTag: UInt32, state: GUIState?) -> Data {
    var payload = Data()
    var tag = actionTag.littleEndian
    withUnsafeBytes(of: &tag) { payload.append(contentsOf: $0) }
    let stateBlob: Data
    if let state, let encoded = try? JSONEncoder().encode(state) {
      stateBlob = encoded
    } else {
      stateBlob = Data()
    }
    var stateLen: UInt32 = UInt32(min(stateBlob.count, Int(UInt32.max)))
    withUnsafeBytes(of: &stateLen) { payload.append(contentsOf: $0) }
    if stateLen > 0 {
      payload.append(stateBlob.prefix(Int(stateLen)))
    }
    return payload
  }

  private func decodeBridgeActionTags(_ data: Data) -> [UInt32] {
    if data.isEmpty {
      return []
    }
    guard data.count % 4 == 0 else {
      logBridge("warning", "bridge emitted malformed action-tag payload", code: "GUI_BRIDGE_EMIT_FORMAT")
      return []
    }

    var tags: [UInt32] = []
    tags.reserveCapacity(data.count / 4)
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var index = 0
      while index + 3 < bytes.count {
        let value =
          UInt32(bytes[index]) |
          (UInt32(bytes[index + 1]) << 8) |
          (UInt32(bytes[index + 2]) << 16) |
          (UInt32(bytes[index + 3]) << 24)
        tags.append(value)
        index += 4
      }
    }
    return tags
  }

  private func applyBridgeStatePatch(_ patchData: Data) {
    guard !patchData.isEmpty else { return }

    guard let patchObject = try? JSONSerialization.jsonObject(with: patchData),
          let patch = patchObject as? [String: Any] else {
      logBridge("warning", "bridge emitted invalid state patch payload", code: "GUI_BRIDGE_STATE_PATCH")
      return
    }

    do {
      let currentStateData = try JSONEncoder().encode(store.state)
      var mergedState: [String: Any] =
        (try JSONSerialization.jsonObject(with: currentStateData) as? [String: Any]) ?? [:]

      for (key, value) in patch {
        mergedState[key] = value
      }

      let mergedStateData = try JSONSerialization.data(withJSONObject: mergedState)
      let decodedState = try JSONDecoder().decode(GUIState.self, from: mergedStateData)
      store.state = decodedState
    } catch {
      logBridge("warning", "failed to apply bridge state patch: \(error)", code: "GUI_BRIDGE_STATE_PATCH")
    }
  }

  private func resolveBridgeDylibPath() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let direct = env["GUI_BRIDGE_DYLIB"], !direct.isEmpty, FileManager.default.fileExists(atPath: direct) {
      return direct
    }

    var candidates: [String] = []
    if let frameworkDir = Bundle.main.privateFrameworksPath {
      candidates.append((frameworkDir as NSString).appendingPathComponent("libgui_bridge_latest.dylib"))
      candidates.append((frameworkDir as NSString).appendingPathComponent("libgui_bridge_latest.so"))
    }

    let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
    candidates.append(bundleURL.appendingPathComponent("Contents/Frameworks/libgui_bridge_latest.dylib").path)
    candidates.append(bundleURL.appendingPathComponent("Contents/Frameworks/libgui_bridge_latest.so").path)

    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.dylib").path)
      candidates.append(resourceURL.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.so").path)
    }

    for path in candidates where FileManager.default.fileExists(atPath: path) {
      return path
    }

    if env["GUI_BRIDGE_ALLOW_EXTERNAL"] == "1" {
      var cursor = bundleURL
      for _ in 0..<6 {
        cursor.deleteLastPathComponent()
        candidates.append(cursor.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.dylib").path)
        candidates.append(cursor.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.so").path)
      }
      for path in candidates where FileManager.default.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }

  private func logBridge(_ level: String, _ message: String, code: String) {
    print("[GUIBridge][\(level)][\(code)] \(message)")
  }

  private func runPersistDefaults(_ args: [String: GUIAnyValue]) {
    guard let key = args["key"]?.stringValue, let value = args["value"] else { return }
    UserDefaults.standard.set(foundationValue(from: value), forKey: key)
  }

  private func runPersistFile(_ args: [String: GUIAnyValue]) {
    guard let key = args["key"]?.stringValue, let value = args["value"] else { return }

    let fileURL: URL
    if let path = args["path"]?.stringValue {
      fileURL = URL(fileURLWithPath: path)
    } else {
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
      fileURL = appSupport.appendingPathComponent("gui-persist.json")
    }

    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      var payload: [String: Any] = [:]
      if let data = try? Data(contentsOf: fileURL),
         let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        payload = existing
      }
      payload[key] = foundationValue(from: value)
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // best-effort persistence in v1 runtime
    }
  }

  private func runKeychainAdd(_ args: [String: GUIAnyValue]) {
    guard let query = makeKeychainBaseQuery(args) else { return }
    var final = query
    if let value = args["value"] {
      final[kSecValueData as String] = dataFromAnyValue(value) ?? Data()
    }
    _ = SecItemAdd(final as CFDictionary, nil)
  }

  private func runKeychainQuery(_ args: [String: GUIAnyValue]) {
    guard var query = makeKeychainBaseQuery(args) else { return }
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    if let extra = args["queryAttrs"]?.objectValue {
      mergeKeychainAttributes(into: &query, attrs: extra)
    }

    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    if status == errSecSuccess {
      sendAction(args["onSuccess"])
    } else {
      sendAction(args["onError"])
    }
  }

  private func runKeychainUpdate(_ args: [String: GUIAnyValue]) {
    guard let query = makeKeychainBaseQuery(args) else { return }
    var updates: [String: Any] = [:]
    if let value = args["value"] {
      updates[kSecValueData as String] = dataFromAnyValue(value) ?? Data()
    }
    if let attrs = args["attrs"]?.objectValue {
      mergeKeychainAttributes(into: &updates, attrs: attrs)
    }
    _ = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
  }

  private func runKeychainDelete(_ args: [String: GUIAnyValue]) {
    guard let query = makeKeychainBaseQuery(args) else { return }
    _ = SecItemDelete(query as CFDictionary)
  }

  private func makeKeychainBaseQuery(_ args: [String: GUIAnyValue]) -> [String: Any]? {
    guard let service = args["service"]?.stringValue,
          let account = args["account"]?.stringValue else {
      return nil
    }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]

    if let attrs = args["attrs"]?.objectValue {
      mergeKeychainAttributes(into: &query, attrs: attrs)
    }

    return query
  }

  private func mergeKeychainAttributes(into query: inout [String: Any], attrs: [String: GUIAnyValue]) {
    for (rawKey, rawValue) in attrs {
      if let known = keychainKnownAttribute(for: rawKey) {
        query[known as String] = foundationValue(from: rawValue)
      } else if rawKey.hasPrefix("kSec") {
        query[rawKey] = foundationValue(from: rawValue)
      }
    }
  }

  private func keychainKnownAttribute(for name: String) -> CFString? {
    switch name {
    case "kSecClass": return kSecClass
    case "kSecAttrAccessible": return kSecAttrAccessible
    case "kSecAttrAccessControl": return kSecAttrAccessControl
    case "kSecAttrAccessGroup": return kSecAttrAccessGroup
    case "kSecAttrSynchronizable": return kSecAttrSynchronizable
    case "kSecAttrService": return kSecAttrService
    case "kSecAttrAccount": return kSecAttrAccount
    case "kSecAttrLabel": return kSecAttrLabel
    case "kSecAttrDescription": return kSecAttrDescription
    case "kSecAttrComment": return kSecAttrComment
    case "kSecAttrGeneric": return kSecAttrGeneric
    case "kSecAttrCreator": return kSecAttrCreator
    case "kSecAttrType": return kSecAttrType
    case "kSecAttrIsInvisible": return kSecAttrIsInvisible
    case "kSecAttrIsNegative": return kSecAttrIsNegative
    case "kSecAttrApplicationTag": return kSecAttrApplicationTag
    case "kSecAttrKeyType": return kSecAttrKeyType
    case "kSecAttrKeySizeInBits": return kSecAttrKeySizeInBits
    case "kSecAttrEffectiveKeySize": return kSecAttrEffectiveKeySize
    case "kSecAttrCanEncrypt": return kSecAttrCanEncrypt
    case "kSecAttrCanDecrypt": return kSecAttrCanDecrypt
    case "kSecAttrCanDerive": return kSecAttrCanDerive
    case "kSecAttrCanSign": return kSecAttrCanSign
    case "kSecAttrCanVerify": return kSecAttrCanVerify
    case "kSecAttrCanWrap": return kSecAttrCanWrap
    case "kSecAttrCanUnwrap": return kSecAttrCanUnwrap
    case "kSecReturnData": return kSecReturnData
    case "kSecReturnAttributes": return kSecReturnAttributes
    case "kSecReturnRef": return kSecReturnRef
    case "kSecReturnPersistentRef": return kSecReturnPersistentRef
    case "kSecMatchLimit": return kSecMatchLimit
    case "kSecMatchItemList": return kSecMatchItemList
    case "kSecMatchSearchList": return kSecMatchSearchList
    case "kSecMatchPolicy": return kSecMatchPolicy
    case "kSecMatchIssuers": return kSecMatchIssuers
    case "kSecMatchEmailAddressIfPresent": return kSecMatchEmailAddressIfPresent
    case "kSecMatchSubjectContains": return kSecMatchSubjectContains
    case "kSecMatchCaseInsensitive": return kSecMatchCaseInsensitive
    case "kSecMatchTrustedOnly": return kSecMatchTrustedOnly
    case "kSecMatchValidOnDate": return kSecMatchValidOnDate
    default: return nil
    }
  }

  private func foundationValue(from value: GUIAnyValue) -> Any {
    switch value {
    case let .string(v): return v
    case let .int(v): return v
    case let .double(v): return v
    case let .bool(v): return v
    case let .object(v):
      var out: [String: Any] = [:]
      for (k, item) in v { out[k] = foundationValue(from: item) }
      return out
    case let .array(v):
      return v.map { foundationValue(from: $0) }
    case .action:
      return "<action>"
    case .null:
      return NSNull()
    }
  }

  private func dataFromAnyValue(_ value: GUIAnyValue) -> Data? {
    switch value {
    case let .string(v):
      return Data(v.utf8)
    case let .int(v):
      return Data(String(v).utf8)
    case let .double(v):
      return Data(String(v).utf8)
    case let .bool(v):
      return Data((v ? "true" : "false").utf8)
    case .action:
      return nil
    case .null:
      return nil
    case let .array(v):
      let payload = v.map { foundationValue(from: $0) }
      return try? JSONSerialization.data(withJSONObject: payload)
    case let .object(v):
      var payload: [String: Any] = [:]
      for (k, item) in v { payload[k] = foundationValue(from: item) }
      return try? JSONSerialization.data(withJSONObject: payload)
    }
  }
}
