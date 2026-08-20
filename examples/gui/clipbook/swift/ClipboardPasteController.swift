#if os(macOS)
import AppKit
import ApplicationServices

@MainActor
final class ClipboardPasteController {
    static let shared = ClipboardPasteController()
    private weak var lastExternalApp: NSRunningApplication?

    func rememberFrontmostApp() {
        let app = NSWorkspace.shared.frontmostApplication
        if app?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = app
        }
    }

    var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func pasteIntoLastApp() {
        guard requestAccessibilityIfNeeded(), let app = lastExternalApp else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
#endif
