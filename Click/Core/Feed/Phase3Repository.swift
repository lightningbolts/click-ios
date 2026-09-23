import Foundation

public struct ProfileTimelineEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let body: String
    public let authorName: String?
    public let createdAt: Date?
    public let visibility: String

    public init(id: String, body: String, authorName: String?, createdAt: Date?, visibility: String) {
        self.id = id
        self.body = body
        self.authorName = authorName
        self.createdAt = createdAt
        self.visibility = visibility
    }
}

public struct Phase3ProfileData: Codable, Equatable, Sendable {
    public let profile: UserProfileSnapshot
    public let timeline: [ProfileTimelineEntry]

    public init(profile: UserProfileSnapshot, timeline: [ProfileTimelineEntry]) {
        self.profile = profile
        self.timeline = timeline
    }
}

public actor Phase3Repository {
    private let api: ClickAPIClient
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var profileMemoryCache: [String: ProfilePayload] = [:]

    private let supabaseURL: URL?
    private let supabaseAnonKey: String

    public init(
        api: ClickAPIClient,
        defaults: UserDefaults = .standard,
        supabaseURL: URL? = nil,
        supabaseAnonKey: String = ""
    ) {
        self.api = api
        self.defaults = defaults
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    public func cachedHome(for userID: String) -> HomeFeedSnapshot? {
        cached(HomeFeedSnapshot.self, key: "phase3.home.\(userID)")
    }

    public func cachedClicks(for userID: String) -> ClicksSnapshot? {
        cached(ClicksSnapshot.self, key: "phase3.clicks.\(userID)")
    }

    public func cachedProfile(for userID: String) -> Phase3ProfileData? {
        cached(Phase3ProfileData.self, key: "phase3.profile.\(userID)")
    }

    public func refreshHome(for userID: String) async throws -> HomeFeedSnapshot {
        async let profileTask = fetchProfile(userID: userID, connectionID: nil)
        async let clicksTask = refreshClicks(for: userID)
        async let recapTask = fetchRecap()

        let (profilePayload, clicks, recap) = try await (profileTask, clicksTask, recapTask)
        let recent = clicks.connections.prefix(4).map {
            RecentConnectionSummary(
                id: $0.id,
                userID: $0.userID,
                connectionID: $0.connectionID,
                displayName: $0.displayName,
                handle: $0.handle,
                avatarUrl: $0.avatarUrl,
                initials: $0.initials,
                encounterLocation: $0.encounterLocation,
                lastActiveRelative: $0.lastActiveRelative,
                isOnline: $0.isOnline,
                presenceKnown: $0.presenceKnown
            )
        }

        let intents = profilePayload.availabilityIntents.map {
            AvailabilityIntent(id: $0.id, emoji: $0.emoji, label: $0.label, isSelected: true)
        }

        let encounterCount = clicks.connections.reduce(0) { $0 + $1.encounterCount }
        let snapshot = HomeFeedSnapshot(
            greetingName: profilePayload.firstName,
            greetingSubtitle: recap.subtitle,
            intents: intents,
            featuredEvent: nil,
            nearbyBeacons: [],
            recentConnections: Array(recent),
            stats: HomeStats(
                totalClicks: clicks.connections.count,
                totalEncounters: encounterCount,
                totalCircles: clicks.connections.filter { $0.segment == .circles }.count
            ),
            recap: recap.activity
        )
        store(snapshot, key: "phase3.home.\(userID)")
        return snapshot
    }

    /// Builds the Clicks inbox in three requests regardless of inbox size: the connections
    /// dashboard bundle, then — concurrently — batched display names/avatars and the
    /// `get_inbox_previews` RPC (latest message + unread count per direct chat).
    /// Names and previews are enrichments: if either fails the inbox still renders.
    public func refreshClicks(for userID: String) async throws -> ClicksSnapshot {
        let request = APIRequest(
            path: "/api/connections",
            method: .get,
            queryItems: [URLQueryItem(name: "bundle", value: "dashboard")],
            requiresAuth: true
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try Self.jsonObject(data)
        let activeRows =
            root["active"] as? [[String: Any]]
            ?? root["connections"] as? [[String: Any]]
            ?? []
        let archivedRows = root["archived"] as? [[String: Any]] ?? []
        let coreIDs = Set(Self.stringArray(root["core"]))

        let peerIDs = Array(Set((activeRows + archivedRows).compactMap {
            Self.peerID(in: $0, currentUserID: userID)
        }))

        async let identitiesTask = fetchIdentities(userIDs: peerIDs)
        async let previewsTask = fetchInboxPreviews(currentUserID: userID)
        let identities = await identitiesTask
        let previews = await previewsTask

        func items(_ rows: [[String: Any]], archived: Bool) -> [ConnectionItem] {
            Self.inboxItems(
                rows: rows,
                currentUserID: userID,
                identities: identities,
                previews: previews,
                coreIDs: coreIDs,
                archived: archived,
                now: Date()
            )
        }

        let snapshot = ClicksSnapshot(
            connections: items(activeRows, archived: false),
            archivedConnections: items(archivedRows, archived: true),
            groups: []
        )
        store(snapshot, key: "phase3.clicks.\(userID)")
        return snapshot
    }

    // MARK: - Connection actions (server-authoritative BFF routes)

    /// Archives or restores a connection for the signed-in user.
    public func setArchived(connectionID: String, archived: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["connection_id": connectionID])
        let path = archived ? "/api/connections/archive" : "/api/connections/unarchive"
        _ = try await api.executeRaw(APIRequest(path: path, method: .post, body: body, requiresAuth: true))
    }

    /// Adds or removes a connection from the signed-in user's Core.
    public func setCore(connectionID: String, isCore: Bool) async throws {
        let request: APIRequest
        if isCore {
            let body = try JSONSerialization.data(withJSONObject: ["connection_id": connectionID])
            request = APIRequest(path: "/api/connections/core", method: .post, body: body, requiresAuth: true)
        } else {
            request = APIRequest(
                path: "/api/connections/core",
                method: .delete,
                queryItems: [URLQueryItem(name: "connection_id", value: connectionID)],
                requiresAuth: true
            )
        }
        _ = try await api.executeRaw(request)
    }

    /// Batched display names and avatar URLs (`POST /api/users/display-names`, ≤100 per call).
    private func fetchIdentities(userIDs: [String]) async -> [String: InboxIdentity] {
        var result: [String: InboxIdentity] = [:]
        for chunk in stride(from: 0, to: userIDs.count, by: 100).map({ Array(userIDs[$0..<min($0 + 100, userIDs.count)]) }) {
            do {
                let body = try JSONSerialization.data(withJSONObject: ["userIds": chunk])
                let request = APIRequest(path: "/api/users/display-names", method: .post, body: body, requiresAuth: true)
                let (data, _) = try await api.executeRaw(request)
                let root = try Self.jsonObject(data)
                let names = root["names"] as? [String: Any] ?? [:]
                let images = root["images"] as? [String: Any] ?? [:]
                for id in chunk {
                    result[id] = InboxIdentity(name: Self.string(names[id]), avatarURL: Self.string(images[id]))
                }
            } catch {
                // Rows fall back to "Click user" with generated avatars; the next refresh retries.
                continue
            }
        }
        return result
    }

    /// Latest message and unread count per direct chat via the approved, RLS-scoped
    /// `get_inbox_previews` RPC shared with the Android and web clients.
    private func fetchInboxPreviews(currentUserID: String) async -> [String: InboxPreviewRow] {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { return [:] }
        let request = APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/rpc/get_inbox_previews",
            method: .post,
            headers: ["apikey": supabaseAnonKey],
            body: Data("{}".utf8),
            requiresAuth: true
        )
        guard
            let (data, _) = try? await api.executeRaw(request),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            // Without previews the inbox still lists every connection; unread badges resume
            // on the next successful refresh.
            return [:]
        }
        return Self.inboxPreviews(from: rows, currentUserID: currentUserID)
    }

    struct InboxIdentity: Sendable {
        let name: String?
        let avatarURL: String?
    }

    struct InboxPreviewRow: Sendable, Equatable {
        let chatID: String
        let lastMessage: InboxLastMessage?
        let lastMessageAt: Date?
        let unreadCount: Int
    }

    /// Keys RPC rows by connection ID.
    nonisolated static func inboxPreviews(from rows: [[String: Any]], currentUserID: String) -> [String: InboxPreviewRow] {
        var result: [String: InboxPreviewRow] = [:]
        for row in rows {
            guard let chatID = string(row["chat_id"]), let connectionID = string(row["connection_id"]) else { continue }
            let metadata = row["last_message_metadata"] as? [String: Any]
            let lastMessage = (row["last_message_content"] as? String).map { content in
                InboxLastMessage(
                    content: content,
                    messageType: string(row["last_message_type"]) ?? "text",
                    isOutgoing: string(row["last_message_user_id"]) == currentUserID,
                    isRead: bool(row["last_message_is_read"]) ?? false,
                    isDisposable: bool(metadata?["disposable_roll"]) ?? false
                )
            }
            result[connectionID] = InboxPreviewRow(
                chatID: chatID,
                lastMessage: lastMessage,
                lastMessageAt: timestamp(row["last_message_time_created"]),
                unreadCount: int(row["unread_count"]) ?? 0
            )
        }
        return result
    }

    /// Pending connections must be greeted within 48 hours before the server's gentle archive.
    nonisolated static let sayHiWindow: TimeInterval = 48 * 60 * 60

    /// Maps dashboard rows plus enrichments into inbox items, newest activity first.
    nonisolated static func inboxItems(
        rows: [[String: Any]],
        currentUserID: String,
        identities: [String: InboxIdentity],
        previews: [String: InboxPreviewRow],
        coreIDs: Set<String>,
        archived: Bool,
        now: Date
    ) -> [ConnectionItem] {
        let items = rows.compactMap { row -> ConnectionItem? in
            guard
                let connectionID = string(row["id"]),
                let peerID = peerID(in: row, currentUserID: currentUserID)
            else { return nil }

            let identity = identities[peerID]
            let displayName = identity?.name ?? "Click user"
            let preview = previews[connectionID]
            let encounters = row["connection_encounters"] as? [[String: Any]] ?? []
            let latestEncounter = encounters.max {
                (timestamp($0["encountered_at"]) ?? .distantPast) < (timestamp($1["encountered_at"]) ?? .distantPast)
            }
            let location = string(latestEncounter?["location_name"])
                ?? string(latestEncounter?["display_location"])
                ?? string(row["semantic_location"])
                ?? ""
            let created = timestamp(row["created"])
            let activity = [
                preview?.lastMessageAt,
                timestamp(row["last_message_at"]),
                timestamp(latestEncounter?["encountered_at"]),
                created
            ].compactMap { $0 }.max()

            let hasBegun = bool(row["has_begun"]) ?? false
            let status = string(row["status"]) ?? "pending"
            let deadline = created.map { $0.addingTimeInterval(sayHiWindow) }
            let sayHiDeadline = (!archived && !hasBegun && status == "pending" && (deadline ?? .distantPast) > now)
                ? deadline : nil

            return ConnectionItem(
                id: connectionID,
                userID: peerID,
                connectionID: connectionID,
                displayName: displayName,
                handle: "",
                avatarUrl: identity?.avatarURL,
                initials: initials(from: displayName),
                isOnline: false,
                presenceKnown: false,
                lastActiveRelative: activity.map { relativeDescription($0, now: now) } ?? "",
                encounterLocation: location,
                encounterCount: encounters.count,
                chatID: preview?.chatID,
                lastMessage: preview?.lastMessage,
                lastActivityAt: activity,
                sayHiDeadline: sayHiDeadline,
                unreadCount: preview?.unreadCount ?? 0,
                isCore: coreIDs.contains(connectionID)
            )
        }
        return items.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    private nonisolated static func peerID(in row: [String: Any], currentUserID: String) -> String? {
        (row["user_ids"] as? [String])?.first { $0 != currentUserID }
    }

    public func refreshProfile(userID: String, connectionID: String? = nil) async throws -> Phase3ProfileData {
        async let profileTask = fetchProfile(userID: userID, connectionID: connectionID)
        async let timelineTask = fetchTimeline(userID: userID)
        let (payload, timeline) = try await (profileTask, timelineTask)

        let profile = UserProfileSnapshot(
            userId: userID,
            displayName: payload.displayName,
            handle: payload.handle,
            avatarUrl: payload.avatarURL,
            initials: payload.initials,
            bio: "",
            interests: payload.tags,
            personalityTraits: payload.personalityTags,
            totalClicks: 0,
            totalEncounters: 0,
            totalCircles: 0,
            memberSince: ""
        )

        let data = Phase3ProfileData(profile: profile, timeline: timeline)
        store(data, key: "phase3.profile.\(userID)")
        return data
    }

    public func refreshSelfProfile(userID: String) async throws -> Phase3ProfileData {
        async let baseTask = refreshProfile(userID: userID)
        async let clicksTask = refreshClicks(for: userID)
        let (base, clicks) = try await (baseTask, clicksTask)

        let profile = UserProfileSnapshot(
            userId: base.profile.userId,
            displayName: base.profile.displayName,
            handle: base.profile.handle,
            avatarUrl: base.profile.avatarUrl,
            initials: base.profile.initials,
            bio: base.profile.bio,
            interests: base.profile.interests,
            personalityTraits: base.profile.personalityTraits,
            totalClicks: clicks.connections.count,
            totalEncounters: clicks.connections.reduce(0) { $0 + $1.encounterCount },
            totalCircles: clicks.cliques.count,
            memberSince: base.profile.memberSince
        )

        let data = Phase3ProfileData(profile: profile, timeline: base.timeline)
        store(data, key: "phase3.profile.\(userID)")
        return data
    }

    public func searchConnections(userID: String, query: String) async throws -> [ConnectionItem] {
        let snapshot: ClicksSnapshot
        if let cached = cachedClicks(for: userID) {
            snapshot = cached
        } else {
            snapshot = try await refreshClicks(for: userID)
        }
        return snapshot.filtered(by: .all, query: query)
    }

    private struct ProfilePayload: Sendable {
        struct Intent: Sendable {
            let id: String
            let label: String
            let emoji: String
        }

        let firstName: String
        let displayName: String
        let handle: String
        let avatarURL: String?
        let initials: String
        let tags: [String]
        let personalityTags: [String]
        let availabilityIntents: [Intent]
    }

    private struct RecapPayload: Sendable {
        let subtitle: String
        let activity: HomeActivityRecap
    }

    private func fetchProfile(userID: String, connectionID: String?) async throws -> ProfilePayload {
        let cacheKey = "\(userID)|\(connectionID ?? "")"
        if let cached = profileMemoryCache[cacheKey] {
            return cached
        }

        var query: [URLQueryItem] = []
        if let connectionID, !connectionID.isEmpty {
            query.append(URLQueryItem(name: "connectionId", value: connectionID))
        }
        let request = APIRequest(
            path: "/api/users/\(userID)/profile",
            method: .get,
            queryItems: query,
            requiresAuth: true
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try Self.jsonObject(data)
        let user = root["user"] as? [String: Any] ?? [:]

        let first = Self.string(user["first_name"]) ?? ""
        let last = Self.string(user["last_name"]) ?? ""
        let directName = Self.string(user["full_name"]) ?? Self.string(user["name"])
        let displayName = directName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ").nonEmpty
            ?? "Click user"
        let email = Self.string(user["email"]) ?? ""
        let handle = email.split(separator: "@").first.map { "@\($0)" } ?? ""
        let tags = Self.stringArray(root["tags"])
        let personality = Self.stringArray(root["personality_tags"])
        let rawIntents = root["availabilityIntents"] as? [[String: Any]] ?? []
        let intents = rawIntents.compactMap { row -> ProfilePayload.Intent? in
            guard let id = Self.string(row["id"]) else { return nil }
            let label = Self.string(row["intent_tag"]) ?? Self.string(row["timeframe"]) ?? "Available"
            return .init(id: id, label: label, emoji: Self.emoji(for: label))
        }

        let payload = ProfilePayload(
            firstName: first,
            displayName: displayName,
            handle: handle,
            avatarURL: Self.string(user["image"]),
            initials: Self.initials(from: displayName),
            tags: tags,
            personalityTags: personality,
            availabilityIntents: intents
        )
        profileMemoryCache[cacheKey] = payload
        return payload
    }

    private func fetchTimeline(userID: String) async throws -> [ProfileTimelineEntry] {
        let request = APIRequest(
            path: "/api/profile/timeline",
            method: .get,
            queryItems: [
                URLQueryItem(name: "target_type", value: "user"),
                URLQueryItem(name: "target_id", value: userID)
            ],
            requiresAuth: true
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try Self.jsonObject(data)
        let rows = root["journal_entries"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = Self.string(row["id"]), let body = Self.string(row["body"]) else { return nil }
            return ProfileTimelineEntry(
                id: id,
                body: body,
                authorName: Self.string(row["author_name"]),
                createdAt: Self.timestamp(row["created_at"]),
                visibility: Self.string(row["visibility"]) ?? "private"
            )
        }
    }

    private func fetchRecap() async throws -> RecapPayload {
        let request = APIRequest(
            path: "/api/me/recap",
            method: .get,
            queryItems: [URLQueryItem(name: "window", value: "week")],
            requiresAuth: true
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try Self.jsonObject(data)
        let recap = root["recap"] as? [String: Any] ?? [:]
        let connections = Self.int(recap["connections_formed"]) ?? 0
        let messages = (Self.int(recap["messages_sent"]) ?? 0) + (Self.int(recap["messages_received"]) ?? 0)
        let activity = HomeActivityRecap(
            connectionsFormed: connections,
            messagesSent: Self.int(recap["messages_sent"]) ?? 0,
            messagesReceived: Self.int(recap["messages_received"]) ?? 0,
            beaconsCreated: Self.int(recap["beacons_created"]) ?? 0,
            eventsRSVPed: Self.int(recap["events_rsvped"]) ?? 0,
            eventsCheckedIn: Self.int(recap["events_checked_in"]) ?? 0,
            eventsSaved: Self.int(recap["events_saved"]) ?? 0
        )
        if connections == 0 && messages == 0 {
            return RecapPayload(subtitle: "Ready to connect today?", activity: activity)
        }
        var parts: [String] = []
        if connections > 0 { parts.append("\(connections) new Click\(connections == 1 ? "" : "s") this week") }
        if messages > 0 { parts.append("\(messages) messages this week") }
        return RecapPayload(subtitle: parts.joined(separator: " · "), activity: activity)
    }

    private func cached<T: Codable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func store<T: Codable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private nonisolated static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding
        }
        return object
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { Self.string($0) }
    }

    private nonisolated static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private nonisolated static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if value == "true" || value == "1" { return true }
            if value == "false" || value == "0" { return false }
        }
        return nil
    }

    private nonisolated static func timestamp(_ value: Any?) -> Date? {
        if let value = value as? NSNumber {
            let raw = value.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let value = value as? String {
            if let raw = Double(value) {
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
            }
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }

    /// Matches the Android client's `initialsForAvatar`: first + last word initials, or the
    /// first two letters of a single word.
    nonisolated static func initials(from displayName: String) -> String {
        let parts = displayName.split(whereSeparator: \.isWhitespace)
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        }
        guard let only = parts.first else { return "?" }
        return String(only.prefix(2)).uppercased()
    }

    private static func emoji(for label: String) -> String {
        let value = label.lowercased()
        if value.contains("coffee") { return "☕️" }
        if value.contains("food") || value.contains("dinner") || value.contains("lunch") { return "🍽️" }
        if value.contains("work") { return "💻" }
        if value.contains("climb") { return "🧗" }
        if value.contains("music") || value.contains("show") { return "🎵" }
        return "✨"
    }

    private nonisolated static func relativeDescription(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "Yesterday" : "\(days)d ago"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
