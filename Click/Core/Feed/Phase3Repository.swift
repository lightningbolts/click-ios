import Foundation

public actor Phase3Repository {
    private let api: ClickAPIClient
    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

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

    public func cachedClicks(for userID: String) -> ClicksSnapshot? {
        cached(ClicksSnapshot.self, key: "phase3.clicks.\(userID)")
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
        let mapRows = root["map"] as? [[String: Any]] ?? []
        let coreIDs = Set(Self.stringArray(root["core"]))

        let peerIDs = Array(Set((activeRows + archivedRows + mapRows).compactMap {
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
            groups: [],
            mapPins: Self.mapPins(rows: mapRows, currentUserID: userID, identities: identities, coreIDs: coreIDs)
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
                isCore: coreIDs.contains(connectionID),
                awaitsPriorResponse: string(row["source"]) == "prior" && status == "pending"
                    && string(row["initiator_id"]).map { $0 != currentUserID } ?? false
            )
        }
        return items.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    /// Canonical 1:1 connection pins, collapsing duplicate edges to the same peer (KMP
    /// `visibleMapConnections`). Memory Map does not hide non-core pins.
    nonisolated static func mapPins(
        rows: [[String: Any]],
        currentUserID: String,
        identities: [String: InboxIdentity],
        coreIDs: Set<String>
    ) -> [ConnectionPin] {
        var byPeer: [String: (pin: ConnectionPin, created: Date)] = [:]
        for row in rows {
            guard
                let connectionID = string(row["id"]),
                let userIDs = row["user_ids"] as? [String], userIDs.count == 2,
                let peerID = userIDs.first(where: { $0 != currentUserID }),
                let coordinate = pinCoordinate(row)
            else { continue }
            let encounters = (row["connection_encounters"] as? [[String: Any]] ?? [])
                .sorted { (timestamp($0["encountered_at"]) ?? .distantFuture) < (timestamp($1["encountered_at"]) ?? .distantFuture) }
            let name = identities[peerID]?.name ?? "Click user"
            let pin = ConnectionPin(
                connectionID: connectionID,
                userID: peerID,
                displayName: name,
                avatarURL: identities[peerID]?.avatarURL,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                locationName: string(encounters.first?["location_name"]) ?? string(row["semantic_location"]),
                isCore: coreIDs.contains(connectionID)
            )
            let created = timestamp(row["created"]) ?? .distantPast
            // Keep the oldest edge for a peer so the first-meet pin never moves.
            if let existing = byPeer[peerID], existing.created <= created { continue }
            byPeer[peerID] = (pin, created)
        }
        return byPeer.values.map(\.pin).sorted { $0.userID < $1.userID }
    }

    /// Mirrors click-web `connectionMapPinGeo`: `geo_location`, then origin encounter GPS,
    /// then latest encounter GPS; (0, 0) is treated as missing.
    nonisolated static func pinCoordinate(_ row: [String: Any]) -> (latitude: Double, longitude: Double)? {
        func valid(_ lat: Double?, _ lon: Double?) -> (Double, Double)? {
            guard let lat, let lon, lat.isFinite, lon.isFinite, !(lat == 0 && lon == 0),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return (lat, lon)
        }
        if let geo = JSONFields.dictionary(row["geo_location"]),
           let found = valid(JSONFields.double(geo["lat"] ?? geo["latitude"]),
                             JSONFields.double(geo["lon"] ?? geo["longitude"] ?? geo["lng"])) {
            return found
        }
        let encounters = (row["connection_encounters"] as? [[String: Any]] ?? [])
            .sorted { (timestamp($0["encountered_at"]) ?? .distantFuture) < (timestamp($1["encountered_at"]) ?? .distantFuture) }
        for encounter in [encounters.first, encounters.last].compactMap({ $0 }) {
            if let found = valid(JSONFields.double(encounter["gps_lat"]), JSONFields.double(encounter["gps_lon"])) {
                return found
            }
        }
        return nil
    }

    private nonisolated static func peerID(in row: [String: Any], currentUserID: String) -> String? {
        (row["user_ids"] as? [String])?.first { $0 != currentUserID }
    }

    /// Lightweight self identity (name + avatar) without the timeline or inbox requests that a
    /// full profile refresh performs.
    public func identity(userID: String) async throws -> (firstName: String, displayName: String, avatarURL: String?) {
        let payload = try await fetchProfile(userID: userID, connectionID: nil)
        let first = payload.firstName.isEmpty
            ? payload.displayName.split(separator: " ").first.map(String.init) ?? ""
            : payload.firstName
        return (first, payload.displayName, payload.avatarURL)
    }

    private struct ProfilePayload: Sendable {
        let firstName: String
        let displayName: String
        let avatarURL: String?
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
        let root = try Self.jsonObject(data)
        let user = root["user"] as? [String: Any] ?? [:]

        let first = Self.string(user["first_name"]) ?? ""
        let last = Self.string(user["last_name"]) ?? ""
        let directName = Self.string(user["full_name"]) ?? Self.string(user["name"])
        let displayName = directName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ").nonEmpty
            ?? "Click user"
        return ProfilePayload(firstName: first, displayName: displayName, avatarURL: Self.string(user["image"]))
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
