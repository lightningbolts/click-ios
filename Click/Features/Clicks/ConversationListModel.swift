import Foundation
import Observation

/// Owns the Clicks inbox: cached snapshot, refresh, memory-only decrypted previews, unread
/// totals for the tab badge, and optimistic connection actions with rollback.
///
/// Owned by the main shell so the Clicks tab badge is correct before the tab is ever opened.
@Observable
@MainActor
final class ConversationListModel {
    private(set) var snapshot: ClicksSnapshot?
    /// Decrypted preview text by connection ID. Never persisted.
    private(set) var previewTexts: [String: String] = [:]
    private(set) var refreshError: String?
    var actionError: String?

    private var environment: AppEnvironment?
    private let refreshesAutomatically: Bool
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private let inboxRealtime = ChatRealtimeManager()
    private var pendingRefresh: Task<Void, Never>?

    /// Refreshing again within this interval (e.g. popping back from a chat) is skipped.
    private static let staleInterval: TimeInterval = 20

    init(initialSnapshot: ClicksSnapshot? = nil) {
        self.snapshot = initialSnapshot
        // A seeded snapshot (design previews) is displayed as-is without network refreshes.
        self.refreshesAutomatically = initialSnapshot == nil
    }

    var active: [ConnectionItem] { snapshot?.connections ?? [] }
    var archived: [ConnectionItem] { snapshot?.archived ?? [] }
    var groups: [CliqueItem] { snapshot?.cliques ?? [] }
    var core: [ConnectionItem] { active.filter(\.isCore) }
    var unreadTotal: Int {
        active.reduce(0) { $0 + $1.unreadCount } + groups.reduce(0) { $0 + $1.unreadCount }
    }
    /// Hubs and event chats opened on this device (no server listing exists).
    private(set) var hubs: [JoinedHub] = []

    /// True once groups came from a successful server read (never inferred from an empty list).
    private(set) var groupsLoaded = false
    private(set) var groupsError: String?

    // MARK: - Loading

    /// Connects the model to app services. Called by the shell before the first `load()`.
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Paints the cached inbox immediately, then refreshes.
    func load() async {
        guard refreshesAutomatically, let environment else { return }
        if let userID { hubs = await environment.joinedHubs.hubs(userID: userID) }
        if snapshot == nil, let userID, let cached = await environment.phase3.cachedClicks(for: userID) {
            let cachedGroups = await CacheStore.shared.load([CliqueItem].self, key: "groups", userID: userID)
            snapshot = ClicksSnapshot(
                connections: cached.connections,
                archivedConnections: cached.archived,
                groups: cachedGroups ?? cached.groups,
                mapPins: cached.mapPins
            )
            await decryptPreviews(for: cached)
        }
        await refresh()
    }

    func refreshIfStale() async {
        guard refreshesAutomatically else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.staleInterval { return }
        await refresh()
    }

    /// Coalesces concurrent callers onto one in-flight refresh.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let environment, let userID else { return }
        Task { await refreshHubs(environment, userID: userID) }
        async let clicksTask = environment.phase3.refreshClicks(for: userID)
        async let groupsTask = environment.groups.groups(userID: userID)
        let groups: [CliqueItem]?
        do {
            groups = try await groupsTask
            groupsLoaded = true
            groupsError = nil
            await CacheStore.shared.save(groups ?? [], key: "groups", userID: userID)
        } catch {
            groups = nil
            groupsError = error.userFacingMessage
        }
        do {
            let fresh = try await clicksTask
            let merged = ClicksSnapshot(
                connections: fresh.connections,
                archivedConnections: fresh.archived,
                groups: groups ?? snapshot?.groups,
                mapPins: fresh.mapPins
            )
            snapshot = merged
            refreshError = nil
            lastRefresh = Date()
            await decryptPreviews(for: merged)
        } catch {
            refreshError = error.userFacingMessage
            if let groups, let current = snapshot {
                snapshot = ClicksSnapshot(connections: current.connections, archivedConnections: current.archived, groups: groups, mapPins: current.mapPins)
            }
        }
    }

    // MARK: - Inbox realtime (spec §35.11)

    var realtimeHealth: SubscriptionHealth { inboxRealtime.health }

    /// Subscribes to new messages the viewer can read. Known conversations update in place;
    /// an unknown chat (a new connection or group) triggers one coalesced refresh.
    func startRealtime() {
        guard refreshesAutomatically, let userID, !AppConfig.shared.supabaseAnonKey.isEmpty else { return }
        let url = AppConfig.shared.supabaseURL
        inboxRealtime.onMessageInserted = { [weak self] payload in
            Task { @MainActor in self?.applyInserted(payload) }
        }
        inboxRealtime.subscribe(
            to: userID,
            stream: .inbox,
            supabaseURL: url,
            anonKey: AppConfig.shared.supabaseAnonKey,
            authToken: environment?.session.currentSession?.jwt
        )
    }

    func stopRealtime() {
        inboxRealtime.teardown()
    }

    func applyInserted(_ payload: RealtimeMessagePayload, currentUserID: String? = nil) {
        guard let snapshot, let userID = currentUserID ?? userID else { return }
        let isOutgoing = payload.senderID == userID
        let isOpen = environment?.activeChatID == payload.chatID
        let bump = !isOutgoing && !isOpen ? 1 : 0
        let message = InboxLastMessage(
            content: payload.content,
            messageType: payload.messageType,
            isOutgoing: isOutgoing,
            isRead: false,
            isDisposable: JSONFields.bool(payload.metadata?["disposable_roll"]) ?? false
        )
        let date = Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000)

        var connections = snapshot.connections
        var archived = snapshot.archived
        var groups = snapshot.cliques
        if let index = connections.firstIndex(where: { $0.chatID == payload.chatID }) {
            let item = connections.remove(at: index)
            connections.insert(item.with(unreadCount: item.unreadCount + bump, lastMessage: message, lastActivityAt: date), at: 0)
        } else if let index = archived.firstIndex(where: { $0.chatID == payload.chatID }) {
            let item = archived[index]
            archived[index] = item.with(unreadCount: item.unreadCount + bump, lastMessage: message, lastActivityAt: date)
        } else if let index = groups.firstIndex(where: { $0.chatID == payload.chatID }) {
            let group = groups.remove(at: index)
            groups.insert(group.with(unreadCount: group.unreadCount + bump, lastMessage: message, lastActivityAt: date), at: 0)
        } else {
            scheduleRefresh()
            return
        }
        let updated = ClicksSnapshot(connections: connections, archivedConnections: archived, groups: groups, mapPins: snapshot.mapPins)
        self.snapshot = updated
        Task { await decryptPreviews(for: updated) }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - Hubs

    /// Refreshes hub previews; hubs the server reports gone or inaccessible are dropped.
    private func refreshHubs(_ environment: AppEnvironment, userID: String) async {
        let current = await environment.joinedHubs.hubs(userID: userID)
        guard !current.isEmpty else { return }
        var updated: [JoinedHub] = []
        await withTaskGroup(of: (JoinedHub, HubRepository.LatestResult?).self) { group in
            for hub in current {
                group.addTask { (hub, await environment.hubs.latest(hubID: hub.hubID)) }
            }
            for await (hub, result) in group {
                var next = hub
                switch result {
                case .gone?: continue
                case .message(let text, let sender, let date)?:
                    next.lastMessage = text
                    next.lastSenderName = sender
                    next.lastActivityAt = date
                case .empty?, nil: break
                }
                updated.append(next)
            }
        }
        await environment.joinedHubs.replaceAll(updated, userID: userID)
        hubs = updated
    }

    /// Called when a hub or event chat opens successfully.
    func rememberHub(_ hub: JoinedHub) async {
        guard let environment, let userID else { return }
        await environment.joinedHubs.upsert(hub, userID: userID)
        hubs = await environment.joinedHubs.hubs(userID: userID)
    }

    /// Called after leaving/deleting a hub or when the server denies access.
    func forgetHub(id: String) async {
        guard let environment, let userID else { return }
        await environment.joinedHubs.remove(hubID: id, userID: userID)
        hubs.removeAll { $0.hubID == id }
    }

    /// Replaces one group after a local management change (rename, membership).
    func replaceGroup(_ group: CliqueItem) {
        guard let snapshot else { return }
        self.snapshot = ClicksSnapshot(
            connections: snapshot.connections,
            archivedConnections: snapshot.archived,
            groups: snapshot.cliques.map { $0.id == group.id ? group : $0 },
            mapPins: snapshot.mapPins
        )
    }

    /// Drops a group the user left or deleted (after the server confirmed).
    func removeGroup(id: String) {
        guard let snapshot else { return }
        self.snapshot = ClicksSnapshot(
            connections: snapshot.connections,
            archivedConnections: snapshot.archived,
            groups: snapshot.cliques.filter { $0.id != id },
            mapPins: snapshot.mapPins
        )
    }

    func markGroupOpened(_ group: CliqueItem) {
        replaceGroup(group.with(unreadCount: 0))
    }

    /// Drops a connection the user removed or blocked (after the server confirmed).
    func removeConnection(connectionID: String) {
        guard let snapshot else { return }
        self.snapshot = ClicksSnapshot(
            connections: snapshot.connections.filter { $0.connectionID != connectionID },
            archivedConnections: snapshot.archived.filter { $0.connectionID != connectionID },
            groups: snapshot.groups,
            mapPins: snapshot.pins.filter { $0.connectionID != connectionID }
        )
    }

    private func decryptPreviews(for snapshot: ClicksSnapshot) async {
        guard let environment, let userID else { return }
        var texts: [String: String] = [:]
        for item in snapshot.connections + snapshot.archived {
            guard let message = item.lastMessage else { continue }
            if let text = await environment.chat.inboxPreviewText(
                message.content,
                chatID: item.chatID,
                connectionID: item.connectionID,
                peerUserID: item.userID,
                currentUserID: userID
            ) {
                texts[item.connectionID] = text
            }
        }
        for group in snapshot.cliques {
            guard let message = group.lastMessage else { continue }
            // Group previews decrypt only from key material already held on this device.
            if let text = await environment.chat.groupPreviewText(message.content, chatID: group.chatID, groupID: group.id) {
                texts[Self.groupPreviewKey(group.chatID)] = text
            }
        }
        previewTexts = texts
    }

    private static func groupPreviewKey(_ chatID: String) -> String { "group:\(chatID)" }

    func previewText(for group: CliqueItem) -> String {
        guard let message = group.lastMessage else { return "\(group.memberCount) members" }
        let prefix = message.isOutgoing ? "You: " : message.senderName.map { "\($0): " } ?? ""
        switch message.messageType.lowercased() {
        case "image", "photo": return prefix + "Photo"
        case "audio", "voice", "voice_note": return prefix + "Voice note"
        case "file", "document": return prefix + "File"
        case "beacon", "event", "event_share", "beacon_share": return prefix + "Shared an event"
        default:
            if let text = previewTexts[Self.groupPreviewKey(group.chatID)] {
                return prefix + text.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
            let encrypted = ClickCryptoV1.isEncrypted(message.content) || ClickCryptoV2.isEncrypted(message.content)
                || message.content.hasPrefix("e2e_grp:")
            return prefix + (encrypted ? "Message" : message.content)
        }
    }

    // MARK: - Row state and actions

    func previewText(for item: ConnectionItem) -> String {
        InboxFormatting.preview(for: item, decryptedText: previewTexts[item.connectionID])
    }

    /// Clears the unread badge as the chat opens; the conversation marks messages read on the
    /// server and the next refresh reconciles.
    func markOpened(_ item: ConnectionItem) {
        replace(item.with(unreadCount: 0))
    }

    func setCore(_ item: ConnectionItem, isCore: Bool) async {
        guard let environment else { return }
        let original = item
        replace(item.with(isCore: isCore))
        ClickHaptics.selection()
        do {
            try await environment.phase3.setCore(connectionID: item.connectionID, isCore: isCore)
        } catch {
            replace(original)
            actionError = isCore ? "Couldn't add to Core. Try again." : "Couldn't remove from Core. Try again."
        }
    }

    func setArchived(_ item: ConnectionItem, archived: Bool) async {
        guard let environment, let before = snapshot else { return }
        move(item, toArchived: archived)
        do {
            try await environment.phase3.setArchived(connectionID: item.connectionID, archived: archived)
        } catch {
            snapshot = before
            actionError = archived ? "Couldn't archive this Click. Try again." : "Couldn't restore this Click. Try again."
        }
    }

    // MARK: - Private

    private var userID: String? { environment?.session.currentSession?.userId }

    private func replace(_ item: ConnectionItem) {
        guard let snapshot else { return }
        func swap(_ list: [ConnectionItem]) -> [ConnectionItem] {
            list.map { $0.id == item.id ? item : $0 }
        }
        self.snapshot = ClicksSnapshot(
            connections: swap(snapshot.connections),
            archivedConnections: swap(snapshot.archived),
            groups: snapshot.groups,
            mapPins: snapshot.mapPins
        )
    }

    private func move(_ item: ConnectionItem, toArchived archived: Bool) {
        guard let snapshot else { return }
        var active = snapshot.connections.filter { $0.id != item.id }
        var archivedList = snapshot.archived.filter { $0.id != item.id }
        let byActivity: (ConnectionItem, ConnectionItem) -> Bool = {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
        if archived {
            archivedList = (archivedList + [item]).sorted(by: byActivity)
        } else {
            active = (active + [item]).sorted(by: byActivity)
        }
        self.snapshot = ClicksSnapshot(
            connections: active,
            archivedConnections: archivedList,
            groups: snapshot.groups,
            mapPins: snapshot.mapPins
        )
    }
}
