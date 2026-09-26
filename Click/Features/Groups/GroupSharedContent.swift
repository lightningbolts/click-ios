import QuickLook
import SwiftUI

/// A group's shared photos/voice notes, files, or event/beacon cards, opened from the group
/// profile (decrypted with the group's keys, the same pipeline as chat).
struct GroupSharedView: View {
    enum Kind: String {
        case media = "Media"
        case files = "Files"
        case beacons = "Events & beacons"
    }

    @Environment(AppEnvironment.self) private var env
    let group: CliqueItem
    let kind: Kind

    @State private var items: [ChatMessageItem] = []
    @State private var beacons: [SharedItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var mediaURLs: [String: URL] = [:]
    @State private var viewerURL: ProfileViewerURL?
    @State private var quickLookURL: URL?
    @State private var tabs: SharedTabs?
    @State private var isLoadingMore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !loaded {
                    ClickLoadingView(size: 32, fillsSpace: false).padding(28)
                } else if let error {
                    Button("Couldn't load. \(error) Retry") { Task { await load() } }.padding()
                } else if kind == .beacons {
                    if beacons.isEmpty { empty }
                    ForEach(beacons) { item in
                        Button {
                            if let id = item.beaconID { env.router.navigate(to: .event(beaconID: id)) }
                        } label: {
                            HStack(spacing: 12) {
                                BeaconVisual(beaconID: item.beaconID, seed: item.beaconID ?? item.id, imageURL: item.beaconImageURL).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.beaconTitle ?? "Event").foregroundStyle(ClickColors.textPrimary)
                                    if let date = item.createdAt {
                                        Text("Shared \(date.formatted(date: .abbreviated, time: .omitted))")
                                            .font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(ClickColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else if items.isEmpty {
                    empty
                } else if kind == .media {
                    let photos = items.filter { $0.media?.kind == .image }
                    let prefetchFrom = Set(photos.suffix(12).map(\.id))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { item in
                            ProfileMediaThumbnail(item: item, load: { try await url(for: item) }) { viewerURL = ProfileViewerURL(url: $0) }
                                .onAppear { if prefetchFrom.contains(item.id) { Task { await loadMore() } } }
                        }
                    }
                    ForEach(items.filter { $0.media?.kind == .audio }) { item in
                        if let media = item.media {
                            MessageMediaContent(message: item, media: media, load: { try await url(for: item) }, onOpen: { _ in })
                        }
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { item in
                            if let media = item.media {
                                MessageMediaContent(message: item, media: media, load: { try await url(for: item) }) { quickLookURL = $0 }
                                    .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                            }
                        }
                    }
                }
            }
            .padding(ClickSpacing.screenGutter)
        }
        .navigationTitle(kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewerURL) { MediaViewer(url: $0.url) }
        .quickLookPreview($quickLookURL)
        .task { if !loaded { await load() } }
    }

    private var empty: some View {
        Text("Nothing shared yet.").foregroundStyle(ClickColors.textTertiary).frame(maxWidth: .infinity).padding(40)
    }

    private func url(for item: ChatMessageItem) async throws -> URL {
        if let url = mediaURLs[item.id] { return url }
        guard let userID = env.session.currentSession?.userId else { throw ChatRepositoryError.mediaUnavailable }
        let url = try await env.chat.loadMedia(for: item, conversation: group.chatRoute.conversationIdentity, currentUserID: userID)
        mediaURLs[item.id] = url
        return url
    }

    private func load() async {
        defer { loaded = true }
        guard let userID = env.session.currentSession?.userId else { return }
        do {
            let tabs = try await env.profiles.sharedTabs(chatID: group.chatID)
            self.tabs = tabs
            beacons = tabs.beacons
            let rows = kind == .files ? tabs.fileRows : tabs.mediaRows
            items = await env.chat.items(fromRows: rows, conversation: group.chatRoute.conversationIdentity, currentUserID: userID)
                .filter { $0.media != nil }
            error = nil
        } catch {
            self.error = error.userFacingMessage
        }
    }
}

extension GroupSharedView {
    /// Next (older) page, appended as the grid nears its end.
    fileprivate func loadMore() async {
        guard !isLoadingMore, let current = tabs, current.hasMore == true, let cursor = current.oldestAttachment,
              let userID = env.session.currentSession?.userId else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await env.profiles.sharedTabs(chatID: group.chatID, before: cursor) else { return }
        tabs = current.appending(page)
        let known = Set(items.map(\.id))
        let rows = kind == .files ? page.fileRows : page.mediaRows
        items += await env.chat.items(fromRows: rows, conversation: group.chatRoute.conversationIdentity, currentUserID: userID)
            .filter { $0.media != nil && !known.contains($0.id) }
    }
}

/// Interests shared by two or more members (from each member's public profile tags).
struct GroupCommonInterests: View {
    @Environment(AppEnvironment.self) private var env
    let members: [GroupMember]

    @State private var counts: [(tag: String, count: Int)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ClickLoadingView(size: 26, fillsSpace: false)
            } else if counts.isEmpty {
                Text("No interests in common yet.").foregroundStyle(ClickColors.textTertiary)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(counts, id: \.tag) { item in
                        Text("\(item.tag) · \(item.count)")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.accentForeground)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(ClickColors.selectionTint, in: Capsule())
                    }
                }
            }
        }
        .task(id: members.map(\.userID)) { await load() }
    }

    private func load() async {
        guard let viewerID = env.session.currentSession?.userId else { return }
        var tally: [String: (label: String, count: Int)] = [:]
        await withTaskGroup(of: [String].self) { group in
            for member in members.prefix(15) {
                group.addTask {
                    if let cached = await env.profiles.cachedProfile(userID: member.userID, viewerID: viewerID) { return cached.interests }
                    return (try? await env.profiles.profile(userID: member.userID, connectionID: nil, viewerID: viewerID))?.interests ?? []
                }
            }
            for await tags in group {
                for tag in Set(tags.map { $0.lowercased() }) {
                    let label = tags.first { $0.lowercased() == tag } ?? tag
                    tally[tag] = (label, (tally[tag]?.count ?? 0) + 1)
                }
            }
        }
        counts = tally.values.filter { $0.count >= 2 }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
            .map { ($0.label, $0.count) }
        loaded = true
    }
}

/// Everything a group's profile shows that its members make together: journal notes, group
/// hangouts (you with two or more members at once) and upcoming plans. One cached model per
/// group, prefetched when the group chat opens, so the profile opens filled.
@Observable
@MainActor
final class GroupSpaceModel {
    let chatID: String
    private(set) var journal = ModuleState<[JournalEntry]>()
    private(set) var hangouts: [GroupHangout] = []
    private(set) var upcomingPlans: [ChatMessageItem] = []
    private var lastLoaded: Date?

    private static var registry: [String: GroupSpaceModel] = [:]

    static func shared(chatID: String) -> GroupSpaceModel {
        if let existing = registry[chatID] { return existing }
        let model = GroupSpaceModel(chatID: chatID)
        registry[chatID] = model
        return model
    }

    static func resetRegistry() { registry = [:] }

    private init(chatID: String) {
        self.chatID = chatID
    }

    /// Refreshes unless it was refreshed moments ago. `memberConnections`: member user ID →
    /// your connection with them (group hangouts are built from your own encounters).
    func load(_ env: AppEnvironment, memberConnections: [String: String], force: Bool = false) async {
        guard let userID = env.session.currentSession?.userId else { return }
        upcomingPlans = UpcomingPlans.in(chatID: chatID, userID: userID)
        if !force, let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 30 { return }
        lastLoaded = .now
        async let notes: Void = loadJournal(env)
        async let together: Void = loadHangouts(env, memberConnections: memberConnections)
        _ = await (notes, together)
    }

    func loadJournal(_ env: AppEnvironment) async {
        journal.begin()
        do { journal.succeed(try await env.profiles.journal(targetUserID: chatID, targetType: "chat")) }
        catch { journal.fail(error) }
    }

    private func loadHangouts(_ env: AppEnvironment, memberConnections: [String: String]) async {
        var tagged: [(userID: String, encounter: Encounter)] = []
        await withTaskGroup(of: [(String, Encounter)].self) { group in
            for (memberID, connectionID) in memberConnections {
                group.addTask {
                    let encounters = (try? await env.profiles.encounters(connectionID: connectionID)) ?? []
                    return encounters.map { (memberID, $0) }
                }
            }
            for await batch in group { tagged += batch.map { (userID: $0.0, encounter: $0.1) } }
        }
        hangouts = GroupHangout.clusters(tagged)
    }
}

/// A moment you were with two or more members of a group (encounters within two hours).
struct GroupHangout: Equatable, Identifiable {
    /// The earliest encounter, preferring one with a location (date, place, map pin).
    let representative: Encounter
    let memberIDs: Set<String>
    var id: String { representative.id }

    static func clusters(_ tagged: [(userID: String, encounter: Encounter)], window: TimeInterval = 2 * 3600) -> [GroupHangout] {
        let ordered = tagged.sorted { $0.encounter.date < $1.encounter.date }
        var result: [GroupHangout] = []
        var current: [(userID: String, encounter: Encounter)] = []
        func flush() {
            let members = Set(current.map(\.userID))
            guard members.count >= 2, let first = current.first?.encounter else { return }
            let located = current.map(\.encounter).first { $0.latitude != nil } ?? first
            result.append(GroupHangout(representative: located, memberIDs: members))
        }
        for item in ordered {
            if let start = current.first?.encounter.date, item.encounter.date.timeIntervalSince(start) > window {
                flush()
                current = []
            }
            current.append(item)
        }
        flush()
        return result
    }
}

/// Plans made in a chat that haven't ended, soonest first (from the on-device timeline, so
/// they show instantly and offline).
enum UpcomingPlans {
    static func `in`(chatID: String, userID: String, now: Date = .now) -> [ChatMessageItem] {
        LocalStore.shared.latestMessages(conversation: chatID, userID: userID, limit: 400)
            .filter { !$0.isDeleted && ($0.plan?.endsOrAssumedEnd ?? .distantPast) > now }
            .sorted { $0.plan!.startsAt < $1.plan!.startsAt }
    }
}

/// Journal notes on a group (`target_type: chat`).
struct GroupJournalSection: View {
    @Environment(AppEnvironment.self) private var env
    let chatID: String

    @State private var editor: JournalEditorTarget?
    private var model: GroupSpaceModel { GroupSpaceModel.shared(chatID: chatID) }
    private var entries: ModuleState<[JournalEntry]> { model.journal }

    var body: some View {
        Group {
            Button {
                editor = JournalEditorTarget(entry: nil)
            } label: {
                Label("Add journal note", systemImage: "square.and.pencil")
            }
            if let list = entries.value {
                ForEach(list) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(entry.visibility == .private ? "Note to self" : "Shared note") · \(entry.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textTertiary)
                        Text(entry.body).foregroundStyle(ClickColors.textPrimary)
                    }
                    .contextMenu {
                        if entry.authorID == env.session.currentSession?.userId {
                            Button("Edit", systemImage: "pencil") { editor = JournalEditorTarget(entry: entry) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { try? await env.profiles.deleteJournal(id: entry.id); await load() }
                            }
                        }
                    }
                }
            } else if entries.errorMessage != nil {
                Button("Couldn't load notes. Retry") { Task { await load() } }
            }
        }
        .sheet(item: $editor) { target in
            JournalEditor(target: target) { body, visibility in
                if let entry = target.entry {
                    try await env.profiles.updateJournal(id: entry.id, body: body, visibility: visibility)
                } else {
                    try await env.profiles.addJournal(targetUserID: chatID, body: body, visibility: visibility, targetType: "chat")
                }
                await load()
            }
        }
        // Normally prefetched with the group; this covers a cold open.
        .task { if entries.value == nil { await load() } }
    }

    private func load() async {
        await model.loadJournal(env)
    }
}
