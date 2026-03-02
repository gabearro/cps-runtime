import SwiftUI
import AppKit

/// A message input field that intercepts Tab, Up Arrow, and Down Arrow keys before
/// SwiftUI's focus navigation system processes them. This enables tab-completion
/// and input history navigation in the IRC chat input.
///
/// Usage from .gui DSL: KeyInterceptingTextField(store: store, isDark: isDark)
/// The view reads/writes inputText from the store and sends actions for key events.
struct KeyInterceptingTextField: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    var body: some View {
        let inputBg = isDark ? Color.white.opacity(0.08) : Color(red: 0.94, green: 0.94, blue: 0.95)
        let inputStroke = isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        let inputFontSize = CGFloat(store.state.fontSize)

        InterceptingTextFieldWrapper(
            text: $store.state.inputText,
            placeholder: "Message \(store.state.activeChannelName)...",
            font: NSFont.systemFont(ofSize: inputFontSize),
            onSubmit: { store.send(.sendMessage) },
            onTabPress: { store.send(.tabComplete) },
            onUpArrow: { store.send(.historyUp) },
            onDownArrow: { store.send(.historyDown) },
            onTextChange: { store.send(.inputChanged) },
            onEscapePress: {
                if store.state.completionActive {
                    store.state.completionActive = false
                    store.state.completionSuggestions = []
                    store.state.completionIndex = -1
                    store.state.completionSelectIndex = -1
                }
            }
        )
        .frame(height: max(inputFontSize + 16, 28))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(inputBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(inputStroke, lineWidth: 0.5)
        )
    }
}

// MARK: - NSViewRepresentable

private struct InterceptingTextFieldWrapper: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var onSubmit: () -> Void
    var onTabPress: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onTextChange: () -> Void
    var onEscapePress: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.font = font
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
            // Move cursor to end when text changes externally (e.g. history navigation)
            if let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: nsView.stringValue.count, length: 0)
            }
        }
        nsView.placeholderString = placeholder
        nsView.font = font
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onTabPress = onTabPress
        context.coordinator.onUpArrow = onUpArrow
        context.coordinator.onDownArrow = onDownArrow
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onEscapePress = onEscapePress
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onTabPress: onTabPress,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onTextChange: onTextChange,
            onEscapePress: onEscapePress
        )
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onTabPress: () -> Void
        var onUpArrow: () -> Void
        var onDownArrow: () -> Void
        var onTextChange: () -> Void
        var onEscapePress: () -> Void

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onTabPress: @escaping () -> Void,
            onUpArrow: @escaping () -> Void,
            onDownArrow: @escaping () -> Void,
            onTextChange: @escaping () -> Void,
            onEscapePress: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onTabPress = onTabPress
            self.onUpArrow = onUpArrow
            self.onDownArrow = onDownArrow
            self.onTextChange = onTextChange
            self.onEscapePress = onEscapePress
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
            onTextChange()
        }

        /// Intercept key commands from the field editor during active editing.
        /// This is the ONLY reliable way to capture Tab, arrows, and Enter
        /// when NSTextField is in editing mode — keyDown on the text field
        /// subclass does NOT fire because the field editor handles events.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTabPress()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                onUpArrow()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                onDownArrow()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscapePress()
                return true
            }
            return false
        }
    }
}
