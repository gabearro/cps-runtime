#if os(macOS)
import SwiftUI

/// Custom SwiftUI view for listing and editing server configurations.
/// When opened from Settings tab 5, shows a list of all servers with edit/duplicate/delete.
/// When editingServerId >= 0, shows a form to edit that server's configuration.
struct ServerEditorView: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    // Local form state, synced from editServerJson when editing starts
    @State private var formName: String = ""
    @State private var formHost: String = ""
    @State private var formPort: String = ""
    @State private var formNick: String = ""
    @State private var formUseTls: Bool = false
    @State private var formPassword: String = ""
    @State private var formSaslUser: String = ""
    @State private var formSaslPass: String = ""
    @State private var formChannels: [String] = []
    @State private var newChannelText: String = ""
    @State private var isEditing: Bool = false
    @State private var lastEditingId: Int = -1

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
        let accentColor = Color(red: 0.039, green: 0.518, blue: 1.0)
        let dangerColor = Color(red: 1.0, green: 0.27, blue: 0.23)
        let successColor = Color(red: 0.19, green: 0.82, blue: 0.35)

        let editingId = store.state.editingServerId

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isEditing {
                    // Edit form
                    editForm(
                        fg: fg, fgSecondary: fgSecondary, fgTertiary: fgTertiary,
                        sectionColor: sectionColor, cardBg: cardBg, cardBorder: cardBorder,
                        fieldBg: fieldBg, fieldBorder: fieldBorder, divider: divider,
                        accentColor: accentColor, dangerColor: dangerColor
                    )
                } else {
                    // Server list
                    serverList(
                        fg: fg, fgSecondary: fgSecondary, fgTertiary: fgTertiary,
                        sectionColor: sectionColor, cardBg: cardBg, cardBorder: cardBorder,
                        divider: divider, accentColor: accentColor, dangerColor: dangerColor,
                        successColor: successColor
                    )
                }
            }
            .padding(24)
        }
        .onAppear {
            if editingId >= 0 && editingId != lastEditingId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    loadFormFromJson()
                    isEditing = true
                    lastEditingId = editingId
                }
            }
        }
        .onChange(of: editingId) { newId in
            if newId >= 0 && newId != lastEditingId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    loadFormFromJson()
                    isEditing = true
                    lastEditingId = newId
                }
            } else if newId < 0 {
                isEditing = false
                lastEditingId = -1
            }
        }
        .onChange(of: store.state.editServerJson) { newJson in
            // Re-load form when Nim populates the JSON after dispatch
            if editingId >= 0 && isEditing {
                loadFormFromJson()
            }
        }
    }

    // MARK: - Server List

    @ViewBuilder
    private func serverList(
        fg: Color, fgSecondary: Color, fgTertiary: Color,
        sectionColor: Color, cardBg: Color, cardBorder: Color,
        divider: Color, accentColor: Color, dangerColor: Color,
        successColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SERVERS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(sectionColor)
                .tracking(0.6)

            if store.state.servers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundColor(fgTertiary)
                        .opacity(0.5)

                    Text("No servers configured")
                        .font(.system(size: 13))
                        .foregroundColor(fgTertiary)

                    Text("Add a server using the + button in the sidebar")
                        .font(.system(size: 11))
                        .foregroundColor(fgTertiary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(store.state.servers.indices), id: \.self) { idx in
                        let server = store.state.servers[idx]
                        serverCard(
                            server: server,
                            fg: fg, fgSecondary: fgSecondary, fgTertiary: fgTertiary,
                            cardBg: cardBg, cardBorder: cardBorder, divider: divider,
                            accentColor: accentColor, dangerColor: dangerColor,
                            successColor: successColor
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serverCard(
        server: IrcServer,
        fg: Color, fgSecondary: Color, fgTertiary: Color,
        cardBg: Color, cardBorder: Color, divider: Color,
        accentColor: Color, dangerColor: Color, successColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(server.connected ? successColor : (server.connecting ? Color.orange : fgTertiary.opacity(0.5)))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(fg)

                    Text("\(server.host):\(server.port)")
                        .font(.system(size: 11))
                        .foregroundColor(fgTertiary)
                }

                Spacer()

                if server.connected {
                    Text("Connected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(successColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(successColor.opacity(0.12))
                        )
                } else if server.connecting {
                    Text("Connecting")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.12))
                        )
                }
            }

            HStack(spacing: 4) {
                Text("Nick: \(server.nick)")
                    .font(.system(size: 11))
                    .foregroundColor(fgSecondary)

                if server.useTls {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(accentColor.opacity(0.7))
                    Text("TLS")
                        .font(.system(size: 10))
                        .foregroundColor(accentColor.opacity(0.7))
                }
            }

            Rectangle()
                .fill(divider)
                .frame(height: 1)

            HStack(spacing: 8) {
                Button(action: { store.send(.editServer(serverId: server.id)) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                        Text("Edit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(accentColor)
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: { store.send(.duplicateServer(serverId: server.id)) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text("Duplicate")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(fgSecondary)
                }
                .buttonStyle(BorderlessButtonStyle())

                Spacer()

                Button(action: { store.send(.deleteServer(serverId: server.id)) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Delete")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(dangerColor)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Edit Form

    @ViewBuilder
    private func editForm(
        fg: Color, fgSecondary: Color, fgTertiary: Color,
        sectionColor: Color, cardBg: Color, cardBorder: Color,
        fieldBg: Color, fieldBorder: Color, divider: Color,
        accentColor: Color, dangerColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with back button
            HStack {
                Button(action: {
                    isEditing = false
                    store.send(.hideServerEditor)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(accentColor)
                }
                .buttonStyle(BorderlessButtonStyle())

                Spacer()

                Text("Edit Server")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(fg)

                Spacer()

                Button(action: saveForm) {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            // Server Identity
            VStack(alignment: .leading, spacing: 12) {
                Text("SERVER")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(sectionColor)
                    .tracking(0.6)

                VStack(alignment: .leading, spacing: 12) {
                    formField(label: "Server Name", text: $formName, placeholder: "My Server",
                              fg: fg, fgTertiary: fgTertiary, fieldBg: fieldBg, fieldBorder: fieldBorder)

                    Rectangle().fill(divider).frame(height: 1)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Host")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(fg)
                            TextField("irc.libera.chat", text: $formHost)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 13))
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(fieldBg))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fieldBorder, lineWidth: 0.5))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Port")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(fg)
                            TextField("6667", text: $formPort)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 13))
                                .padding(8)
                                .frame(width: 80)
                                .background(RoundedRectangle(cornerRadius: 6).fill(fieldBg))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fieldBorder, lineWidth: 0.5))
                        }
                    }

                    Rectangle().fill(divider).frame(height: 1)

                    HStack {
                        Text("Use TLS")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(fg)
                        Spacer()
                        Toggle("", isOn: $formUseTls)
                            .toggleStyle(SwitchToggleStyle(tint: accentColor))
                            .labelsHidden()
                    }

                    Rectangle().fill(divider).frame(height: 1)

                    formField(label: "Nickname", text: $formNick, placeholder: "mynick",
                              fg: fg, fgTertiary: fgTertiary, fieldBg: fieldBg, fieldBorder: fieldBorder)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(cardBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(cardBorder, lineWidth: 0.5))
            }

            // Authentication
            VStack(alignment: .leading, spacing: 12) {
                Text("AUTHENTICATION")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(sectionColor)
                    .tracking(0.6)

                VStack(alignment: .leading, spacing: 12) {
                    secureFormField(label: "Server Password", text: $formPassword, placeholder: "Optional",
                                   fg: fg, fgTertiary: fgTertiary, fieldBg: fieldBg, fieldBorder: fieldBorder)

                    Rectangle().fill(divider).frame(height: 1)

                    formField(label: "SASL Username", text: $formSaslUser, placeholder: "Optional",
                              fg: fg, fgTertiary: fgTertiary, fieldBg: fieldBg, fieldBorder: fieldBorder)

                    Rectangle().fill(divider).frame(height: 1)

                    secureFormField(label: "SASL Password", text: $formSaslPass, placeholder: "Optional",
                                   fg: fg, fgTertiary: fgTertiary, fieldBg: fieldBg, fieldBorder: fieldBorder)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(cardBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(cardBorder, lineWidth: 0.5))
            }

            // Auto-join Channels
            VStack(alignment: .leading, spacing: 12) {
                Text("AUTO-JOIN CHANNELS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(sectionColor)
                    .tracking(0.6)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("#channel", text: $newChannelText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 13))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(fieldBg))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(fieldBorder, lineWidth: 0.5))
                            .onSubmit { addChannel() }

                        Button(action: addChannel) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }

                    Text("Channels to join automatically on connect")
                        .font(.system(size: 11))
                        .foregroundColor(fgTertiary)

                    if !formChannels.isEmpty {
                        Rectangle().fill(divider).frame(height: 1)

                        VStack(spacing: 0) {
                            ForEach(Array(formChannels.enumerated()), id: \.offset) { index, channel in
                                HStack {
                                    Text(channel)
                                        .font(.system(size: 13))
                                        .foregroundColor(fg)

                                    Spacer()

                                    Button(action: { formChannels.remove(at: index) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(fgSecondary.opacity(0.6))
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 4)

                                if index < formChannels.count - 1 {
                                    Rectangle().fill(divider).frame(height: 1)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(cardBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(cardBorder, lineWidth: 0.5))
            }

            // Save / Cancel
            HStack(spacing: 12) {
                Spacer()

                Button(action: {
                    isEditing = false
                    store.send(.hideServerEditor)
                }) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(fgSecondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(RoundedRectangle(cornerRadius: 8).fill(cardBg))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cardBorder, lineWidth: 0.5))
                }
                .buttonStyle(BorderlessButtonStyle())

                Button(action: saveForm) {
                    Text("Save Changes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(RoundedRectangle(cornerRadius: 8).fill(accentColor))
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
    }

    // MARK: - Form Helpers

    @ViewBuilder
    private func formField(
        label: String, text: Binding<String>, placeholder: String,
        fg: Color, fgTertiary: Color, fieldBg: Color, fieldBorder: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(fg)
            TextField(placeholder, text: text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 13))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fieldBorder, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func secureFormField(
        label: String, text: Binding<String>, placeholder: String,
        fg: Color, fgTertiary: Color, fieldBg: Color, fieldBorder: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(fg)
            SecureField(placeholder, text: text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 13))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fieldBorder, lineWidth: 0.5))
        }
    }

    // MARK: - Actions

    private func loadFormFromJson() {
        let json = store.state.editServerJson
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        formName = obj["name"] as? String ?? ""
        formHost = obj["host"] as? String ?? ""
        formPort = (obj["port"] as? Int).map { String($0) } ?? "6667"
        formNick = obj["nick"] as? String ?? ""
        formUseTls = obj["useTls"] as? Bool ?? false
        formPassword = obj["password"] as? String ?? ""
        formSaslUser = obj["saslUser"] as? String ?? ""
        formSaslPass = obj["saslPass"] as? String ?? ""
        formChannels = obj["autoJoinChannels"] as? [String] ?? []
        newChannelText = ""
    }

    private func saveForm() {
        var obj: [String: Any] = [:]
        obj["name"] = formName
        obj["host"] = formHost
        obj["port"] = Int(formPort) ?? 6667
        obj["nick"] = formNick
        obj["useTls"] = formUseTls
        obj["password"] = formPassword
        obj["saslUser"] = formSaslUser
        obj["saslPass"] = formSaslPass
        obj["autoJoinChannels"] = formChannels

        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let jsonStr = String(data: data, encoding: .utf8) {
            store.state.editServerJson = jsonStr
        }

        isEditing = false
        store.send(.saveServerConfig)
    }

    private func addChannel() {
        let ch = newChannelText.trimmingCharacters(in: .whitespaces)
        guard !ch.isEmpty else { return }
        let normalized = ch.hasPrefix("#") ? ch : "#\(ch)"
        if !formChannels.contains(normalized) {
            formChannels.append(normalized)
        }
        newChannelText = ""
    }
}
#endif
