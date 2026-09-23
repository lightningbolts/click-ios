import SwiftUI

/// The Clicks inbox root: native large title and inline search, compact Active / Groups /
/// Archived filters, the Core "Remember" strip, then conversation rows immediately.
/// Rows use native swipe actions and context menus; all state lives in `ConversationListModel`.
public struct ClicksView: View {
    @Environment(AppEnvironment.self) private var env
    let model: ConversationListModel

    @State private var selectedTab: InboxTab = .active
    @State private var query = ""

    init(model: ConversationListModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                if model.refreshError != nil, model.snapshot != nil {
                    OfflineNotice("Offline — showing saved Clicks") {
                        Task { await model.refresh() }
                    }
                }
                filterChips
                if showsRememberStrip {
                    rememberStrip
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: ClickSpacing.screenGutter, bottom: 6, trailing: ClickSpacing.screenGutter))

            Section {
                rows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ClickColors.background.ignoresSafeArea())
        .overlay {
            if model.snapshot == nil {
                initialState
            }
        }
        .navigationTitle("Clicks")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                } label: {
                    Label("Clicks menu", systemImage: "ellipsis")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    env.router.navigate(to: .scanQR)
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .refreshable { await model.refresh() }
        .onAppear {
            Task { await model.refreshIfStale() }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    // MARK: - Header

    private var filterChips: some View {
        HStack(spacing: ClickSpacing.sm) {
            ForEach(InboxTab.allCases, id: \.self) { tab in
                InboxFilterChip(
                    title: tab.title,
                    count: tab == .active ? nil : count(for: tab),
                    isSelected: selectedTab == tab
                ) {
                    selectedTab = tab
                    ClickHaptics.selection()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var showsRememberStrip: Bool {
        selectedTab == .active && query.isEmpty && !model.core.isEmpty
    }

    private var rememberStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(model.core) { item in
                    Button {
                        openProfile(item)
                    } label: {
                        VStack(spacing: 6) {
                            ConnectionAvatar(item: item, size: ClickMetrics.Avatar.conversation)
                            Text(firstName(item.displayName))
                                .font(ClickTypography.caption)
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.displayName), Core")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        switch selectedTab {
        case .active, .archived:
            let isArchived = selectedTab == .archived
            let items = filtered(isArchived ? model.archived : model.active)
            if items.isEmpty, model.snapshot != nil {
                emptyState(isArchived: isArchived)
            }
            ForEach(items) { item in
                ConversationRow(
                    item: item,
                    preview: model.previewText(for: item),
                    onOpen: { isArchived ? openProfile(item) : openChat(item) },
                    onProfile: { openProfile(item) }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: ClickSpacing.screenGutter, bottom: 0, trailing: ClickSpacing.screenGutter))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        Task { await model.setArchived(item, archived: !isArchived) }
                    } label: {
                        Label(isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(ClickColors.offline)
                }
                .swipeActions(edge: .leading) {
                    if !isArchived {
                        coreButton(item)
                            .tint(ClickColors.primaryActionFill)
                    }
                }
                .contextMenu {
                    Button("View Profile", systemImage: "person.crop.circle") { openProfile(item) }
                    if !isArchived { coreButton(item) }
                    Button(isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up" : "archivebox") {
                        Task { await model.setArchived(item, archived: !isArchived) }
                    }
                }
            }
        case .groups:
            let groups = model.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            if groups.isEmpty {
                ContentUnavailableView(
                    "No group Clicks yet",
                    systemImage: "person.3",
                    description: Text("Verified Click groups will appear here when native group chat is available.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                GroupInboxRow(group: group)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func coreButton(_ item: ConnectionItem) -> some View {
        Button {
            Task { await model.setCore(item, isCore: !item.isCore) }
        } label: {
            Label(item.isCore ? "Remove from Core" : "Add to Core", systemImage: item.isCore ? "star.slash" : "star")
        }
    }

    @ViewBuilder
    private func emptyState(isArchived: Bool) -> some View {
        Group {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if isArchived {
                ContentUnavailableView(
                    "No archived Clicks",
                    systemImage: "archivebox",
                    description: Text("Connections you archive appear here.")
                )
            } else {
                ContentUnavailableView(
                    "No connections yet",
                    systemImage: "person.2",
                    description: Text("Start clicking with people nearby!")
                )
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var initialState: some View {
        if let error = model.refreshError {
            ContentUnavailableView {
                Label("Couldn't load Clicks", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
                    .tint(ClickColors.primaryActionFill)
            }
        } else {
            ProgressView()
                .tint(ClickColors.accentForeground)
        }
    }

    // MARK: - Helpers

    private func count(for tab: InboxTab) -> Int {
        switch tab {
        case .active: model.active.count
        case .groups: model.groups.count
        case .archived: model.archived.count
        }
    }

    private func filtered(_ items: [ConnectionItem]) -> [ConnectionItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return items }
        return items.filter {
            $0.displayName.localizedCaseInsensitiveContains(clean)
                || $0.encounterLocation.localizedCaseInsensitiveContains(clean)
                || model.previewText(for: $0).localizedCaseInsensitiveContains(clean)
        }
    }

    private func openChat(_ item: ConnectionItem) {
        guard !item.userID.isEmpty else { return }
        ClickHaptics.selection()
        model.markOpened(item)
        env.router.navigate(to: .chat(
            DirectChatRoute(
                chatID: item.chatID,
                connectionID: item.connectionID,
                peerUserID: item.userID,
                peerDisplayName: item.displayName,
                peerHandle: item.handle,
                peerAvatarURL: item.avatarUrl,
                isOnline: item.isOnline,
                lastActiveText: item.lastActiveRelative
            )
        ))
    }

    private func openProfile(_ item: ConnectionItem) {
        guard !item.userID.isEmpty else { return }
        ClickHaptics.selection()
        env.router.navigate(to: .userProfile(
            userID: item.userID,
            connectionID: item.connectionID.isEmpty ? nil : item.connectionID
        ))
    }

    private func firstName(_ displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}

private enum InboxTab: CaseIterable {
    case active
    case groups
    case archived

    var title: String {
        switch self {
        case .active: "Active"
        case .groups: "Groups"
        case .archived: "Archived"
        }
    }
}

private struct InboxFilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(ClickTypography.badge)
                        .monospacedDigit()
                        .foregroundStyle(ClickColors.primaryActionForeground)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(ClickColors.primaryActionFill, in: Capsule())
                }
            }
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(isSelected ? ClickColors.accentForeground : ClickColors.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.chipHeight)
            .background(isSelected ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
            .frame(minHeight: ClickMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConversationRow: View {
    let item: ConnectionItem
    let preview: String
    let onOpen: () -> Void
    let onProfile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onProfile) {
                ConnectionAvatar(item: item, size: ClickMetrics.Avatar.conversation)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.displayName) profile")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(item.displayName)
                            .font(ClickTypography.bodyEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)
                        if item.isCore {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(ClickColors.accentForeground)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 8)
                        if let date = item.lastActivityAt {
                            Text(InboxFormatting.timestamp(for: date))
                                .font(ClickTypography.metadata)
                                .foregroundStyle(item.unreadCount > 0 ? ClickColors.accentForeground : ClickColors.textTertiary)
                                .monospacedDigit()
                        }
                    }

                    HStack(alignment: .top, spacing: 4) {
                        if let message = item.lastMessage, message.isOutgoing {
                            Image(systemName: message.isRead ? "checkmark.circle.fill" : "checkmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(message.isRead ? ClickColors.accentForeground : ClickColors.textTertiary)
                                .padding(.top, 3)
                                .accessibilityHidden(true)
                        }
                        Text(preview)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        trailingStatus
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.vertical, 10)
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + ClickMetrics.Avatar.conversation + 12
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if item.unreadCount > 0 {
            Text(item.unreadCount > 99 ? "99+" : "\(item.unreadCount)")
                .font(ClickTypography.badge)
                .monospacedDigit()
                .foregroundStyle(ClickColors.primaryActionForeground)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(ClickColors.primaryActionFill, in: Capsule())
        } else if let deadline = item.sayHiDeadline, let remaining = InboxFormatting.sayHiRemaining(until: deadline) {
            Text(remaining)
                .font(ClickTypography.badge)
                .foregroundStyle(ClickColors.accentForeground)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(ClickColors.selectionTint, in: Capsule())
        }
    }

    private var accessibilityText: String {
        var parts = [item.displayName]
        if item.isCore { parts.append("Core") }
        if item.unreadCount > 0 { parts.append("\(item.unreadCount) unread") }
        parts.append(preview)
        if let date = item.lastActivityAt { parts.append(InboxFormatting.timestamp(for: date)) }
        if let deadline = item.sayHiDeadline, let remaining = InboxFormatting.sayHiRemaining(until: deadline) {
            parts.append(remaining)
        }
        return parts.joined(separator: ", ")
    }
}

private struct ConnectionAvatar: View {
    let item: ConnectionItem
    let size: CGFloat

    var body: some View {
        AvatarView(
            imageURL: item.avatarUrl,
            seed: item.userID,
            initials: item.initials,
            size: size,
            presence: AvatarView.Presence(isOnline: item.isOnline, known: item.presenceKnown)
        )
    }
}

private struct GroupInboxRow: View {
    let group: CliqueItem

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(imageURL: nil, seed: group.chatID, initials: group.initials, size: ClickMetrics.Avatar.conversation)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text("\(group.memberCount) members")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            Spacer()

            if !group.lastActiveRelative.isEmpty {
                Text(group.lastActiveRelative)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .padding(.vertical, 10)
    }
}
