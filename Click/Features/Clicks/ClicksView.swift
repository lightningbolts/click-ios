import SwiftUI

/// Native Clicks inbox preserving the shipping Click hierarchy: Active / Groups / Archived,
/// Remember Me, and conversation-first rows.
public struct ClicksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot: ClicksSnapshot?
    @State private var selectedTab: InboxTab = .active
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var refreshError: String?

    public init(initialSnapshot: ClicksSnapshot? = nil) {
        self._snapshot = State(initialValue: initialSnapshot)
    }

    public var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if refreshError != nil {
                            offlineNotice
                        }

                        titleBlock(snapshot)
                        tabSwitcher(snapshot)

                        if selectedTab == .active, !filteredActive(snapshot).isEmpty {
                            rememberMe(filteredActive(snapshot))
                        }

                        inboxSection(snapshot)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .refreshable { await refresh() }
            } else {
                loadingState
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Clicks menu")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Search Clicks")
            }
        }
        .task { await bootstrap() }
        .sheet(isPresented: $isSearching) {
            clicksSearchSheet
        }
    }

    private func titleBlock(_ snapshot: ClicksSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Clicks")
                .font(ClickTypography.headlineLarge)
                .tracking(-0.55)
                .foregroundStyle(ClickColors.textPrimary)

            Text("\(snapshot.connections.count) active connection\(snapshot.connections.count == 1 ? "" : "s")")
                .font(ClickTypography.bodyMedium)
                .foregroundStyle(ClickColors.textSecondary)
        }
    }

    private func tabSwitcher(_ snapshot: ClicksSnapshot) -> some View {
        HStack(spacing: 8) {
            inboxTabButton(.active, count: snapshot.connections.count)
            inboxTabButton(.groups, count: snapshot.cliques.count)
            inboxTabButton(.archived, count: snapshot.archived.count)
        }
    }

    private func inboxTabButton(_ tab: InboxTab, count: Int) -> some View {
        Button {
            selectedTab = tab
            ClickHaptics.selection()
        } label: {
            Text("\(tab.title) (\(count))")
                .font(ClickTypography.labelMedium)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .foregroundStyle(selectedTab == tab ? ClickColors.onPrimary : ClickColors.textPrimary)
                .background(selectedTab == tab ? ClickColors.primary : ClickColors.surface)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            selectedTab == tab ? ClickColors.primary : ClickColors.quietBorder.opacity(0.7),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
    }

    private func rememberMe(_ connections: [ConnectionItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remember Me")
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)

            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(connections.prefix(8)) { connection in
                        Button {
                            openProfile(connection)
                        } label: {
                            VStack(spacing: 7) {
                                ConnectionAvatar(connection: connection, size: 58)
                                Text(firstName(connection.displayName))
                                    .font(ClickTypography.captionSmall)
                                    .foregroundStyle(ClickColors.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 66)

                                if connection.encounterCount > 1 {
                                    Text("\(connection.encounterCount)x")
                                        .font(ClickTypography.microcopy)
                                        .foregroundStyle(ClickColors.primary)
                                        .padding(.horizontal, 7)
                                        .frame(height: 20)
                                        .background(ClickColors.primary.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func inboxSection(_ snapshot: ClicksSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedTab.sectionTitle)
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textPrimary)

            switch selectedTab {
            case .active:
                let rows = filteredActive(snapshot)
                if rows.isEmpty {
                    emptyState(title: "No active Clicks", description: "New in-person connections will appear here.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { connection in
                            ConversationInboxRow(connection: connection) {
                                openChat(connection)
                            } onProfile: {
                                openProfile(connection)
                            }

                            if connection.id != rows.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }

            case .groups:
                let groups = snapshot.cliques.filter {
                    searchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchQuery)
                }
                if groups.isEmpty {
                    emptyState(
                        title: "No group Clicks yet",
                        description: "Verified Click groups will appear here when the native group-chat phase is connected."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            GroupInboxRow(group: group)
                            if group.id != groups.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }

            case .archived:
                let rows = filteredArchived(snapshot)
                if rows.isEmpty {
                    emptyState(title: "No archived Clicks", description: "Older connections you archive will appear here.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { connection in
                            ConversationInboxRow(connection: connection) {
                                openProfile(connection)
                            } onProfile: {
                                openProfile(connection)
                            }

                            if connection.id != rows.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }
            }
        }
    }

    private func filteredActive(_ snapshot: ClicksSnapshot) -> [ConnectionItem] {
        filter(snapshot.connections)
    }

    private func filteredArchived(_ snapshot: ClicksSnapshot) -> [ConnectionItem] {
        filter(snapshot.archived)
    }

    private func filter(_ source: [ConnectionItem]) -> [ConnectionItem] {
        let clean = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(clean)
                || $0.handle.localizedCaseInsensitiveContains(clean)
                || $0.encounterLocation.localizedCaseInsensitiveContains(clean)
                || $0.mutualTags.contains { $0.localizedCaseInsensitiveContains(clean) }
        }
    }

    private func emptyState(title: String, description: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "person.2")
                .font(.system(size: 28))
                .foregroundStyle(ClickColors.tertiaryLabel)
            Text(title)
                .font(ClickTypography.titleMedium)
            Text(description)
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var clicksSearchSheet: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    let rows = filter(snapshot.connections + snapshot.archived)
                    if rows.isEmpty, !searchQuery.isEmpty {
                        ContentUnavailableView.search(text: searchQuery)
                    } else {
                        List(rows) { connection in
                            Button {
                                isSearching = false
                                openChat(connection)
                            } label: {
                                HStack(spacing: 12) {
                                    ConnectionAvatar(connection: connection, size: 42)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(connection.displayName)
                                            .font(ClickTypography.bodyMedium)
                                            .foregroundStyle(ClickColors.textPrimary)
                                        Text(connection.handle)
                                            .font(ClickTypography.bodySmall)
                                            .foregroundStyle(ClickColors.textSecondary)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Search Clicks")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Names, places, interests")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isSearching = false }
                }
            }
        }
        .tint(ClickColors.primary)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(ClickColors.primary)
            Text("Loading Clicks…")
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi.exclamationmark")
            Text("Offline — showing saved Clicks")
                .font(ClickTypography.captionSmall)
            Spacer()
            Button("Retry") { Task { await refresh() } }
                .font(ClickTypography.captionSmall)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func openChat(_ connection: ConnectionItem) {
        guard !connection.userID.isEmpty else { return }
        ClickHaptics.selection()
        env.router.connectionsPath.append(
            .chat(
                DirectChatRoute(
                    chatID: nil,
                    connectionID: connection.connectionID,
                    peerUserID: connection.userID,
                    peerDisplayName: connection.displayName,
                    peerHandle: connection.handle,
                    peerAvatarURL: connection.avatarUrl,
                    isOnline: connection.isOnline,
                    lastActiveText: connection.lastActiveRelative
                )
            )
        )
    }

    private func openProfile(_ connection: ConnectionItem) {
        guard !connection.userID.isEmpty else { return }
        ClickHaptics.selection()
        env.router.connectionsPath.append(
            .userProfile(
                userID: connection.userID,
                connectionID: connection.connectionID.isEmpty ? nil : connection.connectionID
            )
        )
    }

    private func firstName(_ displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    @MainActor
    private func bootstrap() async {
        guard snapshot == nil,
              let userID = env.session.currentSession?.userId else { return }

        if let cached = await env.phase3.cachedClicks(for: userID) {
            snapshot = cached
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = env.session.currentSession?.userId else { return }
        do {
            snapshot = try await env.phase3.refreshClicks(for: userID)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }
}

private enum InboxTab: CaseIterable {
    case active
    case groups
    case archived

    var title: String {
        switch self {
        case .active: return "Active"
        case .groups: return "Groups"
        case .archived: return "Archived"
        }
    }

    var sectionTitle: String {
        switch self {
        case .active: return "Clicks"
        case .groups: return "Group Clicks"
        case .archived: return "Archived"
        }
    }
}

private struct ConversationInboxRow: View {
    let connection: ConnectionItem
    let onOpen: () -> Void
    let onProfile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onProfile) {
                ConnectionAvatar(connection: connection, size: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(connection.displayName) profile")

            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(connection.displayName)
                                .font(ClickTypography.titleMedium)
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(1)

                            if !connection.handle.isEmpty {
                                Text(connection.handle)
                                    .font(ClickTypography.bodySmall)
                                    .foregroundStyle(ClickColors.textSecondary)
                                    .lineLimit(1)
                            }
                        }

                        Text(connection.lastMessagePreview ?? fallbackPreview)
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if !connection.lastActiveRelative.isEmpty {
                        Text(connection.lastActiveRelative)
                            .font(ClickTypography.microcopy)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 11)
    }

    private var fallbackPreview: String {
        if !connection.encounterLocation.isEmpty {
            return "Met at \(connection.encounterLocation)"
        }
        return "Open conversation"
    }
}

private struct ConnectionAvatar: View {
    let connection: ConnectionItem
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let raw = connection.avatarUrl, let url = URL(string: raw) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        fallback
                    }
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

            if connection.presenceKnown {
                Circle()
                    .fill(connection.isOnline ? ClickColors.statusOnline : ClickColors.statusOffline)
                    .frame(width: max(10, size * 0.22), height: max(10, size * 0.22))
                    .overlay {
                        Circle().stroke(ClickColors.background, lineWidth: 2)
                    }
            }
        }
    }

    private var fallback: some View {
        Circle()
            .fill(ClickColors.primary.opacity(0.12))
            .overlay {
                Text(connection.initials)
                    .font(ClickTypography.labelMedium)
                    .foregroundStyle(ClickColors.primary)
            }
    }
}

private struct GroupInboxRow: View {
    let group: CliqueItem

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(ClickColors.primary.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay {
                    Text(group.initials)
                        .font(ClickTypography.labelMedium)
                        .foregroundStyle(ClickColors.primary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(ClickTypography.titleMedium)
                    .foregroundStyle(ClickColors.textPrimary)
                Text("\(group.memberCount) members")
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            Spacer()

            if !group.lastActiveRelative.isEmpty {
                Text(group.lastActiveRelative)
                    .font(ClickTypography.microcopy)
                    .foregroundStyle(ClickColors.textSecondary)
            }
        }
        .padding(.vertical, 11)
    }
}
