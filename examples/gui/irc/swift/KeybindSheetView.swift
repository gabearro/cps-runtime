#if os(macOS)
import SwiftUI
import AppKit

/// Dynamic keybind sheet that reads current bindings from the store's `keybinds`
/// JSON state field. Supports re-mapping: click a shortcut badge to enter recording
/// mode, then press a new key combo. Escape cancels recording.
struct KeybindSheetView: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    @State private var recordingId: String? = nil

    private struct ParsedBind: Identifiable {
        let id: String
        let key: String
        let modifiers: String
        let label: String
        let actionTag: Int
    }

    private static let navIds: Set<String> = [
        "channelSwitcher", "prevChannel", "nextChannel",
        "nextUnread", "prevUnread", "prevServer", "nextServer"
    ]
    private static let chanIds: Set<String> = [
        "joinChannel", "closeChannel", "clearScrollback"
    ]
    private static let viewIds: Set<String> = [
        "toggleUserList", "connectToServer"
    ]

    // Fixed shortcuts handled by KeyInterceptingTextField or .keyboardShortcut
    private static let fixedShortcuts: [(label: String, display: String)] = [
        ("Send Message",  "\u{21A9}"),        // ↩
        ("Tab Complete",  "\u{21E5}"),         // ⇥
        ("History Up",    "\u{2191}"),          // ↑
        ("History Down",  "\u{2193}"),          // ↓
        ("Settings",      "\u{2318},"),         // ⌘,
        ("Search",        "\u{2318}F"),         // ⌘F
    ]

    var body: some View {
        let fg = isDark ? Color(red: 0.98, green: 0.98, blue: 0.99)
                        : Color(red: 0.11, green: 0.11, blue: 0.12)
        let sectionColor = isDark ? Color(red: 0.58, green: 0.58, blue: 0.61)
                                  : Color(red: 0.60, green: 0.60, blue: 0.63)
        let divider = isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
        let cardBg = isDark ? Color(red: 0.19, green: 0.19, blue: 0.20)
                            : Color(red: 0.96, green: 0.96, blue: 0.97)
        let cardBorder = isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)

        let bindings = parseBindings()
        let nav = bindings.filter { Self.navIds.contains($0.id) }
        let chan = bindings.filter { Self.chanIds.contains($0.id) }
        let jump = bindings.filter { $0.id.hasPrefix("channel") && $0.id.count == 8 }
        let view = bindings.filter { Self.viewIds.contains($0.id) }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                remappableSection("NAVIGATION", entries: nav,
                    fg: fg, sectionColor: sectionColor, divider: divider,
                    cardBg: cardBg, cardBorder: cardBorder)
                remappableSection("CHANNELS", entries: chan,
                    fg: fg, sectionColor: sectionColor, divider: divider,
                    cardBg: cardBg, cardBorder: cardBorder)
                remappableSection("JUMP TO CHANNEL", entries: jump,
                    fg: fg, sectionColor: sectionColor, divider: divider,
                    cardBg: cardBg, cardBorder: cardBorder)
                remappableSection("VIEW", entries: view,
                    fg: fg, sectionColor: sectionColor, divider: divider,
                    cardBg: cardBg, cardBorder: cardBorder)
                fixedSection(fg: fg, sectionColor: sectionColor, divider: divider,
                    cardBg: cardBg, cardBorder: cardBorder)
            }
            .padding(24)
        }
        .onDisappear {
            if recordingId != nil {
                store.shortcutMonitor.cancelRecording()
                recordingId = nil
            }
        }
    }

    // MARK: - Section builders

    @ViewBuilder
    private func remappableSection(
        _ title: String,
        entries: [ParsedBind],
        fg: Color, sectionColor: Color, divider: Color,
        cardBg: Color, cardBorder: Color
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(sectionColor)
                    .tracking(0.6)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        if idx > 0 {
                            Rectangle().fill(divider).frame(height: 1)
                                .padding(.horizontal, 12)
                        }
                        remappableRow(entry: entry, fg: fg)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(cardBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cardBorder, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func fixedSection(
        fg: Color, sectionColor: Color, divider: Color,
        cardBg: Color, cardBorder: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INPUT (FIXED)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(sectionColor)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.fixedShortcuts.enumerated()), id: \.offset) { idx, entry in
                    if idx > 0 {
                        Rectangle().fill(divider).frame(height: 1)
                            .padding(.horizontal, 12)
                    }
                    fixedRow(label: entry.label, display: entry.display, fg: fg)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10).fill(cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Row views

    @ViewBuilder
    private func remappableRow(entry: ParsedBind, fg: Color) -> some View {
        let fgSec = isDark ? Color(red: 0.76, green: 0.76, blue: 0.78)
                           : Color(red: 0.42, green: 0.42, blue: 0.44)
        let isRecording = recordingId == entry.id
        let display = KeyboardShortcutMonitor.formatShortcutDisplay(
            key: entry.key, modifiers: entry.modifiers)

        HStack {
            Text(entry.label)
                .font(.system(size: 12))
                .foregroundColor(fg)

            Spacer()

            Button(action: { startRecording(for: entry.id) }) {
                if isRecording {
                    Text("Press a key\u{2026}")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.04, green: 0.52, blue: 1.0))
                        )
                } else {
                    Text(display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(fgSec)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isDark ? Color.white.opacity(0.08)
                                             : Color.black.opacity(0.05))
                        )
                }
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func fixedRow(label: String, display: String, fg: Color) -> some View {
        let fgSec = isDark ? Color(red: 0.76, green: 0.76, blue: 0.78)
                           : Color(red: 0.42, green: 0.42, blue: 0.44)
        let fgTertiary = isDark ? Color(red: 0.55, green: 0.55, blue: 0.57)
                                : Color(red: 0.56, green: 0.56, blue: 0.58)

        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(fg)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundColor(fgTertiary)

                Text(display)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgSec)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isDark ? Color.white.opacity(0.05)
                                         : Color.black.opacity(0.03))
                    )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }

    // MARK: - Recording

    private func startRecording(for id: String) {
        // Cancel any existing recording
        if recordingId != nil {
            store.shortcutMonitor.cancelRecording()
        }

        recordingId = id
        store.shortcutMonitor.startRecording { key, modifiers in
            DispatchQueue.main.async {
                store.send(.updateKeybind(id: id, key: key, modifiers: modifiers))
                recordingId = nil
            }
        }
    }

    // MARK: - JSON parsing

    private func parseBindings() -> [ParsedBind] {
        let json = store.state.keybinds
        guard !json.isEmpty, json != "{}",
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let key = entry["key"] as? String,
                  let mods = entry["modifiers"] as? String,
                  let label = entry["label"] as? String,
                  let tag = entry["actionTag"] as? Int
            else { return nil }
            return ParsedBind(id: id, key: key, modifiers: mods,
                              label: label, actionTag: tag)
        }
    }
}
#endif
