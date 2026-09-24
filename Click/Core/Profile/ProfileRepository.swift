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
            isFreeCurrently: availability.flatMap { JSONFields.bool($0["is_free_this_week"]) }
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
            place: JSONFields.string(row, "location_name", "display_location"),
            eventTitle: JSONFields.string(row["event_beacon_title"]),
            eventBeaconID: JSONFields.string(row["event_beacon_id"]),
            contextTags: JSONFields.stringArray(row["context_tags"]).filter { $0 != "at_event" },
            noiseLevel: JSONFields.string(row["noise_level"]),
            elevation: JSONFields.string(row["elevation_category"]),
            venue: semantic.flatMap { JSONFields.string($0["name"]) },
            temperatureCelsius: weather.flatMap { JSONFields.double($0["temperatureCelsius"]) },
            weatherCondition: weather.flatMap { JSONFields.string($0["condition"]) },
            relativeAltitudeMeters: JSONFields.double(row["relative_altitude_m"])
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
            beaconTitle: JSONFields.string(metadata, "beacon_title", "title")
        )
    }
}

public struct SharedTabs: Equatable, Sendable {
    public let chatID: String
    public let media: [SharedItem]
    public let files: [SharedItem]
    public let beacons: [SharedItem]
    /// Raw message rows (JSON arrays) so media/files can be decrypted like chat messages.
    public var mediaRows: Data = Data("[]".utf8)
    public var fileRows: Data = Data("[]".utf8)
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

    public func journal(targetUserID: String) async throws -> [JournalEntry] {
        let (data, _) = try await api.executeRaw(APIRequest(
            path: "/api/profile/timeline",
            method: .get,
            queryItems: [URLQueryItem(name: "target_type", value: "user"), URLQueryItem(name: "target_id", value: targetUserID)]
        ))
        let root = try JSONFields.object(data)
        guard root["journal_entries"] != nil else { throw APIError.decoding }
        return JSONFields.rows(root["journal_entries"]).compactMap(JournalEntry.decode)
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public func addJournal(targetUserID: String, body: String, visibility: JournalEntry.Visibility) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "target_type": "user", "target_id": targetUserID, "body": body, "visibility": visibility.rawValue
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
    public func sharedTabs(connectionID: String? = nil, chatID: String? = nil) async throws -> SharedTabs {
        let pathID = connectionID ?? chatID ?? ""
        var query = [URLQueryItem(name: "limit", value: "300")]
        if let chatID { query.append(URLQueryItem(name: "chatId", value: chatID)) }
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
            fileRows: raw("files")
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

    /// Removes the connection for this user (`DELETE /api/connections?connectionId=` hides it).
    public func removeConnection(connectionID: String) async throws {
        _ = try await api.executeRaw(APIRequest(
            path: "/api/connections",
            method: .delete,
            queryItems: [URLQueryItem(name: "connectionId", value: connectionID)]
        ))
    }
}

/// Human labels for encounter context chips (prototype: "Outdoors / Nature", "61°F · Clear",
/// "Lively", "+14 m") — never raw enum values like `BELOW_GROUND`.
enum EncounterLabels {
    static func chips(for encounter: Encounter, locale: Locale = .current) -> [String] {
        var chips = encounter.contextTags.map(tag)
        if let weather = weather(encounter, locale: locale) { chips.append(weather) }
        if let noise = encounter.noiseLevel.flatMap(noise) { chips.append(noise) }
        if let elevation = encounter.elevation.flatMap(elevation) { chips.append(elevation) }
        if let altitude = encounter.relativeAltitudeMeters, abs(altitude) >= 3 {
            chips.append(String(format: "%@%d m", altitude > 0 ? "+" : "−", Int(abs(altitude).rounded())))
        }
        var seen = Set<String>()
        return chips.filter { seen.insert($0.lowercased()).inserted }
    }

    static func tag(_ raw: String) -> String {
        let known: [String: String] = [
            "outdoors": "Outdoors / Nature", "nature": "Outdoors / Nature", "cafe": "Cafe / Coffee", "coffee": "Cafe / Coffee",
            "extended_hangout": "Extended hangout", "met_face_to_face": "Met face-to-face", "dining": "Dining",
            "study": "Study", "party": "Party", "club": "Club", "lecture": "Lecture", "conference": "Conference",
            "dorm": "Dorm", "transit": "Transit", "event": "Event", "lounge": "Lounge"
        ]
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if let label = known[key] { return label }
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst().lowercased()
    }

    static func noise(_ raw: String) -> String? {
        switch raw.uppercased() {
        case "VERY_QUIET": "Very quiet"
        case "QUIET": "Quiet"
        case "MODERATE": "Moderate"
        case "LOUD": "Lively"
        case "VERY_LOUD": "Loud"
        default: nil
        }
    }

    static func elevation(_ raw: String) -> String? {
        switch raw.uppercased() {
        case "BELOW_GROUND": "Below ground"
        case "ELEVATED": "Upstairs"
        case "HIGH_RISE": "High up"
        default: nil // Ground level is the unremarkable default.
        }
    }

    static func weather(_ encounter: Encounter, locale: Locale) -> String? {
        guard let celsius = encounter.temperatureCelsius else { return encounter.weatherCondition }
        let measurement = Measurement(value: celsius, unit: UnitTemperature.celsius)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        let temperature = formatter.string(from: measurement)
        return [temperature, encounter.weatherCondition].compactMap { $0 }.joined(separator: " · ")
    }
}
