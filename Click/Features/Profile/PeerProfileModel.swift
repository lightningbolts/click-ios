import Foundation
import Observation

/// One entry in a relationship Timeline: a real-world encounter or a journal note.
enum TimelineItem: Identifiable, Equatable {
    case encounter(Encounter, isFirst: Bool)
    case journal(JournalEntry)

    var id: String {
        switch self {
        case .encounter(let encounter, _): "encounter.\(encounter.id)"
        case .journal(let entry): "journal.\(entry.id)"
        }
    }

    var date: Date {
        switch self {
        case .encounter(let encounter, _): encounter.date
        case .journal(let entry): entry.createdAt ?? .distantPast
        }
    }
}

/// State for the canonical person profile (spec §47). Each tab loads independently; a failed
/// optional tab never blocks identity or Timeline.
@Observable
@MainActor
final class PeerProfileModel {
    let userID: String
    private(set) var connectionID: String?

    private(set) var profile = ModuleState<PeerProfile>()
    private(set) var encounters = ModuleState<[Encounter]>()
    private(set) var journal = ModuleState<[JournalEntry]>()
    private(set) var tabs = ModuleState<SharedTabs>()
    private(set) var links = ModuleState<[URL]>()
    /// Shared photos/voice notes and files as decryptable message items.
    private(set) var mediaItems: [ChatMessageItem] = []
    private(set) var fileItems: [ChatMessageItem] = []
    private var mediaURLs: [String: URL] = [:]

    private var environment: AppEnvironment?
    private var lastLoaded: Date?

    /// One model per person for the session, so returning to a profile paints its last state
    /// immediately and refreshes in place instead of starting from spinners.
    private static var registry: [String: PeerProfileModel] = [:]

    static func shared(userID: String, connectionID: String?) -> PeerProfileModel {
        if let existing = registry[userID] {
            if existing.connectionID == nil, let connectionID { existing.connectionID = connectionID }
            return existing
        }
        let model = PeerProfileModel(userID: userID, connectionID: connectionID)
        registry[userID] = model
        return model
    }

    static func resetRegistry() {
        registry = [:]
    }

    init(userID: String, connectionID: String?) {
        self.userID = userID
        self.connectionID = connectionID
    }

    var timeline: [TimelineItem] {
        let firstID = encounters.value?.min { $0.date < $1.date }?.id
        let items = (encounters.value ?? []).map { TimelineItem.encounter($0, isFirst: $0.id == firstID) }
            + (journal.value ?? []).map(TimelineItem.journal)
        return items.sorted { $0.date > $1.date }
    }

    /// "Clicked Sep 12 at Café Allegro · 3 encounters" from real encounter rows only.
    var relationshipLine: String? {
        guard let all = encounters.value, let first = all.min(by: { $0.date < $1.date }) else { return nil }
        var line = "Clicked \(first.date.formatted(.dateTime.month(.abbreviated).day()))"
        if let place = first.place { line += " at \(place)" }
        if all.count > 1 { line += " · \(all.count) encounters" }
        return line
    }

    func attach(_ environment: AppEnvironment, fallbackConnectionID: String?) {
        self.environment = environment
        if connectionID == nil { connectionID = fallbackConnectionID }
    }

    /// Refreshes everything unless it was refreshed moments ago (`force` for pull-to-refresh).
    func load(force: Bool = false) async {
        guard let environment, let viewerID = environment.session.currentSession?.userId else { return }
        if !force, let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 30 { return }
        lastLoaded = .now
        profile.seed(await environment.profiles.cachedProfile(userID: userID, viewerID: viewerID))
        encounters.seed(await CacheStore.shared.load([Encounter].self, key: "encounters.\(userID)", userID: viewerID))
        journal.seed(await CacheStore.shared.load([JournalEntry].self, key: "journal.\(userID)", userID: viewerID))
        async let identity: Void = loadProfile()
        async let history: Void = loadEncounters()
        async let notes: Void = loadJournal()
        async let shared: Void = loadTabs()
        _ = await (identity, history, notes, shared)
    }

    func loadProfile() async {
        guard let environment, let viewerID = environment.session.currentSession?.userId else { return }
        profile.begin()
        do {
            profile.succeed(try await environment.profiles.profile(userID: userID, connectionID: connectionID, viewerID: viewerID))
        } catch {
            profile.fail(error)
        }
    }

    func loadEncounters() async {
        guard let environment, let connectionID else {
            encounters.markUnavailable("Timeline history appears once you're connected.")
            return
        }
        encounters.begin()
        do {
            let fresh = try await environment.profiles.encounters(connectionID: connectionID)
            encounters.succeed(fresh)
            if let viewerID = environment.session.currentSession?.userId {
                await CacheStore.shared.save(fresh, key: "encounters.\(userID)", userID: viewerID)
            }
        } catch {
            encounters.fail(error)
        }
    }

    func loadJournal() async {
        guard let environment else { return }
        journal.begin()
        do {
            let fresh = try await environment.profiles.journal(targetUserID: userID)
            journal.succeed(fresh)
            if let viewerID = environment.session.currentSession?.userId {
                await CacheStore.shared.save(fresh, key: "journal.\(userID)", userID: viewerID)
            }
        } catch {
            journal.fail(error)
        }
    }

    func loadTabs() async {
        guard let environment, let connectionID else {
            tabs.markUnavailable("Shared content appears once you're connected.")
            return
        }
        // Paint the stored tabs at once; refetch only when they're over two minutes old.
        let viewerID = environment.session.currentSession?.userId ?? ""
        let key = "profile.tabs.\(connectionID)"
        if tabs.value == nil, let stored = LocalStore.shared.load(SharedTabs.self, key: key, userID: viewerID) {
            tabs.seed(stored.value)
            await loadMediaItems(stored.value)
            if Date().timeIntervalSince(stored.savedAt) < 120 {
                tabs.succeedKeepingValue()
                return
            }
        }
        tabs.begin()
        do {
            let fresh = try await environment.profiles.sharedTabs(connectionID: connectionID)
            tabs.succeed(fresh)
            LocalStore.shared.save(fresh, key: key, userID: viewerID)
            await loadMediaItems(fresh)
        } catch {
            tabs.fail(error)
        }
    }

    /// Links are extracted on this device from decrypted messages; the server cannot read v2
    /// message text (spec §47.6). Only http(s) URLs are kept.
    func loadLinks(peerName: String) async {
        guard links.value == nil, let environment, let connectionID,
              let currentUserID = environment.session.currentSession?.userId else {
            if connectionID == nil { links.markUnavailable("Links appear once you're connected.") }
            return
        }
        links.begin()
        do {
            let conversation = ConversationIdentity(
                chatID: connectionID,
                connectionID: connectionID,
                peerUserID: userID,
                peerDisplayName: peerName
            )
            let messages = try await environment.chat.fetchMessages(
                conversation: conversation,
                currentUserID: currentUserID,
                cursor: nil,
                limit: 200
            )
            links.succeed(Self.extractLinks(from: messages.map(\.content)))
        } catch {
            links.fail(error)
        }
    }

    private var conversation: ConversationIdentity? {
        guard let connectionID else { return nil }
        return ConversationIdentity(
            chatID: tabs.value?.chatID.nonEmptyTrimmed ?? connectionID,
            connectionID: connectionID,
            peerUserID: userID,
            peerDisplayName: profile.value?.displayName ?? "Click user"
        )
    }

    private func loadMediaItems(_ tabs: SharedTabs) async {
        guard let environment, let conversation, let viewerID = environment.session.currentSession?.userId else { return }
        mediaItems = await environment.chat.items(fromRows: tabs.mediaRows, conversation: conversation, currentUserID: viewerID)
            .filter { $0.media != nil }
        fileItems = await environment.chat.items(fromRows: tabs.fileRows, conversation: conversation, currentUserID: viewerID)
            .filter { $0.media != nil }
    }

    /// Decrypted local file for a shared item (downloaded once, then vault-cached).
    func mediaURL(for item: ChatMessageItem) async throws -> URL {
        if let url = mediaURLs[item.id] { return url }
        guard let environment, let conversation, let viewerID = environment.session.currentSession?.userId else {
            throw ChatRepositoryError.mediaUnavailable
        }
        let url = try await environment.chat.loadMedia(for: item, conversation: conversation, currentUserID: viewerID)
        mediaURLs[item.id] = url
        return url
    }

    // MARK: - Journal mutations

    func saveJournal(body: String, visibility: JournalEntry.Visibility, editing entry: JournalEntry?) async throws {
        guard let environment else { return }
        if let entry {
            try await environment.profiles.updateJournal(id: entry.id, body: body, visibility: visibility)
        } else {
            try await environment.profiles.addJournal(targetUserID: userID, body: body, visibility: visibility)
        }
        await loadJournal()
    }

    func deleteJournal(_ entry: JournalEntry) async throws {
        guard let environment else { return }
        try await environment.profiles.deleteJournal(id: entry.id)
        await loadJournal()
    }

    // MARK: - Pure helpers

    static func extractLinks(from texts: [String]) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      seen.insert(url.absoluteString).inserted else { continue }
                result.append(url)
            }
        }
        return result
    }
}
