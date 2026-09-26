import SwiftUI

/// The Clicks inbox root: native large title and inline search, compact Active / Groups /
/// Archived filters, the Core "Remember" strip, then conversation rows immediately.
/// Rows use native swipe actions and context menus; all state lives in `ConversationListModel`.
public struct ClicksView: View {
    @Environment(AppEnvironment.self) private var env
    let model: ConversationListModel

    @State private var selectedTab: InboxTab = .active
    @State private var creatingGroup = false
    @State private var pendingAction: PendingConversationAction?

    init(model: ConversationListModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                if model.snapshot != nil {
                    OfflineNotice(showing: "saved Clicks", hasCachedValue: true, refreshFailed: model.refreshError != nil) {
                        Task { await model.refresh() }
                    }
                }
                SearchLaunchField()
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                RootMenu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    env.router.navigate(to: .scanQR)
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creatingGroup = true
                } label: {
                    Label("New verified group", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
                .buttonBorderShape(.circle)
            }
        }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $creatingGroup) {
            NewGroupSheet()
        }
        .onAppear {
            Task { await model.refreshIfStale() }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            model.hubPreviewsVisible = tab == .groups
        }
        .onDisappear { model.hubPreviewsVisible = false }
        .conversationActionDialogs(model: model, pending: $pendingAction)
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
        selectedTab == .active && !model.core.isEmpty
    }

    private var rememberStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(model.core) { item in
                    Button {
                        openChat(item)
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
                    // Same actions as the conversation row (one implementation).
                    .contextMenu {
                        DirectConversationActions(item: item, model: model, pending: $pendingAction, onProfile: { openProfile(item) })
                    }
                    .accessibilityLabel("\(item.displayName), Core")
                    .accessibilityHint("Opens the chat. Touch and hold for more options.")
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
            let items = isArchived ? model.archived : model.active
            if items.isEmpty, model.snapshot != nil {
                emptyState(isArchived: isArchived)
            }
            ForEach(items) { item in
                ConversationRow(
                    item: item,
                    preview: model.previewText(for: item),
                    isMuted: model.isMuted([item.chatID, item.connectionID]),
                    onOpen: { isArchived ? openProfile(item) : openChat(item) },
                    onProfile: { openProfile(item) }
                )
                .inboxRowChrome()
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        Task { await model.setArchived(item, archived: !isArchived) }
                    } label: {
                        Label(isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(ClickColors.offline)
                    if item.chatID?.isEmpty == false {
                        Button {
                            Task { await model.markUnread(item) }
                        } label: {
                            Label("Unread", systemImage: "envelope.badge")
                        }
                        .tint(ClickColors.accentForeground)
                    }
                }
                .swipeActions(edge: .leading) {
                    if !isArchived {
                        coreButton(item)
                            .tint(ClickColors.primaryActionFill)
                    }
                }
                .contextMenu {
                    if let chatID = item.chatID?.nonEmptyTrimmed { muteMenu(chatID: chatID, aliases: [item.connectionID]) }
                    DirectConversationActions(item: item, model: model, pending: $pendingAction, onProfile: { openProfile(item) })
                }
            }
        case .groups:
            let groups = model.groups
            let hubs = model.hubs
            if groups.isEmpty, hubs.isEmpty {
                if let error = model.groupsError, !model.groupsLoaded {
                    ContentUnavailableView {
                        Label("Couldn't load groups", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await model.refresh() } }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if model.groupsLoaded {
                    ContentUnavailableView {
                        Label("No groups yet", systemImage: "person.3")
                    } description: {
                        Text("Verified groups, event chats, and hubs you join appear here.")
                    } actions: {
                        Button("New verified group") { creatingGroup = true }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ClickLoadingView(size: 26, fillsSpace: false).listRowBackground(Color.clear)
                }
            }
            ForEach(GroupsTabRow.merge(groups: groups, hubs: hubs)) { row in
                switch row {
                case .group(let group):
                    GroupInboxRow(
                        group: group,
                        preview: model.previewText(for: group),
                        avatarMembers: group.avatarMembers(excluding: env.session.currentSession?.userId),
                        isMuted: model.isMuted([group.chatID]),
                        onOpen: { openGroup(group) },
                        onProfile: { env.router.navigate(to: .groupProfile(chatID: group.chatID)) }
                    )
                    .inboxRowChrome()
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await model.markUnread(group) }
                        } label: {
                            Label("Unread", systemImage: "envelope.badge")
                        }
                        .tint(ClickColors.accentForeground)
                    }
                    .contextMenu {
                        muteMenu(chatID: group.chatID)
                        GroupConversationActions(
                            group: group,
                            model: model,
                            currentUserID: env.session.currentSession?.userId,
                            pending: $pendingAction,
                            onInfo: { env.router.navigate(to: .groupProfile(chatID: group.chatID)) }
                        )
                    }
                case .hub(let hub):
                    HubInboxRow(hub: hub, isMuted: model.isMuted([hub.hubID])) {
                        ClickHaptics.selection()
                        env.router.navigate(to: .hub(hubID: hub.hubID))
                    }
                    .inboxRowChrome()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingAction = .leaveHub(hub)
                        } label: {
                            Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    .contextMenu {
                        muteMenu(chatID: hub.hubID)
                        HubConversationActions(hub: hub, currentUserID: env.session.currentSession?.userId, pending: $pendingAction)
                    }
                }
            }
            if !groups.isEmpty || !hubs.isEmpty {
                Label("Private chats are end-to-end encrypted", systemImage: "lock")
                    .font(ClickTypography.caption)
                    .foregroundStyle(ClickColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func muteMenu(chatID: String, aliases: [String?] = []) -> some View {
        MuteMenu(model: model, chatID: chatID, aliases: aliases) { result in
            if case .failure = result { model.actionError = "Couldn't change notifications. Try again." }
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
            if isArchived {
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
                Label("Couldn't load Clicks", systemImage: "exclamationmark.arrow.circlepath")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
                    .tint(ClickColors.primaryActionFill)
            }
        } else {
            ClickLoadingView()
        }
    }

    // MARK: - Helpers

    private func count(for tab: InboxTab) -> Int {
        switch tab {
        case .active: model.active.count
        case .groups: model.groups.count + model.hubs.count
        case .archived: model.archived.count
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

    private func openGroup(_ group: CliqueItem) {
        ClickHaptics.selection()
        model.markGroupOpened(group)
        env.router.navigate(to: .groupChat(group.chatRoute))
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

struct ConversationRow: View {
    let item: ConnectionItem
    let preview: String
    var isMuted = false
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
                        if isMuted { MutedBadge() }
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
                        InboxPreviewText(preview)
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
        .frame(minHeight: InboxRowMetrics.minHeight)
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
        } else if item.awaitsPriorResponse {
            Text("Knows you?")
                .font(ClickTypography.badge)
                .foregroundStyle(ClickColors.accentForeground)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(ClickColors.selectionTint, in: Capsule())
                .accessibilityLabel("Prior connection request. Touch and hold to accept or decline.")
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

/// One Groups-tab row: a verified group or a joined hub / event chat, ordered by activity.
private enum GroupsTabRow: Identifiable {
    case group(CliqueItem)
    case hub(JoinedHub)

    var id: String {
        switch self {
        case .group(let group): "group.\(group.id)"
        case .hub(let hub): "hub.\(hub.hubID)"
        }
    }

    var activity: Date {
        switch self {
        case .group(let group): group.lastActivityAt ?? .distantPast
        case .hub(let hub): hub.lastActivityAt ?? hub.joinedAt
        }
    }

    static func merge(groups: [CliqueItem], hubs: [JoinedHub]) -> [GroupsTabRow] {
        (groups.map(GroupsTabRow.group) + hubs.map(GroupsTabRow.hub)).sorted { $0.activity > $1.activity }
    }
}

struct HubInboxRow: View {
    let hub: JoinedHub
    var isMuted = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                BeaconVisual(beaconID: hub.eventBeaconID, seed: hub.hubID, symbol: hub.isEvent ? "calendar" : "house",
                             cornerRadius: ClickMetrics.Avatar.conversation / 2)
                    .frame(width: ClickMetrics.Avatar.conversation, height: ClickMetrics.Avatar.conversation)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(hub.name)
                            .font(ClickTypography.bodyEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)
                        if isMuted { MutedBadge() }
                        Spacer(minLength: 8)
                        if let date = hub.lastActivityAt {
                            Text(InboxFormatting.timestamp(for: date))
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textTertiary)
                                .monospacedDigit()
                        }
                    }
                    InboxPreviewText(preview)
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: InboxRowMetrics.minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + ClickMetrics.Avatar.conversation + 12
        }
    }

    private var preview: String {
        guard let message = hub.lastMessage else { return hub.isEvent ? "Event chat" : "Community hub" }
        return hub.lastSenderName.map { "\($0.split(separator: " ").first.map(String.init) ?? $0): \(message)" } ?? message
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

struct GroupInboxRow: View {
    let group: CliqueItem
    let preview: String
    let avatarMembers: [GroupMember]
    var isMuted = false
    let onOpen: () -> Void
    var onProfile: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onProfile) {
                GroupAvatarView(
                    avatarURL: group.avatarURL,
                    seed: group.chatID,
                    initials: group.initials,
                    members: avatarMembers,
                    size: ClickMetrics.Avatar.conversation
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name) group info")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(group.name)
                            .font(ClickTypography.bodyEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)
                        if isMuted { MutedBadge() }
                        Spacer(minLength: 8)
                        if let date = group.lastActivityAt {
                            Text(InboxFormatting.timestamp(for: date))
                                .font(ClickTypography.metadata)
                                .foregroundStyle(group.unreadCount > 0 ? ClickColors.accentForeground : ClickColors.textTertiary)
                                .monospacedDigit()
                        }
                    }
                    HStack(alignment: .top, spacing: 4) {
                        InboxPreviewText(preview)
                        if group.unreadCount > 0 {
                            Text(group.unreadCount > 99 ? "99+" : "\(group.unreadCount)")
                                .font(ClickTypography.badge)
                                .monospacedDigit()
                                .foregroundStyle(ClickColors.primaryActionForeground)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(ClickColors.primaryActionFill, in: Capsule())
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.vertical, 10)
        .frame(minHeight: InboxRowMetrics.minHeight)
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + ClickMetrics.Avatar.conversation + 12
        }
    }

    private var accessibilityText: String {
        var parts = [group.name, "\(group.memberCount) members"]
        if group.unreadCount > 0 { parts.append("\(group.unreadCount) unread") }
        parts.append(preview)
        return parts.joined(separator: ", ")
    }
}

/// Direct, group, and hub rows share one height so the inbox reads as one list.
enum InboxRowMetrics {
    static let minHeight: CGFloat = ClickMetrics.Avatar.conversation + 30
}

/// The one preview style for every inbox row. Two lines are always reserved, so a one-line
/// group preview is exactly as tall as a two-line DM preview.
struct InboxPreviewText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ClickTypography.supporting)
            .foregroundStyle(ClickColors.textSecondary)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The single owner of an inbox row's list insets and background (the row itself owns
    /// only its vertical padding), shared by direct, group and hub rows.
    func inboxRowChrome() -> some View {
        touchRipple(bleed: ClickSpacing.screenGutter)
            .listRowInsets(EdgeInsets(top: 0, leading: ClickSpacing.screenGutter, bottom: 0, trailing: ClickSpacing.screenGutter))
            .listRowBackground(Color.clear)
    }
}
