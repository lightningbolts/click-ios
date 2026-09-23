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

    public init(api: ClickAPIClient, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
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
            )
        )
        store(snapshot, key: "phase3.home.\(userID)")
        return snapshot
    }

    public func refreshClicks(for userID: String) async throws -> ClicksSnapshot {
        let request = APIRequest(
            path: "/api/connections",
            method: .get,
            queryItems: [URLQueryItem(name: "limit", value: "50")],
            requiresAuth: true
        )
        let (data, _) = try await api.executeRaw(request)
        let root = try jsonObject(data)
        let rows = root["connections"] as? [[String: Any]] ?? []

        var items: [ConnectionItem] = []
        items.reserveCapacity(rows.count)

        for row in rows {
            guard
                let connectionID = string(row["id"]),
                let userIDs = row["user_ids"] as? [String],
                let peerID = userIDs.first(where: { $0 != userID })
            else { continue }

            let profile = try? await fetchProfile(userID: peerID, connectionID: connectionID)
            let encounters = row["connection_encounters"] as? [[String: Any]] ?? []
            let latestEncounter = encounters.first
            let location = string(latestEncounter?["location_name"])
                ?? string(row["location_name"])
                ?? ""
            let activityDate = timestamp(row["last_message_at"])
                ?? timestamp(latestEncounter?["encountered_at"])
                ?? timestamp(row["created"])
            let lastActive = activityDate.map(Self.relativeDescription) ?? ""
            let tags = profile?.tags ?? []

            items.append(
                ConnectionItem(
                    id: connectionID,
                    userID: peerID,
                    connectionID: connectionID,
                    displayName: profile?.displayName ?? "Click user",
                    handle: profile?.handle ?? "",
                    avatarUrl: profile?.avatarURL,
                    initials: profile?.initials ?? Self.initials(from: profile?.displayName ?? ""),
                    isOnline: false,
                    presenceKnown: false,
                    lastActiveRelative: lastActive,
                    encounterLocation: location,
                    mutualTags: tags,
                    encounterCount: encounters.count,
                    segment: .all
                )
            )
        }

        let snapshot = ClicksSnapshot(connections: items)
        store(snapshot, key: "phase3.clicks.\(userID)")
        return snapshot
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
            totalCircles: clicks.connections.filter { $0.segment == .circles }.count,
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
    }

    private func fetchProfile(userID: String, connectionID: String?) async throws -> ProfilePayload {
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
        let root = try jsonObject(data)
        let user = root["user"] as? [String: Any] ?? [:]

        let first = string(user["first_name"]) ?? ""
        let last = string(user["last_name"]) ?? ""
        let directName = string(user["full_name"]) ?? string(user["name"])
        let displayName = directName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ").nonEmpty
            ?? "Click user"
        let email = string(user["email"]) ?? ""
        let handle = email.split(separator: "@").first.map { "@\($0)" } ?? ""
        let tags = stringArray(root["tags"])
        let personality = stringArray(root["personality_tags"])
        let rawIntents = root["availabilityIntents"] as? [[String: Any]] ?? []
        let intents = rawIntents.compactMap { row -> ProfilePayload.Intent? in
            guard let id = string(row["id"]) else { return nil }
            let label = string(row["intent_tag"]) ?? string(row["timeframe"]) ?? "Available"
            return .init(id: id, label: label, emoji: Self.emoji(for: label))
        }

        return ProfilePayload(
            firstName: first,
            displayName: displayName,
            handle: handle,
            avatarURL: string(user["image"]),
            initials: Self.initials(from: displayName),
            tags: tags,
            personalityTags: personality,
            availabilityIntents: intents
        )
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
        let root = try jsonObject(data)
        let rows = root["journal_entries"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = string(row["id"]), let body = string(row["body"]) else { return nil }
            return ProfileTimelineEntry(
                id: id,
                body: body,
                authorName: string(row["author_name"]),
                createdAt: timestamp(row["created_at"]),
                visibility: string(row["visibility"]) ?? "private"
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
        let root = try jsonObject(data)
        let recap = root["recap"] as? [String: Any] ?? [:]
        let connections = int(recap["connections_formed"]) ?? 0
        let messages = (int(recap["messages_sent"]) ?? 0) + (int(recap["messages_received"]) ?? 0)
        if connections == 0 && messages == 0 {
            return RecapPayload(subtitle: "Ready to connect today?")
        }
        var parts: [String] = []
        if connections > 0 { parts.append("\(connections) new Click\(connections == 1 ? "" : "s") this week") }
        if messages > 0 { parts.append("\(messages) messages this week") }
        return RecapPayload(subtitle: parts.joined(separator: " · "))
    }

    private func cached<T: Codable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func store<T: Codable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding
        }
        return object
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { string($0) }
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func timestamp(_ value: Any?) -> Date? {
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

    private static func initials(from displayName: String) -> String {
        let parts = displayName.split(separator: " ")
        let result = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return result.isEmpty ? "?" : result.uppercased()
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

    private static func relativeDescription(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
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
