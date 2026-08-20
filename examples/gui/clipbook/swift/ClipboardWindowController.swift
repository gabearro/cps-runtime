#if os(macOS)
import AppKit

@MainActor
final class ClipboardWindowController {
    static let shared = ClipboardWindowController()
    private let frameKey = "clipbook.window.frame"
    private weak var mainWindow: NSWindow?

    func restore(window: NSWindow?) {
        guard let window,
              let frameString = UserDefaults.standard.string(forKey: frameKey) else { return }
        window.setFrame(NSRectFromString(frameString), display: true)
    }

    func persist(window: NSWindow?) {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
    }

    func register(window: NSWindow?) {
        guard let window, !window.isSheet, !(window is NSPanel) else { return }
        window.identifier = NSUserInterfaceItemIdentifier("clipbook.main-window")

        if let existing = mainWindow, existing !== window {
            window.orderOut(nil)
            window.close()
            if !existing.isVisible {
                show(existing)
            }
            return
        }

        mainWindow = window
        restore(window: window)
        collapseDuplicateWindows(keeping: window)
    }

    func toggleClipBookWindow() {
        let window = mainClipBookWindow()
        if let window, window.isVisible, NSApp.isActive {
            persist(window: window)
            window.orderOut(nil)
            return
        }
        show(window)
    }

    func showClipBookWindow() {
        show(mainClipBookWindow())
    }

    func hideClipBookWindow() {
        for window in NSApp.windows where !window.isSheet {
            window.orderOut(nil)
        }
    }

    func focusSearch() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func mainClipBookWindow() -> NSWindow? {
        if let mainWindow {
            return mainWindow
        }
        let candidates = NSApp.windows.filter { window in
            !window.isSheet && !(window is NSPanel)
        }
        if let identified = candidates.first(where: { $0.identifier?.rawValue == "clipbook.main-window" }) {
            mainWindow = identified
            return identified
        }
        if let titled = candidates.first(where: { $0.title == "ClipBook" }) {
            mainWindow = titled
            return titled
        }
        if let first = candidates.first {
            mainWindow = first
            return first
        }
        return nil
    }

    private func show(_ window: NSWindow?) {
        guard let window else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        collapseDuplicateWindows(keeping: window)
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func collapseDuplicateWindows(keeping keeper: NSWindow) {
        for window in NSApp.windows where window !== keeper && !window.isSheet && !(window is NSPanel) {
            if window.title == "ClipBook" || window.identifier?.rawValue == "clipbook.main-window" {
                window.orderOut(nil)
                window.close()
            }
        }
    }
}
#endif
