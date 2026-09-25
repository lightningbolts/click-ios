import SwiftUI

/// Result filters.
enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case people = "People"
    case messages = "Messages"
    case groups = "Groups"
    case events = "Events"
    case hubs = "Hubs"

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
    /// A message from the on-device store (includes end-to-end encrypted chats).
    case storedMessage(StoredMessageHit)
    /// Someone the viewer shares a group or hub with but hasn't Clicked with (server).
    case sharedContextPerson(RemotePerson)
    case remoteEvent(RemoteEvent)
    case joinedHub(JoinedHub)

    var id: String {
        switch self {
        case .person(let item, _, _): "person.\(item.id)"
        case .group(let group, _): "group.\(group.id)"
        case .beacon(let beacon): "beacon.\(beacon.id)"
        case .hub(let hub): "hub.\(hub.id)"
        case .ownIntent(let intent): "intent.\(intent.id)"
        case .message(let hit): "message.\(hit.messageID)"
        case .storedMessage(let hit): "message.\(hit.messageID)"
        case .sharedContextPerson(let person): "user.\(person.userID)"
        case .remoteEvent(let event): "beacon.\(event.beaconID)"
        case .joinedHub(let hub): "hub.\(hub.hubID)"
        }
    }

    var scope: SearchScope {
        switch self {
        case .person, .sharedContextPerson: .people
        case .group: .groups
        case .beacon, .remoteEvent, .ownIntent: .events
        case .hub, .joinedHub: .hubs
        case .message, .storedMessage: .messages
        }
    }
}

/// A match from the on-device message index, resolved to its conversation.
struct StoredMessageHit: Equatable, Sendable {
    let messageID: String
    let conversationTitle: String
    let snippet: String
    let date: Date
    let route: AppRoute
    /// Set for hubs: the message focus is handed to the hub's chat when it opens.
    var focusConversationID: String? = nil
}

struct RemotePerson: Equatable, Sendable {
    let userID: String
    let name: String
    let avatarURL: String?
    let context: String?
}

struct RemoteEvent: Equatable, Sendable {
    let beaconID: String
    let title: String
    let locationName: String?
    let start: Date?
    let imageURL: String?
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

/// Canonical cross-domain search (spec §21), the only search surface (presented by the shell).
///
/// Local-first: connections, groups, joined hubs, cached events and every stored message
/// (including end-to-end encrypted chats, decrypted on this device) match on each keystroke.
/// The server (`/api/search`) is the debounced fallback for what the device doesn't hold:
/// people you share a group or hub with, public events, and plaintext message hits. A server
/// failure is shown as an error, never as "No results".
struct GlobalSearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var scope: SearchScope = .all
    @State private var beacons: [MapBeacon] = []
    @State private var hubs: [NearbyHub] = []
    @State private var intents: [AvailabilityIntentPost] = []
    @State private var stored: [StoredMessageHit] = []
    @State private var remote = ModuleState<RemoteResults>()
    /// Focuses the field when search opens (keyboard up immediately).
    @State private var isFieldActive = false

    struct RemoteResults: Equatable, Sendable {
        var people: [RemotePerson] = []
        var events: [RemoteEvent] = []
        var hits: [MessageHit] = []
    }

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

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
        ) + conversations.hubs
            .filter { hub in clean.count >= 1 && ([hub.name, hub.category ?? ""].contains { $0.localizedCaseInsensitiveContains(clean) }) }
            .filter { hub in !hubs.contains { $0.id == hub.hubID } }
            .map(SearchResult.joinedHub)
    }

    private var results: [SearchResult] {
        var seen = Set<String>()
        var all: [SearchResult] = []
        func add(_ items: [SearchResult]) {
            for item in items where seen.insert(item.id).inserted { all.append(item) }
        }
        add(localResults)
        add(stored.map(SearchResult.storedMessage))
        if let remote = remote.value {
            add(remote.people.map(SearchResult.sharedContextPerson))
            add(remote.events.map(SearchResult.remoteEvent))
            add(remote.hits.map(SearchResult.message))
        }
        return scope == .all ? all : all.filter { $0.scope == scope }
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
            .overlay(alignment: .top) {
                // Outside the list, top-anchored and keyboard-independent: showing or hiding
                // the keyboard (or closing the field) never moves it.
                if clean.isEmpty {
                    ContentUnavailableView {
                        Label("Search Click", systemImage: "magnifyingglass")
                    } description: {
                        Text("Find people, messages, groups, events, hubs, and your plans.")
                    }
                    .fixedSize(horizontal: false, vertical: true)   // intrinsic height, pinned to the top
                    .padding(.top, 24)
                    .ignoresSafeArea(.keyboard)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $isFieldActive, placement: .navigationBarDrawer(displayMode: .always), prompt: "People, messages, places, events")
            .onAppear { isFieldActive = true }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await loadLocalSources() }
            .task(id: clean) {
                await searchStoredMessages()
                await searchServer()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if clean.isEmpty {
            EmptyView()   // the empty state is the list's overlay
        } else if scope == .all {
            ForEach(SearchScope.allCases.dropFirst()) { section in
                let rows = results.filter { $0.scope == section }
                if !rows.isEmpty {
                    Section(section.rawValue) {
                        ForEach(rows.prefix(section == .messages ? 30 : 12)) { row($0) }
                    }
                }
            }
            serverStatus
        } else {
            ForEach(results) { row($0) }
            serverStatus
        }
    }

    /// Server-search state, kept distinct from "no results".
    @ViewBuilder
    private var serverStatus: some View {
        if clean.count >= 2, remote.isPending {
            HStack(spacing: 8) {
                ClickLoadingView(size: 18, fillsSpace: false).frame(width: 28)
                Text("Searching Click…").foregroundStyle(ClickColors.textSecondary)
            }
            .font(ClickTypography.supporting)
            .listRowSeparator(.hidden)
        } else if clean.count >= 2, let error = remote.errorMessage {
            Button {
                Task { await searchServer() }
            } label: {
                Label(results.isEmpty ? "Couldn't search. \(error) Tap to retry." : "Showing results on this device. Tap to retry the rest.",
                      systemImage: "exclamationmark.triangle")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            .listRowSeparator(.hidden)
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
        case .sharedContextPerson(let person):
            resultRow(
                title: person.name,
                subtitle: person.context,
                avatar: AnyView(AvatarView(imageURL: person.avatarURL, seed: person.userID,
                                           initials: Phase3Repository.initials(from: person.name), size: 40))
            ) { open(.publicProfile(userID: person.userID)) }
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
        case .remoteEvent(let event):
            resultRow(
                title: event.title,
                subtitle: ["Event", event.start?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()), event.locationName]
                    .compactMap { $0 }.joined(separator: " · "),
                avatar: AnyView(EventVisual(seed: event.beaconID, imageURL: event.imageURL, symbol: "calendar").frame(width: 40, height: 40))
            ) { open(.event(beaconID: event.beaconID)) }
        case .hub(let hub):
            resultRow(
                title: hub.name,
                subtitle: "Hub · \(hub.category)",
                avatar: AnyView(EventVisual(seed: hub.id, symbol: "dot.radiowaves.left.and.right").frame(width: 40, height: 40))
            ) { open(.hub(hubID: hub.id)) }
        case .joinedHub(let hub):
            resultRow(
                title: hub.name,
                subtitle: ["Hub", hub.category].compactMap { $0 }.joined(separator: " · "),
                avatar: AnyView(EventVisual(seed: hub.hubID, symbol: "dot.radiowaves.left.and.right").frame(width: 40, height: 40))
            ) { open(.hub(hubID: hub.hubID)) }
        case .ownIntent(let intent):
            resultRow(
                title: intent.tag,
                subtitle: "Your availability · \(intent.timeframe)",
                avatar: AnyView(Image(systemName: "hand.wave").frame(width: 40, height: 40))
            ) {
                dismiss()
                env.router.selectTab(.home)
            }
        case .storedMessage(let hit):
            resultRow(
                title: hit.conversationTitle,
                subtitle: hit.snippet,
                avatar: AnyView(Image(systemName: "text.bubble").frame(width: 40, height: 40)),
                trailing: hit.date.formatted(.relative(presentation: .named))
            ) {
                if let conversationID = hit.focusConversationID {
                    env.pendingMessageFocus = MessageFocus(conversationIDs: [conversationID], messageID: hit.messageID)
                }
                open(hit.route)
            }
        case .message(let hit):
            resultRow(
                title: hit.chatName,
                subtitle: hit.snippet,
                avatar: AnyView(Image(systemName: hit.isHub ? "dot.radiowaves.left.and.right" : "text.bubble").frame(width: 40, height: 40)),
                trailing: hit.date?.formatted(.relative(presentation: .named))
            ) { openMessage(hit) }
        }
    }

    private func resultRow(title: String, subtitle: String?, avatar: AnyView, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatar
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(ClickColors.accentForeground)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(ClickTypography.bodyEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let trailing {
                            Text(trailing)
                                .font(ClickTypography.caption)
                                .foregroundStyle(ClickColors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Routing

    /// Closes search; the shell opens the route once the sheet is gone.
    private func open(_ route: AppRoute) {
        env.router.openFromSearch(route)
    }

    private func openMessage(_ hit: MessageHit) {
        if hit.isHub, let hubID = hit.hubID {
            env.pendingMessageFocus = MessageFocus(conversationIDs: [hubID], messageID: hit.messageID)
            open(.hub(hubID: hubID))
        } else {
            open(.conversation(chatID: hit.chatID, messageID: hit.messageID))
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

    /// Full-text search over every stored message; instant, on-device.
    private func searchStoredMessages() async {
        guard clean.count >= 2, let userID = env.session.currentSession?.userId else {
            stored = []
            return
        }
        let hits = await LocalStore.shared.searchMessages(clean, userID: userID, limit: 60)
        guard !Task.isCancelled else { return }
        stored = hits.compactMap(resolve)
    }

    /// Names the conversation a stored hit belongs to and how to open it.
    private func resolve(_ hit: LocalStore.MessageHit) -> StoredMessageHit? {
        let key = hit.conversation
        let snippet = hit.senderName.isEmpty || hit.senderName == "You" ? hit.snippet : "\(hit.senderName): \(hit.snippet)"
        if let group = conversations.groups.first(where: { $0.chatID == key }) {
            return StoredMessageHit(messageID: hit.messageID, conversationTitle: group.name, snippet: snippet, date: hit.createdAt,
                                    route: .conversation(chatID: key, messageID: hit.messageID))
        }
        if let item = (conversations.active + conversations.archived).first(where: { $0.chatID == key || $0.connectionID == key }) {
            return StoredMessageHit(messageID: hit.messageID, conversationTitle: item.displayName, snippet: snippet, date: hit.createdAt,
                                    route: .conversation(chatID: key, messageID: hit.messageID))
        }
        if let hub = conversations.hubs.first(where: { $0.hubID == key }) {
            // Hubs open through the hub screen (access check, hub menu), focused on the message.
            return StoredMessageHit(messageID: hit.messageID, conversationTitle: hub.name, snippet: snippet, date: hit.createdAt,
                                    route: .hub(hubID: key), focusConversationID: key)
        }
        return nil
    }

    /// Debounced, cancelled by the next keystroke (`task(id:)`). Falls back to the older
    /// message-only endpoint when the server doesn't have `/api/search` yet.
    private func searchServer() async {
        guard clean.count >= 2 else {
            remote = ModuleState()
            return
        }
        remote.begin()
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let request = APIRequest(path: "/api/search", method: .get, queryItems: [URLQueryItem(name: "q", value: clean)])
            let root: [String: Any]
            do {
                let (data, _) = try await env.api.executeRaw(request)
                root = try JSONFields.object(data)
            } catch APIError.notFound {
                let (data, _) = try await env.api.executeRaw(APIRequest(path: "/api/chat/search", method: .get,
                                                                        queryItems: [URLQueryItem(name: "q", value: clean)]))
                root = try JSONFields.object(data)
            }
            guard !Task.isCancelled else { return }
            remote.succeed(Self.decodeRemote(root))
        } catch {
            guard !Task.isCancelled else { return }
            remote.fail(error)
        }
    }

    static func decodeRemote(_ root: [String: Any]) -> RemoteResults {
        RemoteResults(
            people: JSONFields.rows(root["people"]).compactMap { row in
                guard let id = JSONFields.string(row["userId"]), let name = JSONFields.string(row["name"]) else { return nil }
                return RemotePerson(userID: id, name: name, avatarURL: JSONFields.string(row["avatarUrl"]), context: JSONFields.string(row["context"]))
            },
            events: JSONFields.rows(root["events"]).compactMap { row in
                guard let id = JSONFields.string(row["beaconId"]) else { return nil }
                return RemoteEvent(beaconID: id, title: JSONFields.string(row["title"]) ?? "Event",
                                   locationName: JSONFields.string(row["locationName"]),
                                   start: JSONFields.date(row["startAt"]), imageURL: JSONFields.string(row["imageUrl"]))
            },
            hits: JSONFields.rows(root["hits"]).compactMap(MessageHit.decode)
        )
    }
}
