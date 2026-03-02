#if os(macOS)
import SwiftUI

/// Custom SwiftUI view for editing ignore, highlight, and join/part mute lists.
/// Each list is stored as a JSON array string in the store's state.
struct SettingsListsSection: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    @State private var ignoreInput: String = ""
    @State private var highlightInput: String = ""
    @State private var muteInput: String = ""

    var body: some View {
        let fg = isDark ? Color(red: 0.98, green: 0.98, blue: 0.99)
                        : Color(red: 0.11, green: 0.11, blue: 0.12)
        let fgSecondary = isDark ? Color(red: 0.76, green: 0.76, blue: 0.78)
                                 : Color(red: 0.44, green: 0.44, blue: 0.46)
        let fgTertiary = isDark ? Color(red: 0.62, green: 0.62, blue: 0.65)
                                : Color(red: 0.56, green: 0.56, blue: 0.58)
        let sectionColor = isDark ? Color(red: 0.58, green: 0.58, blue: 0.61)
                                  : Color(red: 0.60, green: 0.60, blue: 0.63)
        let cardBg = isDark ? Color(red: 0.19, green: 0.19, blue: 0.20)
                            : Color(red: 0.96, green: 0.96, blue: 0.97)
        let cardBorder = isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        let fieldBg = isDark ? Color.black.opacity(0.25) : Color.white
        let fieldBorder = isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.10)
        let divider = isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
        let dangerColor = Color(red: 1.0, green: 0.27, blue: 0.23)

        let ignoreList = parseJsonArray(store.state.ignoreListJson)
        let highlightList = parseJsonArray(store.state.highlightWordsJson)
        let muteList = parseJsonArray(store.state.joinPartMuteListJson)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // IGNORE LIST
                listSection(
                    title: "IGNORE LIST",
                    description: "Messages from ignored nicks are hidden",
                    items: ignoreList,
                    input: $ignoreInput,
                    placeholder: "Add nick...",
                    onAdd: {
                        let nick = ignoreInput.trimmingCharacters(in: .whitespaces)
                        guard !nick.isEmpty else { return }
                        var updated = ignoreList
                        let lower = nick.lowercased()
                        if !updated.contains(lower) { updated.append(lower) }
                        ignoreInput = ""
                        store.send(.updateIgnoreList(json: serializeArray(updated)))
                    },
                    onRemove: { index in
                        var updated = ignoreList
                        updated.remove(at: index)
                        store.send(.updateIgnoreList(json: serializeArray(updated)))
                    },
                    fg: fg, fgSecondary: fgSecondary, fgTertiary: fgTertiary,
                    sectionColor: sectionColor, cardBg: cardBg, cardBorder: cardBorder,
                    fieldBg: fieldBg, fieldBorder: fieldBorder, divider: divider,
                    dangerColor: dangerColor
                )

                // HIGHLIGHT WORDS
                listSection(
                    title: "HIGHLIGHT WORDS",
                    description: "Messages containing these words are highlighted",
                    items: highlightList,
                    input: $highlightInput,
                    placeholder: "Add word...",
                    onAdd: {
                        let word = highlightInput.trimmingCharacters(in: .whitespaces)
                        guard !word.isEmpty else { return }
                        var updated = highlightList
                        let lower = word.lowercased()
                        if !updated.contains(lower) { updated.append(lower) }
                        highlightInput = ""
                        store.send(.updateHighlightWords(json: serializeArray(updated)))
                    },
                    onRemove: { index in
                        var updated = highlightList
                        updated.remove(at: index)
                        store.send(.updateHighlightWords(json: serializeArray(updated)))
                    },
                    fg: fg, fgSecondary: fgSecondary, fgTertiary: fgTertiary,
                    sectionColor: sectionColor, cardBg: cardBg, cardBorder: cardBorder,
                    fieldBg: fieldBg, fieldBorder: fieldBorder, divider: divider,
                    dangerColor: dangerColor
                )

                // JOIN/PART MUTE LIST
                listSection(
                    title: "JOIN/PART MUTE LIST",
                    description: "Join/part/quit messages from these nicks are always hidden",
                    items: muteList,
                    input: $muteInput,
                    placeholder: "Add nick...",
                    onAdd: {
                        let nick = muteInput.trimmingCharacters(in: .whitespaces)
                        guard !nick.isEmpty else { return }
                        var updated = muteList
                        let lower = nick.lowercased()
                        if !updated.contains(lower) { updated.append(lower) }
                        muteInput = ""
                        store.send(.updateJoinPartMuteList(json: serializeArray(updated)))
                    },
                    onRemove: { index in
                        var updated = muteList
                        updated.remove(at: index)
                        store.send(.updateJoinPartMuteList(json: serializeArray(updated)))
                    },
                    fg: fg, fgSecondary: fgSecondary, fgTertiary: fgTertiary,
                    sectionColor: sectionColor, cardBg: cardBg, cardBorder: cardBorder,
                    fieldBg: fieldBg, fieldBorder: fieldBorder, divider: divider,
                    dangerColor: dangerColor
                )
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func listSection(
        title: String,
        description: String,
        items: [String],
        input: Binding<String>,
        placeholder: String,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        fg: Color, fgSecondary: Color, fgTertiary: Color,
        sectionColor: Color, cardBg: Color, cardBorder: Color,
        fieldBg: Color, fieldBorder: Color, divider: Color,
        dangerColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(sectionColor)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField(placeholder, text: input)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 13))
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(fieldBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(fieldBorder, lineWidth: 0.5)
                        )
                        .onSubmit { onAdd() }

                    Button(action: onAdd) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Color(red: 0.039, green: 0.518, blue: 1.0))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(fgTertiary)

                if !items.isEmpty {
                    Rectangle()
                        .fill(divider)
                        .frame(height: 1)

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(item)
                                    .font(.system(size: 13))
                                    .foregroundColor(fg)

                                Spacer()

                                Button(action: { onRemove(index) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(fgSecondary.opacity(0.6))
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)

                            if index < items.count - 1 {
                                Rectangle()
                                    .fill(divider)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
    }

    private func parseJsonArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    private func serializeArray(_ arr: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }
}
#endif
