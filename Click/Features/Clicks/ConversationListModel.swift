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
    var unreadTotal: Int { active.reduce(0) { $0 + $1.unreadCount } }

    // MARK: - Loading

    /// Connects the model to app services. Called by the shell before the first `load()`.
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Paints the cached inbox immediately, then refreshes.
    func load() async {
        guard refreshesAutomatically, let environment else { return }
        if snapshot == nil, let userID, let cached = await environment.phase3.cachedClicks(for: userID) {
            snapshot = cached
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
        do {
            let fresh = try await environment.phase3.refreshClicks(for: userID)
            snapshot = fresh
            refreshError = nil
            lastRefresh = Date()
            await decryptPreviews(for: fresh)
        } catch {
            refreshError = error.localizedDescription
        }
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
        previewTexts = texts
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
            groups: snapshot.groups
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
        self.snapshot = ClicksSnapshot(connections: active, archivedConnections: archivedList, groups: snapshot.groups)
    }
}
