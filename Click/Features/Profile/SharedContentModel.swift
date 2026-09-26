import Foundation
import Observation

/// A conversation's shared photos/voice notes, files and event cards, decrypted on this device,
/// for person and group profiles. Stored, so a profile opens filled even right after launch;
/// refetched when over two minutes old; paged as the grid nears its end. The grid's first rows
/// are decoded ahead of display.
@Observable
@MainActor
final class SharedContentModel {
    private(set) var tabs = ModuleState<SharedTabs>()
    /// Shared photos/voice notes and files as decryptable message items.
    private(set) var mediaItems: [ChatMessageItem] = []
    private(set) var fileItems: [ChatMessageItem] = []
    private(set) var isLoadingMore = false

    /// A person's tabs are read by connection, a group's by chat.
    private let connectionID: String?
    private let chatID: String?
    private var mediaURLs: [String: URL] = [:]
    private var environment: AppEnvironment?
    /// The conversation shared items decrypt in (a person's chat ID comes with the tabs).
    private var identity: (SharedTabs) -> ConversationIdentity? = { _ in nil }

    private static let prefetchedThumbnails = 9

    init(connectionID: String?, chatID: String? = nil) {
        self.connectionID = connectionID
        self.chatID = chatID
    }

    private var storeKey: String { connectionID.map { "profile.tabs.\($0)" } ?? "group.tabs.\(chatID ?? "")" }
    private var viewerID: String { environment?.session.currentSession?.userId ?? "" }
    private var conversation: ConversationIdentity? { tabs.value.flatMap(identity) }

    func load(_ environment: AppEnvironment, identity: @escaping (SharedTabs) -> ConversationIdentity?) async {
        self.environment = environment
        self.identity = identity
        guard connectionID != nil || chatID != nil else {
            tabs.markUnavailable("Shared content appears once you're connected.")
            return
        }
        // Paint the stored tabs at once; refetch only when they're over two minutes old.
        if tabs.value == nil, let stored = LocalStore.shared.load(SharedTabs.self, key: storeKey, userID: viewerID) {
            tabs.seed(stored.value)
            await decryptItems()
            if Date().timeIntervalSince(stored.savedAt) < 120 {
                tabs.succeedKeepingValue()
                return
            }
        }
        tabs.begin()
        do {
            let fresh = try await environment.profiles.sharedTabs(connectionID: connectionID, chatID: chatID)
            tabs.succeed(fresh)
            LocalStore.shared.save(fresh, key: storeKey, userID: viewerID)
            await decryptItems()
        } catch {
            tabs.fail(error)
        }
    }

    /// Fetches the next (older) page of shared media/files and appends it; called as the grid
    /// nears its end, so the user never waits at the bottom.
    func loadMore() async {
        guard !isLoadingMore, let environment, let current = tabs.value, current.hasMore == true,
              let cursor = current.oldestAttachment, let conversation else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await environment.profiles.sharedTabs(connectionID: connectionID, chatID: chatID, before: cursor) else { return }
        let merged = current.appending(page)
        tabs.succeed(merged)
        LocalStore.shared.save(merged, key: storeKey, userID: viewerID)
        let known = Set((mediaItems + fileItems).map(\.id))
        mediaItems += await items(page.mediaRows, in: conversation).filter { !known.contains($0.id) }
        fileItems += await items(page.fileRows, in: conversation).filter { !known.contains($0.id) }
    }

    /// Decrypted local file for a shared item (downloaded once, then vault-cached).
    func mediaURL(for item: ChatMessageItem) async throws -> URL {
        if let url = mediaURLs[item.id] { return url }
        guard let environment, let conversation else { throw ChatRepositoryError.mediaUnavailable }
        let url = try await environment.chat.loadMedia(for: item, conversation: conversation, currentUserID: viewerID)
        mediaURLs[item.id] = url
        return url
    }

    private func decryptItems() async {
        guard let tabs = tabs.value, let conversation else { return }
        mediaItems = await items(tabs.mediaRows, in: conversation)
        fileItems = await items(tabs.fileRows, in: conversation)
        // The grid's first rows, decoded now: the profile opens with its photos in place.
        await withTaskGroup(of: Void.self) { group in
            for item in mediaItems.filter({ $0.media?.kind == .image }).prefix(Self.prefetchedThumbnails) {
                group.addTask { await ProfileMediaThumbnail.prefetch(item) { @Sendable in try await self.mediaURL(for: item) } }
            }
        }
    }

    private func items(_ rows: Data, in conversation: ConversationIdentity) async -> [ChatMessageItem] {
        guard let environment else { return [] }
        return await environment.chat.items(fromRows: rows, conversation: conversation, currentUserID: viewerID)
            .filter { $0.media != nil }
    }
}
