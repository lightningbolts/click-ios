import Foundation

/// Day/week activity rollup from `GET /api/me/recap`.
public struct ActivityRecap: Codable, Equatable, Sendable {
    public enum Window: String, Codable, CaseIterable, Sendable {
        case day
        case week
    }

    public let window: Window
    public let connectionsFormed: Int
    public let messagesSent: Int
    public let messagesReceived: Int
    public let beaconsCreated: Int
    public let eventsRSVPed: Int
    public let eventsCheckedIn: Int
    public let eventsSaved: Int

    /// A successful response with no activity. Only a confirmed server response may be empty;
    /// a failed request never becomes a zero recap (spec §20.3).
    public var isEmpty: Bool {
        connectionsFormed + messagesSent + messagesReceived + beaconsCreated
            + eventsRSVPed + eventsCheckedIn + eventsSaved == 0
    }

    static func decode(_ root: [String: Any], window: Window) throws -> ActivityRecap {
        guard let row = JSONFields.dictionary(root["recap"]) else { throw APIError.decoding }
        func count(_ key: String) -> Int { max(0, JSONFields.int(row[key]) ?? 0) }
        return ActivityRecap(
            window: window,
            connectionsFormed: count("connections_formed"),
            messagesSent: count("messages_sent"),
            messagesReceived: count("messages_received"),
            beaconsCreated: count("beacons_created"),
            eventsRSVPed: count("events_rsvped"),
            eventsCheckedIn: count("events_checked_in"),
            eventsSaved: count("events_saved")
        )
    }
}

/// A server-generated relationship prompt from `GET /api/me/nudges`.
public struct InboxNudge: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case reconnectLull = "reconnect_lull"
        case sharedUpcomingEvent = "shared_upcoming_event"
    }

    public let id: String
    public let kind: Kind
    public let connectionID: String?
    public let beaconID: String?
    public let headline: String
    public let body: String
    public let peerFirstName: String?
    public let sentAt: Date?

    static func decode(_ row: [String: Any]) -> InboxNudge? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        let payload = JSONFields.dictionary(row["payload"]) ?? [:]
        return InboxNudge(
            id: id,
            kind: JSONFields.string(row["nudge_type"]) == Kind.sharedUpcomingEvent.rawValue
                ? .sharedUpcomingEvent : .reconnectLull,
            connectionID: JSONFields.string(row["connection_id"]),
            beaconID: JSONFields.string(row["beacon_id"]),
            headline: JSONFields.string(row["headline"]) ?? "Reconnect",
            body: JSONFields.string(row["body"]) ?? "",
            peerFirstName: JSONFields.string(payload["peer_first_name"]),
            sentAt: JSONFields.date(row["sent_at"])
        )
    }
}

/// An active "I'm down for…" availability intent (`/api/user/availability-intents`).
public struct AvailabilityIntentPost: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let tag: String
    public let timeframe: String
    public let expiresAt: Date?

    static func decode(_ row: [String: Any]) -> AvailabilityIntentPost? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        return AvailabilityIntentPost(
            id: id,
            tag: JSONFields.string(row["intent_tag"]) ?? "Available",
            timeframe: JSONFields.string(row["timeframe"]) ?? "",
            expiresAt: JSONFields.date(row["expires_at"])
        )
    }
}

/// Server duration presets for availability intents. Mirrors click-web
/// `AVAILABILITY_INTENT_DURATION_PRESETS` (and the KMP `AvailabilityIntentDuration`).
public enum AvailabilityDuration: Int, CaseIterable, Identifiable, Sendable {
    case minutes15 = 15
    case minutes30 = 30
    case minutes45 = 45
    case hour1 = 60
    case minutes90 = 90
    case hours2 = 120
    case hours3 = 180
    case hours6 = 360
    case hours24 = 1440

    public var id: Int { rawValue }
    public var milliseconds: Int { rawValue * 60_000 }

    public var label: String {
        switch self {
        case .minutes15: "15 min"
        case .minutes30: "30 min"
        case .minutes45: "45 min"
        case .hour1: "1 hour"
        case .minutes90: "90 min"
        case .hours2: "2 hours"
        case .hours3: "3 hours"
        case .hours6: "6 hours"
        case .hours24: "24 hours"
        }
    }

    /// The server default when no duration is chosen.
    public static let serverDefault: AvailabilityDuration = .hours3
}

/// Signed-in user reads/writes that are not tied to one connection: recap, nudges,
/// availability intents.
public actor MeRepository {
    private let api: ClickAPIClient
    private let cache: CacheStore
    private let supabaseURL: URL?
    private let supabaseAnonKey: String

    /// The server rejects intent tags longer than this.
    public static let intentTagMaxLength = 25

    /// - Parameters: supabaseURL/anonKey enable the RLS-scoped PostgREST reads/writes the
    ///   shipping KMP client already uses for notification and location-privacy preferences.
    public init(api: ClickAPIClient, cache: CacheStore = .shared, supabaseURL: URL? = nil, supabaseAnonKey: String = "") {
        self.api = api
        self.cache = cache
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    // MARK: - Recap

    public func cachedRecap(window: ActivityRecap.Window, userID: String) async -> ActivityRecap? {
        await cache.load(ActivityRecap.self, key: "recap.\(window.rawValue)", userID: userID)
    }

    public func recap(window: ActivityRecap.Window, userID: String) async throws -> ActivityRecap {
        let request = APIRequest(
            path: "/api/me/recap",
            method: .get,
            queryItems: [URLQueryItem(name: "window", value: window.rawValue)]
        )
        let (data, _) = try await api.executeRaw(request)
        let recap = try ActivityRecap.decode(try JSONFields.object(data), window: window)
        await cache.save(recap, key: "recap.\(window.rawValue)", userID: userID)
        return recap
    }

    // MARK: - Nudges

    public func cachedNudges(userID: String) async -> [InboxNudge]? {
        await cache.load([InboxNudge].self, key: "nudges", userID: userID)
    }

    public func nudges(userID: String) async throws -> [InboxNudge] {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/me/nudges", method: .get))
        let root = try JSONFields.object(data)
        guard root["nudges"] != nil else { throw APIError.decoding }
        let nudges = JSONFields.rows(root["nudges"]).compactMap(InboxNudge.decode)
        await cache.save(nudges, key: "nudges", userID: userID)
        return nudges
    }

    public enum NudgeAction: String, Sendable {
        case dismiss
        case acted
    }

    /// Records a nudge outcome server-side and drops it from the cache so a stale cached copy
    /// cannot resurrect it on the next launch (spec §29.6).
    public func resolveNudge(_ nudgeID: String, action: NudgeAction, userID: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/me/nudges/\(nudgeID)/\(action.rawValue)", method: .post))
        if let cached = await cache.load([InboxNudge].self, key: "nudges", userID: userID) {
            await cache.save(cached.filter { $0.id != nudgeID }, key: "nudges", userID: userID)
        }
    }

    // MARK: - Availability intents

    public func cachedIntents(userID: String) async -> [AvailabilityIntentPost]? {
        await cache.load([AvailabilityIntentPost].self, key: "intents", userID: userID)
    }

    public func availabilityIntents(userID: String) async throws -> [AvailabilityIntentPost] {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/user/availability-intents", method: .get))
        let root = try JSONFields.object(data)
        guard root["intents"] != nil else { throw APIError.decoding }
        let intents = JSONFields.rows(root["intents"]).compactMap(AvailabilityIntentPost.decode)
        await cache.save(intents, key: "intents", userID: userID)
        return intents
    }

    public func createIntent(tag: String, duration: AvailabilityDuration) async throws -> AvailabilityIntentPost {
        let body = try JSONSerialization.data(withJSONObject: [
            "intent_tag": tag,
            "durationMs": duration.milliseconds,
            "timeframe": duration.label
        ])
        let (data, _) = try await api.executeRaw(
            APIRequest(path: "/api/user/availability-intents", method: .post, body: body)
        )
        guard
            let row = JSONFields.dictionary(try JSONFields.object(data)["intent"]),
            let intent = AvailabilityIntentPost.decode(row)
        else { throw APIError.decoding }
        return intent
    }

    public func deleteIntent(id: String) async throws {
        _ = try await api.executeRaw(APIRequest(
            path: "/api/user/availability-intents",
            method: .delete,
            queryItems: [URLQueryItem(name: "id", value: id)]
        ))
    }

    // MARK: - Self profile

    public func cachedSelfProfile(userID: String) async -> SelfProfile? {
        await cache.load(SelfProfile.self, key: "self-profile", userID: userID)
    }

    /// `GET /api/users/{id}/profile` for the signed-in user: identity, interests, personality,
    /// and "Free currently" (`availability.is_free_this_week`).
    public func selfProfile(userID: String) async throws -> SelfProfile {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/users/\(userID)/profile", method: .get))
        let root = try JSONFields.object(data)
        guard let user = JSONFields.dictionary(root["user"]) else { throw APIError.decoding }
        let profile = SelfProfile.decode(user: user, root: root, userID: userID)
        await cache.save(profile, key: "self-profile", userID: userID)
        return profile
    }

    /// Updates the display name (`PATCH /api/users/{id}/profile`).
    /// `PATCH /api/user/ghost-mode {enabled:false}` — clears a flag set by older clients.
    public func clearLegacyGhostMode() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": false])
        _ = try await api.executeRaw(APIRequest(path: "/api/user/ghost-mode", method: .patch, body: body))
    }

    public func updateName(userID: String, firstName: String, lastName: String) async throws {
        try await updateProfile(userID: userID, fields: ["first_name": firstName, "last_name": lastName])
    }

    public static let bioMaxLength = 160

    /// Name and bio in one `PATCH /api/users/{id}/profile` (an empty bio clears it).
    public func updateProfile(userID: String, fields: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await api.executeRaw(APIRequest(path: "/api/users/\(userID)/profile", method: .patch, body: body))
    }

    /// `DELETE /api/user/avatar`: clears the photo and removes the stored image.
    public func removeAvatar(userID: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/user/avatar", method: .delete))
        await cache.remove(key: "self-profile", userID: userID)
    }

    /// Persists "Free currently" (`PATCH /api/user/availability`) and returns the saved value.
    public func setFreeCurrently(_ isFree: Bool) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["is_free_this_week": isFree])
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/user/availability", method: .patch, body: body))
        guard
            let saved = JSONFields.dictionary(try JSONFields.object(data)["availability"]),
            let value = JSONFields.bool(saved["is_free_this_week"])
        else { throw APIError.decoding }
        return value
    }

    // MARK: - Notification preferences

    /// Reads `notification_preferences` under RLS, as the KMP client does (there is no GET route).
    /// A missing row means the server defaults (everything on); a failed read throws — it is
    /// never reported as "all on".
    public func notificationPreferences(userID: String) async throws -> NotificationPreferences {
        let columns = NotificationPreferences.Key.allCases.map(\.rawValue).joined(separator: ",")
        let rows = try await restRows(
            table: "notification_preferences",
            query: [URLQueryItem(name: "select", value: columns), URLQueryItem(name: "user_id", value: "eq.\(userID)")]
        )
        return NotificationPreferences(row: rows.first ?? [:])
    }

    /// Saves one preference through the BFF (`PATCH /api/user/preferences`) and returns the
    /// server's full resulting row.
    public func setNotificationPreference(_ key: NotificationPreferences.Key, enabled: Bool) async throws -> NotificationPreferences {
        let body = try JSONSerialization.data(withJSONObject: [key.rawValue: enabled])
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/user/preferences", method: .patch, body: body))
        let root = try JSONFields.object(data)
        guard JSONFields.bool(root["ok"]) == true else { throw APIError.decoding }
        return NotificationPreferences(row: root)
    }

    // MARK: - Location privacy

    /// Reads the three location-privacy columns on `users` under RLS (KMP contract).
    public func locationPrivacy(userID: String) async throws -> LocationPrivacy {
        let rows = try await restRows(
            table: "users",
            query: [
                URLQueryItem(name: "select", value: LocationPrivacy.Key.allCases.map(\.rawValue).joined(separator: ",")),
                URLQueryItem(name: "id", value: "eq.\(userID)")
            ]
        )
        guard let row = rows.first else { throw APIError.notFound }
        return LocationPrivacy(row: row)
    }

    /// Writes the location-privacy columns on the caller's own `users` row (KMP contract) and
    /// returns what the database now holds. Zero affected rows is a failure, never success.
    public func setLocationPrivacy(_ privacy: LocationPrivacy, userID: String) async throws -> LocationPrivacy {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        let body = try JSONSerialization.data(withJSONObject: privacy.row)
        let request = APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/users",
            method: .patch,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(userID)")],
            headers: ["apikey": supabaseAnonKey, "Prefer": "return=representation"],
            body: body
        )
        let (data, _) = try await api.executeRaw(request)
        guard
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let row = rows.first
        else { throw APIError.forbidden }
        return LocationPrivacy(row: row)
    }

    /// Clicks whose live availability shares a tag or timeframe with the viewer's
    /// (`get_availability_overlaps`; the RPC only answers for mutual connections).
    public func availabilityOverlaps(peerIDs: [String]) async throws -> Set<String> {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        guard !peerIDs.isEmpty else { return [] }
        let body = try JSONSerialization.data(withJSONObject: ["p_peer_ids": Array(Set(peerIDs)).sorted()])
        let (data, _) = try await api.executeRaw(.supabaseRPC("get_availability_overlaps", baseURL: supabaseURL, anonKey: supabaseAnonKey, body: body))
        return Self.overlappingPeers(data)
    }

    nonisolated static func overlappingPeers(_ data: Data) -> Set<String> {
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return Set(rows.compactMap { JSONFields.bool($0["has_overlap"]) == true ? JSONFields.string($0["peer_id"]) : nil })
    }

    private func restRows(table: String, query: [URLQueryItem]) async throws -> [[String: Any]] {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        let request = APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/\(table)",
            method: .get,
            queryItems: query,
            headers: ["apikey": supabaseAnonKey]
        )
        let (data, _) = try await api.executeRaw(request)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.decoding
        }
        return rows
    }
}

/// The signed-in user's own profile as the Me root needs it.
public struct SelfProfile: Codable, Equatable, Sendable {
    public let userID: String
    public let firstName: String
    public let lastName: String
    public let displayName: String
    public let avatarURL: String?
    public let interests: [String]
    public let personality: [String]
    /// `nil` when the server has no availability row yet.
    public let isFreeCurrently: Bool?
    /// Short tagline (≤160), `users.bio`.
    public var bio: String? = nil

    public var initials: String { Phase3Repository.initials(from: displayName) }

    static func decode(user: [String: Any], root: [String: Any], userID: String) -> SelfProfile {
        let first = JSONFields.string(user["first_name"]) ?? ""
        let last = JSONFields.string(user["last_name"]) ?? ""
        let display = JSONFields.string(user, "full_name", "name")
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let availability = JSONFields.dictionary(root["availability"])
        return SelfProfile(
            userID: userID,
            firstName: first,
            lastName: last,
            displayName: display.isEmpty ? "Click user" : display,
            avatarURL: JSONFields.string(user["image"]),
            interests: JSONFields.stringArray(root["tags"]),
            personality: JSONFields.stringArray(root["personality_tags"] ?? user["personality_tags"]),
            isFreeCurrently: availability.flatMap { JSONFields.bool($0["is_free_this_week"]) },
            bio: JSONFields.string(user["bio"])
        )
    }
}

/// Server-backed push categories surfaced in native Settings (spec §65.3). Retired categories
/// (`call_push_enabled`, Seed-a-Room `event_teaser_push_enabled`) are deliberately absent.
public struct NotificationPreferences: Codable, Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case messages = "message_push_enabled"
        case eventReminders = "event_reminder_push_enabled"
        case reconnectNudges = "reconnect_nudge_push_enabled"
        case availabilityMatches = "availability_match_push_enabled"
        case hubMessages = "hub_message_push_enabled"

        public var title: String {
            switch self {
            case .messages: "Message notifications"
            case .eventReminders: "Event reminders"
            case .reconnectNudges: "Reconnect nudges"
            case .availabilityMatches: "Availability matches"
            case .hubMessages: "Hub messages"
            }
        }

        public var detail: String {
            switch self {
            case .messages: "New messages, archive warnings, and Click Drop reveals"
            case .eventReminders: "Day-of and one-hour-before reminders for your events"
            case .reconnectNudges: "Prompts to reconnect and shared upcoming events"
            case .availabilityMatches: "When a Click's plans overlap with yours"
            case .hubMessages: "Messages in community and event hubs"
            }
        }
    }

    private var values: [String: Bool]

    public subscript(key: Key) -> Bool {
        get { values[key.rawValue] ?? true }
        set { values[key.rawValue] = newValue }
    }

    /// Absent columns take the server's upsert default (`true`).
    init(row: [String: Any]) {
        values = Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.rawValue, JSONFields.bool(row[$0.rawValue]) ?? true) })
    }
}

/// The three independent location-privacy toggles (spec §65.4).
public struct LocationPrivacy: Codable, Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case connectionSnap = "location_connection_snap_enabled"
        case memoryMap = "location_show_on_map_enabled"
        case businessInsights = "location_include_in_insights_enabled"
    }

    public var connectionSnap: Bool
    public var memoryMap: Bool
    public var businessInsights: Bool

    public init(connectionSnap: Bool, memoryMap: Bool, businessInsights: Bool) {
        self.connectionSnap = connectionSnap
        self.memoryMap = memoryMap
        self.businessInsights = businessInsights
    }

    /// Absent columns are off, matching the KMP model defaults (no accidental opt-in).
    init(row: [String: Any]) {
        connectionSnap = JSONFields.bool(row[Key.connectionSnap.rawValue]) ?? false
        memoryMap = JSONFields.bool(row[Key.memoryMap.rawValue]) ?? false
        businessInsights = JSONFields.bool(row[Key.businessInsights.rawValue]) ?? false
    }

    var row: [String: Bool] {
        [
            Key.connectionSnap.rawValue: connectionSnap,
            Key.memoryMap.rawValue: memoryMap,
            Key.businessInsights.rawValue: businessInsights
        ]
    }
}
