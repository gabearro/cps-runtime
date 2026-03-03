#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Reorderable Sidebar

/// Custom SwiftUI sidebar view that supports drag-to-reorder for servers and channels.
/// Replaces the generated Component_ServerSidebar with identical visuals plus drag support.
/// On drop, sends MoveServer/MoveChannel actions to the Nim bridge which reorders the
/// backing arrays and returns the updated state immediately.
struct ReorderableSidebar: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    // Track dragged items by identity (server id / channel name) so the fade
    // follows the item across array reorders and only clears once the store updates.
    @State private var draggingServerId: Int? = nil
    @State private var draggingServerFromIdx: Int? = nil
    @State private var serverDropTarget: Int? = nil

    @State private var draggingChannelName: String? = nil
    @State private var draggingChannelFromIdx: Int? = nil
    @State private var channelDropTarget: Int? = nil

    var body: some View {
        let fgTertiary = isDark ? Color(red: 0.54, green: 0.54, blue: 0.57) : GUITokens.color_textSubtle
        let fgSecondary = isDark ? Color(red: 0.66, green: 0.66, blue: 0.69) : GUITokens.color_textMuted
        let sidebarBg = isDark
            ? Color(red: 0.16, green: 0.16, blue: 0.17)
            : Color(red: 0.965, green: 0.965, blue: 0.975)
        let dividerColor = isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
        let sectionLabelColor = isDark ? Color(red: 0.58, green: 0.58, blue: 0.61) : Color(red: 0.6, green: 0.6, blue: 0.63)
        let filterBg = isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        let filterStroke = isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
        let dropIndicatorColor = GUITokens.color_accent

        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(fgTertiary)
                TextField("Filter...", text: $store.state.sidebarFilter)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                if store.state.sidebarFilter != "" {
                    Button(action: { store.send(.updateSidebarFilter) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(fgTertiary)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 7).fill(filterBg))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(filterStroke, lineWidth: 0.5))
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // SERVERS section header
                    HStack {
                        Text("SERVERS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(sectionLabelColor)
                            .tracking(0.6)
                        Spacer()
                        Button(action: { store.send(.showConnectForm) }) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(fgSecondary)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Add server")
                    }
                    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                    // Empty servers state
                    if store.state.servers.count == 0 {
                        VStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 28))
                                .foregroundColor(fgTertiary)
                                .opacity(0.5)
                            Text("No servers")
                                .font(.system(size: 12))
                                .foregroundColor(fgTertiary)
                            Button(action: { store.send(.showConnectForm) }) {
                                Text("Add Server")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(GUITokens.color_accent)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(EdgeInsets(top: 24, leading: 0, bottom: 24, trailing: 0))
                    }

                    // Server rows with drag-to-reorder
                    ForEach(Array(store.state.servers.indices), id: \.self) { idx in
                        let server = store.state.servers[idx]
                        if store.state.sidebarFilter == "" || server.name.localizedCaseInsensitiveContains(store.state.sidebarFilter) {
                            VStack(spacing: 0) {
                                // Drop indicator line above this row
                                if serverDropTarget == idx && draggingServerId != nil && server.id != draggingServerId {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(dropIndicatorColor)
                                        .frame(height: 2)
                                        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                                        .transition(.opacity)
                                }

                                Component_ServerRow(store: store, server: server, isActive: server.id == store.state.activeServerId, isDark: isDark)
                                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                    .onTapGesture { store.send(.switchServer(serverId: server.id)) }
                                    .opacity(server.id == draggingServerId ? 0.4 : 1.0)
                                    .onDrag {
                                        self.draggingServerId = server.id
                                        self.draggingServerFromIdx = idx
                                        return NSItemProvider(object: "server:\(idx)" as NSString)
                                    }
                                    .onDrop(of: [UTType.text], delegate: SidebarReorderDelegate(
                                        targetIndex: idx,
                                        dropTarget: $serverDropTarget,
                                        isDragging: draggingServerId != nil,
                                        onDrop: { to in
                                            guard let from = draggingServerFromIdx, from != to else {
                                                clearServerDragState()
                                                return
                                            }
                                            serverDropTarget = nil
                                            store.send(.moveServer(fromIndex: from, toIndex: to))
                                            // draggingServerId stays set — cleared by onChange below
                                        }
                                    ))
                            }
                        }
                    }

                    Spacer().frame(height: 16)

                    Rectangle()
                        .fill(dividerColor)
                        .frame(height: 1)
                        .padding(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))

                    Spacer().frame(height: 8)

                    // CHANNELS section header
                    HStack {
                        Text("CHANNELS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(sectionLabelColor)
                            .tracking(0.6)
                        Spacer()
                        if store.state.activeServerId >= 0 {
                            Button(action: { store.send(.showJoinChannel) }) {
                                Image(systemName: "number")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(fgSecondary)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Join channel")
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))

                    // Empty channels state
                    if store.state.channels.count == 0 {
                        VStack(spacing: 8) {
                            Text("No channels joined")
                                .font(.system(size: 12))
                                .foregroundColor(fgTertiary)
                            if store.state.activeServerId >= 0 {
                                Button(action: { store.send(.showJoinChannel) }) {
                                    Text("Join a Channel")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(GUITokens.color_accent)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                        .padding(EdgeInsets(top: 16, leading: 14, bottom: 16, trailing: 14))
                    }

                    // Channel rows with drag-to-reorder
                    ForEach(Array(store.state.channels.indices), id: \.self) { idx in
                        let channel = store.state.channels[idx]
                        if channel.isChannel || channel.isDm {
                            if store.state.sidebarFilter == "" || channel.name.localizedCaseInsensitiveContains(store.state.sidebarFilter) {
                                VStack(spacing: 0) {
                                    // Drop indicator line above this row
                                    if channelDropTarget == idx && draggingChannelName != nil && channel.name != draggingChannelName {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(dropIndicatorColor)
                                            .frame(height: 2)
                                            .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                                            .transition(.opacity)
                                    }

                                    Component_ChannelRow(store: store, channel: channel, isActive: channel.name == store.state.activeChannelName, isDark: isDark, isDm: channel.isDm)
                                        .padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                        .contextMenu {
                                            Button("Close") { store.send(.closeChannel(channelName: channel.name)) }
                                            if channel.isChannel {
                                                Button("Part Channel") { store.send(.partChannel(channelName: channel.name)) }
                                            }
                                            if channel.isChannel {
                                                Divider()
                                                Button("Channel Info") { store.send(.showChannelInfo) }
                                            }
                                        }
                                        .onTapGesture { store.send(.switchChannel(channelName: channel.name)) }
                                        .opacity(channel.name == draggingChannelName ? 0.4 : 1.0)
                                        .onDrag {
                                            self.draggingChannelName = channel.name
                                            self.draggingChannelFromIdx = idx
                                            return NSItemProvider(object: "channel:\(idx)" as NSString)
                                        }
                                        .onDrop(of: [UTType.text], delegate: SidebarReorderDelegate(
                                            targetIndex: idx,
                                            dropTarget: $channelDropTarget,
                                            isDragging: draggingChannelName != nil,
                                            onDrop: { to in
                                                guard let from = draggingChannelFromIdx, from != to else {
                                                    clearChannelDragState()
                                                    return
                                                }
                                                channelDropTarget = nil
                                                store.send(.moveChannel(fromIndex: from, toIndex: to))
                                                // draggingChannelName stays set — cleared by onChange below
                                            }
                                        ))
                                }
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }

            Spacer()
            Component_StatusBar(store: store, isDark: isDark)
        }
        .background(sidebarBg)
        // Clear drag state once the store arrays actually update from the bridge response.
        // This prevents the flash where the old item appears at full opacity before reorder.
        .onChange(of: store.state.servers) { _ in
            if draggingServerId != nil {
                clearServerDragState()
            }
        }
        .onChange(of: store.state.channels) { _ in
            if draggingChannelName != nil {
                clearChannelDragState()
            }
        }
    }

    private func clearServerDragState() {
        draggingServerId = nil
        draggingServerFromIdx = nil
        serverDropTarget = nil
    }

    private func clearChannelDragState() {
        draggingChannelName = nil
        draggingChannelFromIdx = nil
        channelDropTarget = nil
    }
}

// MARK: - Generic Sidebar Reorder DropDelegate

/// Shared DropDelegate for both server and channel row reordering.
/// Tracks drop target for visual indicator and dispatches the move action on drop.
struct SidebarReorderDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var dropTarget: Int?
    let isDragging: Bool
    let onDrop: (Int) -> Void

    func dropEntered(info: DropInfo) {
        guard isDragging else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTarget = targetIndex
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if dropTarget == targetIndex {
                dropTarget = nil
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isDragging else { return false }
        onDrop(targetIndex)
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return isDragging
    }
}

#endif
