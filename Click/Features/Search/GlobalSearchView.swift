import SwiftUI

/// Search scopes (KMP `SearchResultCategory`).
enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case archived = "Archived"
    case groups = "Groups"
    case nearby = "Nearby"
    case beacons = "Beacons"
    case intents = "Intents"

    var id: String { rawValue }
}

/// One unified search row. Identity is the underlying entity, so refreshes don't reshuffle rows.
enum SearchResult: Identifiable, Equatable {
    case person(ConnectionItem, archived: Bool, reason: String?)
    case group(CliqueItem, reason: String?)
    case beacon(MapBeacon)
    case hub(NearbyHub)
    case ownIntent(AvailabilityIntentPost)
    case message(MessageHit)

    var id: String {
        switch self {
        case .person(let item, _, _): "person.\(item.id)"
        case .group(let group, _): "group.\(group.id)"
        case .beacon(let beacon): "beacon.\(beacon.id)"
        case .hub(let hub): "hub.\(hub.id)"
        case .ownIntent(let intent): "intent.\(intent.id)"
        case .message(let hit): "message.\(hit.messageID)"
        }
    }

    var scopes: Set<SearchScope> {
        switch self {
        case .person(_, let archived, _): [archived ? .archived : .active]
        case .group: [.groups]
        case .beacon: [.beacons, .nearby]
        case .hub: [.nearby]
        case .ownIntent: [.intents, .active]
        case .message(let hit): hit.isHub ? [.nearby] : [.active]
        }
    }
}

/// A server message hit (`GET /api/chat/search`). Only plaintext bodies can match server-side.
struct MessageHit: Equatable, Sendable {
    let messageID: String
    let chatID: String
    let connectionID: String?
    let chatName: String
    let snippet: String
    let date: Date?
    let isHub: Bool
    let hubID: String?

    static func decode(_ row: [String: Any]) -> MessageHit? {
        guard let id = JSONFields.string(row["messageId"]), let chat = JSONFields.string(row["chatId"]) else { return nil }
        return MessageHit(
            messageID: id,
            chatID: chat,
            connectionID: JSONFields.string(row["connectionId"]),
            chatName: JSONFields.string(row["chatName"]) ?? "Conversation",
            snippet: JSONFields.string(row["snippet"]) ?? "",
            date: JSONFields.date(row["timestamp"]),
            isHub: JSONFields.bool(row["isHub"]) ?? false,
            hubID: JSONFields.string(row["hubId"])
        )
    }
}

enum SearchIndex {
    /// Immediate on-device matching over data the app already holds.
    static func local(
        query: String,
        active: [ConnectionItem],
        archived: [ConnectionItem],
        groups: [CliqueItem],
        beacons: [MapBeacon],
        hubs: [NearbyHub],
        intents: [AvailabilityIntentPost]
    ) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        func has(_ text: String?) -> Bool { text?.localizedCaseInsensitiveContains(q) == true }

        var results: [SearchResult] = []
        results += intents.filter { has($0.tag) }.map(SearchResult.ownIntent)
        for (list, isArchived) in [(active, false), (archived, true)] {
            for item in list {
                if has(item.displayName) {
                    results.append(.person(item, archived: isArchived, reason: nil))
                } else if let tag = item.mutualTags.first(where: has) {
                    results.append(.person(item, archived: isArchived, reason: "Shared interest: \(tag)"))
                } else if has(item.encounterLocation) {
                    results.append(.person(item, archived: isArchived, reason: "Met at \(item.encounterLocation)"))
                }
            }
        }
        for group in groups {
            if has(group.name) {
                results.append(.group(group, reason: nil))
            } else if let member = group.members.first(where: { has($0.name) }) {
                results.append(.group(group, reason: "With \(member.name)"))
            }
        }
        results += beacons.filter { has($0.title) || has($0.locationName) || $0.eventCategories.contains(where: has) }.map(SearchResult.beacon)
        results += hubs.filter { has($0.name) || has($0.category) }.map(SearchResult.hub)
        return results
    }
}

/// Canonical cross-domain search (spec §21), presented from the root search controls.
/// Local matches appear immediately; server message search is debounced, cancellable, and a
/// server failure is shown as an error — never as "No results".
struct GlobalSearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var beacons: [MapBeacon] = []
    @State private var hubs: [NearbyHub] = []
    @State private var intents: [AvailabilityIntentPost] = []
    @State private var remote = ModuleState<[MessageHit]>()

    private var clean: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var localResults: [SearchResult] {
        SearchIndex.local(
            query: clean,
            active: conversations.active,
            archived: conversations.archived,
            groups: conversations.groups,
            beacons: beacons,
            hubs: hubs,
            intents: intents
        )
    }

    private var results: [SearchResult] {
        let messages = (remote.value ?? []).map(SearchResult.message)
        let all = localResults + messages
        return scope == .all ? all : all.filter { $0.scopes.contains(scope) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !clean.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(SearchScope.allCases) { item in
                                    Button(item.rawValue) { scope = item }
                                        .buttonStyle(.bordered)
                                        .tint(scope == item ? ClickColors.accentForeground : ClickColors.textSecondary)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                content
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "People, groups, places, events")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await loadLocalSources() }
            .task(id: clean) { await searchMessages() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if clean.isEmpty {
            ContentUnavailableView {
                Label("Search Click", systemImage: "magnifyingglass")
            } description: {
                Text("Find people, groups, events, hubs, and your availability posts.")
            }
            .listRowSeparator(.hidden)
        } else {
            ForEach(results) { row($0) }
            messageStatus
        }
    }

    /// Message-search state, kept distinct from "no results".
    @ViewBuilder
    private var messageStatus: some View {
        if clean.count >= 2 {
            if remote.isPending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching messages…").foregroundStyle(ClickColors.textSecondary)
                }
                .font(ClickTypography.supporting)
            } else if let error = remote.errorMessage {
                Button {
                    Task { await searchMessages() }
                } label: {
                    Label("Couldn't search messages. \(error) Tap to retry.", systemImage: "exclamationmark.triangle")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: clean)
                    .listRowSeparator(.hidden)
            }
            if !remote.isPending {
                Text("Encrypted messages can't be searched on the server; open a conversation to find text in it.")
                    .font(ClickTypography.caption)
                    .foregroundStyle(ClickColors.textTertiary)
                    .listRowSeparator(.hidden)
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: clean)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ result: SearchResult) -> some View {
        switch result {
        case .person(let item, let archived, let reason):
            resultRow(
                title: item.displayName,
                subtitle: reason ?? (archived ? "Archived" : item.encounterLocation.nonEmptyTrimmed),
                avatar: AnyView(AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 40))
            ) {
                open(.chat(DirectChatRoute(
                    chatID: item.chatID, connectionID: item.connectionID, peerUserID: item.userID,
                    peerDisplayName: item.displayName, peerHandle: item.handle, peerAvatarURL: item.avatarUrl
                )))
            }
            .contextMenu {
                Button("View Profile", systemImage: "person.crop.circle") {
                    open(.userProfile(userID: item.userID, connectionID: item.connectionID))
                }
            }
        case .group(let group, let reason):
            resultRow(
                title: group.name,
                subtitle: reason ?? "\(group.memberCount) members",
                avatar: AnyView(GroupAvatarView(avatarURL: group.avatarURL, seed: group.chatID, initials: group.initials,
                                                members: group.avatarMembers(excluding: env.session.currentSession?.userId), size: 40))
            ) { open(.groupChat(group.chatRoute)) }
        case .beacon(let beacon):
            resultRow(
                title: beacon.title,
                subtitle: [beacon.kind.label, beacon.schedule.map { EventFormatting.when($0) }, beacon.locationName].compactMap { $0 }.joined(separator: " · "),
                avatar: AnyView(EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage).frame(width: 40, height: 40))
            ) { open(beacon.isEvent ? .event(beaconID: beacon.id) : .beacon(beaconID: beacon.id)) }
        case .hub(let hub):
            resultRow(
                title: hub.name,
                subtitle: "Hub · \(hub.category)",
                avatar: AnyView(EventVisual(seed: hub.id, symbol: "dot.radiowaves.left.and.right").frame(width: 40, height: 40))
            ) { open(.hub(hubID: hub.id)) }
        case .ownIntent(let intent):
            resultRow(
                title: intent.tag,
                subtitle: "Your availability · \(intent.timeframe)",
                avatar: AnyView(Image(systemName: "hand.wave").frame(width: 40, height: 40))
            ) {
                dismiss()
                env.router.selectTab(.home)
            }
        case .message(let hit):
            resultRow(
                title: hit.chatName,
                subtitle: hit.snippet,
                avatar: AnyView(Image(systemName: hit.isHub ? "dot.radiowaves.left.and.right" : "text.bubble").frame(width: 40, height: 40))
            ) { openMessage(hit) }
        }
    }

    private func resultRow(title: String, subtitle: String?, avatar: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatar
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(ClickColors.accentForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Routing

    private func open(_ route: AppRoute) {
        dismiss()
        env.router.navigate(to: route)
    }

    private func openMessage(_ hit: MessageHit) {
        if hit.isHub, let hubID = hit.hubID {
            open(.hub(hubID: hubID))
        } else if let group = conversations.groups.first(where: { $0.chatID == hit.chatID }) {
            open(.groupChat(group.chatRoute))
        } else if let item = (conversations.active + conversations.archived).first(where: {
            $0.chatID == hit.chatID || $0.connectionID == hit.connectionID
        }) {
            open(.chat(DirectChatRoute(chatID: hit.chatID, connectionID: item.connectionID, peerUserID: item.userID,
                                       peerDisplayName: item.displayName, peerAvatarURL: item.avatarUrl)))
        }
    }

    // MARK: - Loading

    private func loadLocalSources() async {
        guard let userID = env.session.currentSession?.userId else { return }
        if let discovery = await env.beacons.cachedDiscovery(userID: userID) {
            beacons = discovery.beacons.filter { $0.isActive() }
            hubs = discovery.hubs
        }
        intents = await env.me.cachedIntents(userID: userID) ?? []
    }

    /// Debounced, cancelled by the next keystroke (`task(id:)`).
    private func searchMessages() async {
        guard clean.count >= 2 else {
            remote = ModuleState()
            return
        }
        remote.begin()
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let (data, _) = try await env.api.executeRaw(APIRequest(
                path: "/api/chat/search",
                method: .get,
                queryItems: [URLQueryItem(name: "q", value: clean)]
            ))
            let root = try JSONFields.object(data)
            guard root["hits"] != nil else { throw APIError.decoding }
            guard !Task.isCancelled else { return }
            remote.succeed(JSONFields.rows(root["hits"]).compactMap(MessageHit.decode))
        } catch {
            guard !Task.isCancelled else { return }
            remote.fail(error)
        }
    }
}
