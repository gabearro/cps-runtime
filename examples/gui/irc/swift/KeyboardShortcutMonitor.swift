#if os(macOS)
import AppKit
import Foundation

/// Intercepts keyboard events via NSEvent.addLocalMonitorForEvents before
/// macOS default menu items (File > New Window = Cmd+N, File > Print = Cmd+P,
/// File > Close = Cmd+W, Edit > New Tab = Cmd+T) can consume them.
///
/// Keybindings are loaded from the store's `keybinds` JSON state field, so
/// they can be remapped at runtime and persisted across launches.
@MainActor
final class KeyboardShortcutMonitor {

    struct Binding {
        let key: String              // lowercased character, e.g. "n", "[", "1"
        let modifiers: NSEvent.ModifierFlags
        let actionTag: UInt32
    }

    private var monitor: Any?
    private weak var store: GUIStore?
    private var bindings: [Binding] = []

    // Recording mode for keybind re-mapping
    private var recordingCallback: ((String, String) -> Void)? = nil
    var isRecording: Bool { recordingCallback != nil }

    func startRecording(completion: @escaping (String, String) -> Void) {
        recordingCallback = completion
    }

    func cancelRecording() {
        recordingCallback = nil
    }

    // ---- Default binding table -------------------------------------------------

    /// The canonical set of keybindings. Each entry maps a human-readable id to
    /// a key + modifier + action-tag triple. The action tags must match the
    /// declaration order in app.gui (same as bridge.nim constants).
    private static let defaultBindings: [(id: String, key: String, modifiers: NSEvent.ModifierFlags, tag: UInt32)] = [
        // Navigation
        ("channelSwitcher",   "k", .command,                64),  // ShowChannelSwitcher
        ("prevChannel",       "[", .command,                60),  // PrevChannel
        ("nextChannel",       "]", .command,                61),  // NextChannel
        ("nextUnread",        "n", .command,                62),  // NextUnreadChannel
        ("prevUnread",        "p", .command,                70),  // PrevUnreadChannel
        ("prevServer",        "[", [.command, .shift],      68),  // PrevServer
        ("nextServer",        "]", [.command, .shift],      69),  // NextServer

        // Channel management
        ("joinChannel",       "t", .command,                32),  // ShowJoinChannel
        ("closeChannel",      "w", .command,                 9),  // CloseChannel
        ("clearScrollback",   "l", .command,                63),  // ClearScrollback

        // View / input
        ("toggleUserList",    "u", [.command, .shift],      12),  // ToggleUserList
        ("connectToServer",   "c", [.command, .shift],      13),  // ShowConnectForm

        // Channel by index (Cmd+1..9)
        ("channel1", "1", .command, 1001),
        ("channel2", "2", .command, 1002),
        ("channel3", "3", .command, 1003),
        ("channel4", "4", .command, 1004),
        ("channel5", "5", .command, 1005),
        ("channel6", "6", .command, 1006),
        ("channel7", "7", .command, 1007),
        ("channel8", "8", .command, 1008),
        ("channel9", "9", .command, 1009),
    ]

    // Synthetic tag range for SwitchChannelByIndex
    private static let channelIndexTagBase: UInt32 = 1000

    // ---- Lifecycle -------------------------------------------------------------

    func start(store: GUIStore) {
        self.store = store
        loadDefaultBindings()
        reloadBindings(from: store.state.keybinds)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    // ---- Binding management ----------------------------------------------------

    private func loadDefaultBindings() {
        bindings = Self.defaultBindings.map { entry in
            Binding(key: entry.key, modifiers: entry.modifiers, actionTag: entry.tag)
        }
    }

    func reloadBindings(from json: String) {
        guard !json.isEmpty, json != "{}" else {
            loadDefaultBindings()
            return
        }

        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            // If JSON is invalid or not an array, keep current bindings
            return
        }

        var newBindings: [Binding] = []
        for entry in parsed {
            guard let key = entry["key"] as? String,
                  let modsStr = entry["modifiers"] as? String,
                  let tagNum = entry["actionTag"] as? Int
            else { continue }

            let mods = Self.parseModifiers(modsStr)
            newBindings.append(Binding(key: key.lowercased(), modifiers: mods, actionTag: UInt32(tagNum)))
        }

        if !newBindings.isEmpty {
            bindings = newBindings
        }
    }

    // ---- Event handling --------------------------------------------------------

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)  // Ignore caps lock for matching

        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return event
        }

        // Recording mode: capture the key combo for re-mapping
        if let callback = recordingCallback {
            // Escape cancels recording
            if event.keyCode == 53 {
                recordingCallback = nil
                return nil
            }
            // Ignore modifier-only presses (no character key)
            if chars.isEmpty { return event }
            let modStr = Self.formatModifiersToString(flags)
            callback(chars, modStr)
            recordingCallback = nil
            return nil  // Consume the event
        }

        for binding in bindings {
            if chars == binding.key && flags == binding.modifiers {
                dispatchAction(for: binding.actionTag)
                return nil  // Consume event — prevents macOS menu from handling it
            }
        }

        return event  // Pass through to normal handling
    }

    private func dispatchAction(for tag: UInt32) {
        guard let store else { return }

        // Handle synthetic channel-index tags
        if tag > Self.channelIndexTagBase && tag <= Self.channelIndexTagBase + 9 {
            let index = Int(tag - Self.channelIndexTagBase) - 1
            store.send(.switchChannelByIndex(index: index))
            return
        }

        // Map known tags to GUIAction cases
        if let action = Self.actionForTag(tag) {
            store.send(action)
        }
    }

    private static func actionForTag(_ tag: UInt32) -> GUIAction? {
        switch tag {
        case  9: return .closeChannel(channelName: "")
        case 12: return .toggleUserList
        case 13: return .showConnectForm
        case 32: return .showJoinChannel
        case 60: return .prevChannel
        case 61: return .nextChannel
        case 62: return .nextUnreadChannel
        case 63: return .clearScrollback
        case 64: return .showChannelSwitcher
        case 68: return .prevServer
        case 69: return .nextServer
        case 70: return .prevUnreadChannel
        default: return nil
        }
    }

    // ---- Modifier parsing / formatting ------------------------------------------

    private static func parseModifiers(_ str: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let parts = str.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            switch part {
            case "command", "cmd":
                flags.insert(.command)
            case "shift":
                flags.insert(.shift)
            case "option", "alt":
                flags.insert(.option)
            case "control", "ctrl":
                flags.insert(.control)
            default:
                break
            }
        }
        return flags
    }

    /// Convert NSEvent.ModifierFlags back to the bridge string format (e.g. "command+shift")
    static func formatModifiersToString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("command") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.control) { parts.append("control") }
        return parts.isEmpty ? "" : parts.joined(separator: "+")
    }

    /// Convert key + modifiers strings to a human-readable display (e.g. "⌘⇧K")
    static func formatShortcutDisplay(key: String, modifiers: String) -> String {
        var display = ""
        let parts = modifiers.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        // macOS convention: ⌃⌥⇧⌘ order
        if parts.contains("control") { display += "\u{2303}" }
        if parts.contains("option") || parts.contains("alt") { display += "\u{2325}" }
        if parts.contains("shift") { display += "\u{21E7}" }
        if parts.contains("command") || parts.contains("cmd") { display += "\u{2318}" }

        // Special key names
        switch key.lowercased() {
        case "return", "\r", "\n":  display += "\u{21A9}"
        case "tab", "\t":           display += "\u{21E5}"
        case "delete", "\u{7F}":    display += "\u{232B}"
        case "escape":              display += "\u{238B}"
        case "space", " ":          display += "\u{2423}"
        default:                    display += key.uppercased()
        }
        return display
    }
}
#endif
