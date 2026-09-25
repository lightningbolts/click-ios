import Foundation

/// Another Click user's profile as seen by the viewer.
public struct PeerProfile: Codable, Equatable, Sendable {
    public let userID: String
    public let displayName: String
    public let firstName: String
    public let avatarURL: String?
    public let interests: [String]
    public let personality: [String]
    /// Interests the viewer and this person share (server-computed).
    public let sharedInterests: [String]
    public let isFreeCurrently: Bool?
    public var bio: String? = nil

    public var initials: String { Phase3Repository.initials(from: displayName) }

    static func decode(_ root: [String: Any], userID: String) throws -> PeerProfile {
        guard let user = JSONFields.dictionary(root["user"]) else { throw APIError.decoding }
        let first = JSONFields.string(user["first_name"]) ?? ""
        let last = JSONFields.string(user["last_name"]) ?? ""
        let display = JSONFields.string(user, "full_name", "name")
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let availability = JSONFields.dictionary(root["availability"])
        return PeerProfile(
            userID: userID,
            displayName: display.isEmpty ? "Click user" : display,
            firstName: first.isEmpty ? (display.split(separator: " ").first.map(String.init) ?? "") : first,
            avatarURL: JSONFields.string(user["image"]),
            interests: JSONFields.stringArray(root["tags"]),
            personality: JSONFields.stringArray(root["personality_tags"]),
            sharedInterests: JSONFields.stringArray(root["sharedInterestTags"]),
            isFreeCurrently: availability.flatMap { JSONFields.bool($0["is_free_this_week"]) },
            bio: JSONFields.string(user["bio"])
        )
    }
}

/// One real-world encounter in a relationship (first meet or reconnect).
public struct Encounter: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let place: String?
    /// Present only when the server's per-viewer eligibility (RSVP + check-in) allows it.
    public let eventTitle: String?
    public let eventBeaconID: String?
    public let contextTags: [String]
    public let noiseLevel: String?
    public let elevation: String?
    /// Named place from reverse geocoding ("Gas Works Park"), preferred over street addresses.
    public var venue: String? = nil
    public var temperatureCelsius: Double? = nil
    public var weatherCondition: String? = nil
    public var relativeAltitudeMeters: Double? = nil
    public var neighbourhood: String? = nil
    public var city: String? = nil
    public var noiseDecibels: Double? = nil
    public var barometricElevationMeters: Double? = nil
    public var lux: Double? = nil
    public var motionVariance: Double? = nil
    public var windKph: Double? = nil
    public var windDirectionDegrees: Double? = nil
    /// Raw `location_name` / `display_location` (KMP `formatEncounterPlaceLine` inputs).
    public var locationName: String? = nil
    public var displayLocation: String? = nil
    public var compassAzimuth: Double? = nil
    public var batteryLevel: Int? = nil
    /// Optional `vibe_capture` text written by KMP's vibe check.
    public var vibeCapture: String? = nil

    /// Venue name, else the first component of the stored label (never a full address).
    public var placeName: String? {
        if let venue { return venue }
        return place?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func decode(_ row: [String: Any]) -> Encounter? {
        guard let id = JSONFields.string(row["id"]), let date = JSONFields.date(row["encountered_at"]) else { return nil }
        let semantic = JSONFields.dictionary(row["semantic_location"])
        let weather = JSONFields.dictionary(row["weather_snapshot"])
        return Encounter(
            id: id,
            date: date,
            place: JSONFields.string(row["location_name"]) ?? JSONFields.place(row["display_location"]),
            eventTitle: JSONFields.string(row["event_beacon_title"]),
            eventBeaconID: JSONFields.string(row["event_beacon_id"]),
            contextTags: JSONFields.stringArray(row["context_tags"]).filter { $0 != "at_event" },
            noiseLevel: JSONFields.string(row["noise_level"]),
            elevation: JSONFields.string(row["elevation_category"]),
            venue: semantic.flatMap { JSONFields.string($0["name"]) },
            temperatureCelsius: weather.flatMap { JSONFields.double($0["temperatureCelsius"]) },
            weatherCondition: weather.flatMap { JSONFields.string($0["condition"]) },
            relativeAltitudeMeters: JSONFields.double(row["relative_altitude_m"]),
            neighbourhood: semantic.flatMap { JSONFields.dictionary($0["address"]) }.flatMap { JSONFields.string($0, "neighbourhood", "neighborhood", "suburb") },
            city: semantic.flatMap { JSONFields.dictionary($0["address"]) }.flatMap { JSONFields.string($0, "city", "town", "village") },
            noiseDecibels: JSONFields.double(row["exact_noise_level_db"]),
            barometricElevationMeters: JSONFields.double(row["exact_barometric_elevation_m"]),
            lux: JSONFields.double(row["lux_level"]),
            motionVariance: JSONFields.double(row["motion_variance"]),
            windKph: weather.flatMap { JSONFields.double($0["windSpeedKph"]) },
            windDirectionDegrees: weather.flatMap { JSONFields.double($0["windDirectionDegrees"]) },
            locationName: JSONFields.string(row["location_name"]),
            displayLocation: JSONFields.place(row["display_location"]),
            compassAzimuth: JSONFields.double(row["compass_azimuth"]),
            batteryLevel: JSONFields.int(row["battery_level"]),
            vibeCapture: JSONFields.string(row["vibe_capture"])
        )
    }
}

/// A journal note on a profile timeline (`/api/profile/timeline`).
public struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Visibility: String, Codable, CaseIterable, Sendable {
        case `private`
        case shared

        public var label: String { self == .private ? "Only me" : "Shared with them" }
    }

    public let id: String
    public let body: String
    public let visibility: Visibility
    public let authorID: String
    public let authorName: String?
    public let createdAt: Date?

    static func decode(_ row: [String: Any]) -> JournalEntry? {
        guard let id = JSONFields.string(row["id"]), let body = JSONFields.string(row["body"]) else { return nil }
        let raw = JSONFields.string(row["visibility"]) ?? "private"
        return JournalEntry(
            id: id,
            body: body,
            visibility: raw == "private" ? .private : .shared,
            authorID: JSONFields.string(row["author_user_id"]) ?? "",
            authorName: JSONFields.string(row["author_name"]),
            createdAt: JSONFields.date(row["created_at"])
        )
    }
}

/// A message row listed by `/api/connections/{id}/tabs` (media, files, beacons).
/// Content is ciphertext; only type, sender, time, and plaintext metadata are used.
public struct SharedItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let chatID: String
    public let senderID: String
    public let messageType: String
    public let createdAt: Date?
    /// Beacon shares carry the beacon ID in metadata.
    public let beaconID: String?
    public let beaconTitle: String?
    /// The shared event's banner (same metadata keys as the chat's event card).
    public var beaconImageURL: String? = nil

    static func decode(_ row: [String: Any]) -> SharedItem? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        let metadata = JSONFields.dictionary(row["metadata"]) ?? [:]
        return SharedItem(
            id: id,
            chatID: JSONFields.string(row["chat_id"]) ?? "",
            senderID: JSONFields.string(row["user_id"]) ?? "",
            messageType: JSONFields.string(row["message_type"]) ?? "",
            createdAt: JSONFields.date(row["time_created"]),
            beaconID: JSONFields.string(metadata, "beacon_id", "beaconId"),
            beaconTitle: JSONFields.string(metadata, "beacon_title", "title"),
            beaconImageURL: JSONFields.string(metadata, "album_art_url", "image_url", "cover_url")
        )
    }
}

public struct SharedTabs: Equatable, Sendable, Codable {
    public let chatID: String
    public let media: [SharedItem]
    public let files: [SharedItem]
    public let beacons: [SharedItem]
    /// Raw message rows (JSON arrays) so media/files can be decrypted like chat messages.
    public var mediaRows: Data = Data("[]".utf8)
    public var fileRows: Data = Data("[]".utf8)
    /// More attachments exist before the oldest one here (nil from older servers).
    public var hasMore: Bool? = nil

    /// The oldest attachment time here: the cursor for the next page.
    public var oldestAttachment: Date? {
        (media + files).compactMap(\.createdAt).min()
    }

    /// Appends an older page (dedup by ID); rows are merged as JSON arrays.
    public func appending(_ page: SharedTabs) -> SharedTabs {
        let knownIDs = Set((media + files).map(\.id))
        func mergeRows(_ a: Data, _ b: Data) -> Data {
            let first = (try? JSONSerialization.jsonObject(with: a)) as? [[String: Any]] ?? []
            let known = Set(first.compactMap { JSONFields.string($0["id"]) })
            let second = ((try? JSONSerialization.jsonObject(with: b)) as? [[String: Any]] ?? [])
                .filter { JSONFields.string($0["id"]).map { !known.contains($0) } ?? false }
            return (try? JSONSerialization.data(withJSONObject: first + second)) ?? a
        }
        var merged = SharedTabs(
            chatID: chatID,
            media: media + page.media.filter { !knownIDs.contains($0.id) },
            files: files + page.files.filter { !knownIDs.contains($0.id) },
            beacons: beacons,
            mediaRows: mergeRows(mediaRows, page.mediaRows),
            fileRows: mergeRows(fileRows, page.fileRows)
        )
        let added = (page.media + page.files).contains { !knownIDs.contains($0.id) }
        merged.hasMore = (page.hasMore ?? false) && added
        return merged
    }
}

/// Canonical person-profile reads and relationship actions (spec §47, §66).
public actor ProfileRepository {
    private let api: ClickAPIClient
    private let cache: CacheStore

    public init(api: ClickAPIClient, cache: CacheStore = .shared) {
        self.api = api
        self.cache = cache
    }

    public func cachedProfile(userID: String, viewerID: String) async -> PeerProfile? {
        await cache.load(PeerProfile.self, key: "peer.\(userID)", userID: viewerID)
    }

    public func profile(userID: String, connectionID: String?, viewerID: String) async throws -> PeerProfile {
        var query: [URLQueryItem] = []
        if let connectionID { query.append(URLQueryItem(name: "connectionId", value: connectionID)) }
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/users/\(userID)/profile", method: .get, queryItems: query))
        let profile = try PeerProfile.decode(try JSONFields.object(data), userID: userID)
        await cache.save(profile, key: "peer.\(userID)", userID: viewerID)
        return profile
    }

    /// Encounters from the event-redacted single-connection read, newest first.
    /// `GET /api/users/{id}/public-profile` — the limited card anyone may see (App Clip, QR
    /// previews, event directories): display name, avatar, aura colors only.
    public func publicProfile(userID: String) async throws -> PublicProfile {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/users/\(userID)/public-profile", requiresAuth: false))
        let root = try JSONFields.object(data)
        return PublicProfile(
            userID: userID,
            displayName: JSONFields.string(root["display_name"]) ?? "Click user",
            avatarURL: JSONFields.string(root["avatar_url"]),
            auraColors: JSONFields.stringArray(root["aura_colors"])
        )
    }

    public func encounters(connectionID: String) async throws -> [Encounter] {
        let (data, _) = try await api.executeRaw(APIRequest(
            path: "/api/connections",
            method: .get,
            queryItems: [URLQueryItem(name: "connectionId", value: connectionID)]
        ))
        guard let connection = JSONFields.dictionary(try JSONFields.object(data)["connection"]) else {
            throw APIError.notFound
        }
        return JSONFields.rows(connection["connection_encounters"])
            .compactMap(Encounter.decode)
            .sorted { $0.date > $1.date }
    }

    // MARK: - Journal

    /// Journal notes on a person (`user`) or a group chat (`chat`).
    public func journal(targetUserID: String, targetType: String = "user") async throws -> [JournalEntry] {
        let (data, _) = try await api.executeRaw(APIRequest(
            path: "/api/profile/timeline",
            method: .get,
            queryItems: [URLQueryItem(name: "target_type", value: targetType), URLQueryItem(name: "target_id", value: targetUserID)]
        ))
        let root = try JSONFields.object(data)
        guard root["journal_entries"] != nil else { throw APIError.decoding }
        return JSONFields.rows(root["journal_entries"]).compactMap(JournalEntry.decode)
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public func addJournal(targetUserID: String, body: String, visibility: JournalEntry.Visibility, targetType: String = "user") async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "target_type": targetType, "target_id": targetUserID, "body": body, "visibility": visibility.rawValue
        ])
        _ = try await api.executeRaw(APIRequest(path: "/api/profile/timeline", method: .post, body: payload))
    }

    public func updateJournal(id: String, body: String, visibility: JournalEntry.Visibility) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "body": body, "visibility": visibility.rawValue])
        _ = try await api.executeRaw(APIRequest(path: "/api/profile/timeline", method: .put, body: payload))
    }

    public func deleteJournal(id: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["id": id])
        _ = try await api.executeRaw(APIRequest(path: "/api/profile/timeline", method: .delete, body: payload))
    }

    // MARK: - Shared content tabs

    /// `GET /api/connections/{id}/tabs` — also accepts a group chat ID via `chatId`.
    /// Pages of `limit` attachments, newest first; `before` (ms cursor) fetches older pages.
    public static let sharedPageSize = 60

    public func sharedTabs(connectionID: String? = nil, chatID: String? = nil, before: Date? = nil,
                           limit: Int = ProfileRepository.sharedPageSize) async throws -> SharedTabs {
        let pathID = connectionID ?? chatID ?? ""
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let chatID { query.append(URLQueryItem(name: "chatId", value: chatID)) }
        if let before { query.append(URLQueryItem(name: "before", value: String(Int64(before.timeIntervalSince1970 * 1000)))) }
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/connections/\(pathID)/tabs", method: .get, queryItems: query))
        let root = try JSONFields.object(data)
        func items(_ key: String) -> [SharedItem] {
            JSONFields.rows(root[key]).compactMap(SharedItem.decode)
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
        func raw(_ key: String) -> Data {
            (try? JSONSerialization.data(withJSONObject: root[key] as? [Any] ?? [])) ?? Data("[]".utf8)
        }
        return SharedTabs(
            chatID: JSONFields.string(root["chatId"]) ?? chatID ?? "",
            media: items("media"),
            files: items("files"),
            beacons: items("beacons"),
            mediaRows: raw("media"),
            fileRows: raw("files"),
            hasMore: JSONFields.bool(root["hasMore"])
        )
    }

    // MARK: - Safety (spec §66)

    public func report(connectionID: String, reason: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["connection_id": connectionID, "reason": reason])
        _ = try await api.executeRaw(APIRequest(path: "/api/safety/report", method: .post, body: body))
    }

    public func block(userID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["blocked_id": userID])
        _ = try await api.executeRaw(APIRequest(path: "/api/safety/block", method: .post, body: body))
    }

    /// Removes the connection for this user only (`POST /api/connections/hide`; the server's
    /// `DELETE /api/connections` is the same per-user hide, so there is one action, not two).
    public func removeConnection(connectionID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["connection_id": connectionID])
        _ = try await api.executeRaw(APIRequest(path: "/api/connections/hide", method: .post, body: body))
    }

    /// `POST /api/connections/prior/respond`: accept creates the chat; decline removes it for
    /// both people. A 409 (`not_pending`) means it was already answered elsewhere.
    public func respondToPriorConnection(connectionID: String, accept: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["connection_id": connectionID, "action": accept ? "accept" : "decline"])
        _ = try await api.executeRaw(APIRequest(path: "/api/connections/prior/respond", method: .post, body: body))
    }

    /// `GET /api/safety/block` → the caller's blocks, newest first.
    public func blockedUsers() async throws -> [BlockedUser] {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/safety/block", method: .get))
        return JSONFields.rows(try JSONFields.object(data)["blocks"]).compactMap { row in
            JSONFields.string(row["blocked_id"]).map { BlockedUser(userID: $0, blockedAt: JSONFields.date(row["blocked_at"])) }
        }
    }

    /// `DELETE /api/safety/block?blocked_id=`.
    public func unblock(userID: String) async throws {
        _ = try await api.executeRaw(APIRequest(
            path: "/api/safety/block", method: .delete,
            queryItems: [URLQueryItem(name: "blocked_id", value: userID)]
        ))
    }
}

/// Human labels for encounter context chips (prototype: "Outdoors / Nature", "61°F · Clear",
/// "Lively", "+14 m") — never raw enum values like `BELOW_GROUND`.
enum EncounterLabels {
    public struct MetricPill: Hashable, Sendable {
        public let symbol: String
        public let tintHex: String
        public let text: String

        public init(symbol: String, tintHex: String, text: String) {
            self.symbol = symbol
            self.tintHex = tintHex
            self.text = text
        }
    }

    /// Context tags as chips (KMP labels with emoji; custom tags as written).
    nonisolated static func chips(for encounter: Encounter) -> [String] {
        var seen = Set<String>()
        return encounter.contextTags.map(tag).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Secondary lines under the title, returning only when and place lines.
    nonisolated static func lines(for encounter: Encounter, timeZone: TimeZone = .current) -> [(symbol: String, text: String)] {
        var rows: [(String, String)] = [("clock", whenLine(encounter.date, timeZone: timeZone))]
        if let place = placeLine(locationName: encounter.locationName ?? encounter.venue,
                                 displayLocation: encounter.displayLocation,
                                 neighbourhood: encounter.neighbourhood) {
            rows.append(("mappin", place))
        }
        return rows
    }

    /// Colorful metric pills in KMP order: condition, temperature, wind, noise, elevation, compass.
    nonisolated static func metricPills(for encounter: Encounter) -> [MetricPill] {
        var pills: [MetricPill] = []

        if let condition = encounter.weatherCondition?.trimmingCharacters(in: .whitespaces), !condition.isEmpty {
            pills.append(MetricPill(symbol: "cloud", tintHex: "#B0BEC5", text: condition))
        }

        if let celsius = encounter.temperatureCelsius, celsius.isFinite {
            let fahrenheit = Int((celsius * 9 / 5 + 32).rounded())
            let c = Int(celsius.rounded())
            pills.append(MetricPill(symbol: "thermometer.medium", tintHex: "#FFCC80", text: "\(fahrenheit)°F (\(c)°C)"))
        }

        if let wind = encounter.windKph, wind.isFinite {
            let direction = encounter.windDirectionDegrees.map { " " + compass($0) } ?? ""
            pills.append(MetricPill(symbol: "wind", tintHex: "#81D4FA", text: "\(Int(wind.rounded())) km/h\(direction)"))
        }

        if let noiseCat = encounter.noiseLevel.flatMap(noise) {
            pills.append(MetricPill(symbol: "waveform", tintHex: "#69F0AE", text: noiseCat))
        }

        let elevCat = encounter.elevation.flatMap(elevation)
        let elevM = (encounter.relativeAltitudeMeters ?? encounter.barometricElevationMeters).flatMap { $0.isFinite ? "\(Int($0.rounded())) m" : nil }
        let elevParts = [elevCat, elevM].compactMap { $0 }
        if !elevParts.isEmpty {
            pills.append(MetricPill(symbol: "mountain.2", tintHex: "#90CAF9", text: elevParts.joined(separator: " · ")))
        }

        if let azimuth = encounter.compassAzimuth, azimuth.isFinite {
            pills.append(MetricPill(symbol: "safari", tintHex: "#B39DDB", text: "\(Int(azimuth.rounded()))°"))
        }

        return pills
    }

    nonisolated static func whenLine(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy '·' h:mm a"
        return formatter.string(from: date)
    }

    /// KMP `formatEncounterPlaceLine`: "Location • Neighbourhood, display".
    nonisolated static func placeLine(locationName: String?, displayLocation: String?, neighbourhood: String?) -> String? {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let name = clean(locationName)
        let display = clean(displayLocation)
        let area = clean(neighbourhood)
        switch (name, area, display) {
        case let (name?, area?, display?): return "\(name) • \(area), \(display)"
        case let (name?, area?, nil): return "\(name) • \(area)"
        case let (nil, area?, display?): return "\(area), \(display)"
        case let (name?, nil, display?) where name != display: return "\(name) · \(display)"
        default: return display ?? name ?? area
        }
    }

    nonisolated static func compass(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return directions[Int(((normalized + 22.5) / 45).rounded(.down)) % 8]
    }

    nonisolated static func tag(_ raw: String) -> String {
        ContextTagTaxonomy.label(for: raw)
    }

    /// KMP `formatNoiseCategory`.
    nonisolated static func noise(_ raw: String) -> String? {
        switch raw.uppercased().replacingOccurrences(of: " ", with: "_") {
        case "VERY_QUIET": "Very quiet"
        case "QUIET": "Quiet"
        case "MODERATE": "Moderate"
        case "LOUD": "Loud"
        case "VERY_LOUD": "Very loud"
        default: nil
        }
    }

    /// KMP `formatElevationCategoryLabel`.
    nonisolated static func elevation(_ raw: String) -> String? {
        switch raw.uppercased().replacingOccurrences(of: " ", with: "_") {
        case "BELOW_GROUND": "Below ground"
        case "GROUND_LEVEL": "Ground level"
        case "ELEVATED": "Elevated"
        case "HIGH_RISE": "High rise"
        default: nil
        }
    }
}

public struct BlockedUser: Identifiable, Equatable, Sendable {
    public let userID: String
    public let blockedAt: Date?
    public var id: String { userID }
}

public struct PublicProfile: Equatable, Sendable {
    public let userID: String
    public let displayName: String
    public let avatarURL: String?
    public let auraColors: [String]
    public var initials: String { Phase3Repository.initials(from: displayName) }
}
