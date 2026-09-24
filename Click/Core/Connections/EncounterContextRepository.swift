import Foundation

/// Opt-in sensor context stored with an encounter (KMP `ConnectionSensorContext` keys).
public struct EncounterSensorContext: Equatable, Sendable {
    public var noiseLevel: String?
    public var noiseDecibels: Double?
    public var elevationCategory: String?
    public var barometricElevationMeters: Double?

    public init(noiseLevel: String? = nil, noiseDecibels: Double? = nil, elevationCategory: String? = nil, barometricElevationMeters: Double? = nil) {
        self.noiseLevel = noiseLevel
        self.noiseDecibels = noiseDecibels
        self.elevationCategory = elevationCategory
        self.barometricElevationMeters = barometricElevationMeters
    }

    var isEmpty: Bool { noiseLevel == nil && noiseDecibels == nil && elevationCategory == nil && barometricElevationMeters == nil }

    var columns: [String: Any] {
        var out: [String: Any] = [:]
        if let noiseLevel { out["noise_level"] = noiseLevel }
        if let noiseDecibels { out["exact_noise_level_db"] = noiseDecibels }
        if let elevationCategory { out["elevation_category"] = elevationCategory }
        if let barometricElevationMeters { out["exact_barometric_elevation_m"] = barometricElevationMeters }
        return out
    }
}

/// A post-connect event suggestion (`GET /api/connections/{id}/event-recommendation`).
public struct EventRecommendation: Equatable, Sendable {
    public let beaconID: String
    public let title: String
    public let startsAt: Date?
    public let locationName: String?
    public let peerName: String?
}

/// Encounter context writes and post-connect reads (spec §25–§27), wire-compatible with KMP.
public actor EncounterContextRepository {
    private let api: ClickAPIClient
    private let supabaseURL: URL?
    private let supabaseAnonKey: String

    /// KMP `ACTIVE_ENCOUNTER_CONTEXT_PATCH_WINDOW_MS` / `ACTIVE_ENCOUNTER_FUTURE_SKEW_MS`.
    public static let patchWindow: TimeInterval = 30 * 60
    public static let futureSkew: TimeInterval = 2 * 60

    public init(api: ClickAPIClient, supabaseURL: URL?, supabaseAnonKey: String) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    struct EncounterRow: Equatable {
        let id: String
        let encounteredAt: Date
        let contextTags: [String]
        let reportingUserID: String?
    }

    /// KMP `mergePatchLatestEncounter`: every encounter row of this connection from the last
    /// 30 minutes gets the union of its tags and the new ones; sensor columns are written only
    /// to rows this user reported (or rows with no reporter). Rows with nothing to change are
    /// skipped.
    nonisolated static func patches(
        rows: [EncounterRow],
        tags: [String],
        sensor: EncounterSensorContext,
        reportingUserID: String,
        now: Date
    ) -> [(id: String, body: [String: Any])] {
        let active = rows.filter {
            $0.encounteredAt >= now.addingTimeInterval(-patchWindow) && $0.encounteredAt <= now.addingTimeInterval(futureSkew)
        }
        var union: [String] = []
        for tag in active.flatMap(\.contextTags) + tags where !union.contains(tag) { union.append(tag) }
        return active.compactMap { row in
            var body: [String: Any] = [:]
            if union != row.contextTags, !tags.isEmpty { body["context_tags"] = union }
            if !sensor.isEmpty, row.reportingUserID == nil || row.reportingUserID == reportingUserID {
                body.merge(sensor.columns) { _, new in new }
            }
            return body.isEmpty ? nil : (row.id, body)
        }
    }

    public enum TagSaveError: Error, Equatable {
        case noActiveEncounter
    }

    public func saveContext(connectionID: String, tags: [String], sensor: EncounterSensorContext, reportingUserID: String, now: Date = .now) async throws {
        guard !tags.isEmpty || !sensor.isEmpty else { return }
        let data = try await rest("GET", query: [
            URLQueryItem(name: "select", value: "id,encountered_at,context_tags,reporting_user_id"),
            URLQueryItem(name: "connection_id", value: "eq.\(connectionID)"),
            URLQueryItem(name: "order", value: "encountered_at.desc"),
            URLQueryItem(name: "limit", value: "25")
        ])
        let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).compactMap { row -> EncounterRow? in
            guard let id = JSONFields.string(row["id"]), let date = JSONFields.date(row["encountered_at"]) else { return nil }
            return EncounterRow(id: id, encounteredAt: date, contextTags: JSONFields.stringArray(row["context_tags"]),
                                reportingUserID: JSONFields.string(row["reporting_user_id"]))
        }
        let updates = Self.patches(rows: rows, tags: tags, sensor: sensor, reportingUserID: reportingUserID, now: now)
        if updates.isEmpty, !rows.contains(where: { $0.encounteredAt >= now.addingTimeInterval(-Self.patchWindow) }) {
            throw TagSaveError.noActiveEncounter
        }
        for update in updates {
            _ = try await rest("PATCH", query: [URLQueryItem(name: "id", value: "eq.\(update.id)")],
                               body: try JSONSerialization.data(withJSONObject: update.body))
        }
    }

    /// Replaces one encounter's tags ("Edit tags" on the timeline). `at_event` is server-owned
    /// and kept, so editing never detaches an event.
    public func setTags(encounterID: String, tags: [String]) async throws {
        let data = try await rest("GET", query: [
            URLQueryItem(name: "select", value: "context_tags"),
            URLQueryItem(name: "id", value: "eq.\(encounterID)")
        ])
        let existing = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first.map { JSONFields.stringArray($0["context_tags"]) } ?? []
        var next = tags
        if existing.contains("at_event"), !next.contains("at_event") { next.append("at_event") }
        _ = try await rest("PATCH", query: [URLQueryItem(name: "id", value: "eq.\(encounterID)")],
                           body: try JSONSerialization.data(withJSONObject: ["context_tags": next]))
    }

    /// Nil when the server has no suggestion (always nil for groups). Errors are the caller's
    /// to swallow: a recommendation never blocks the connection.
    public func eventRecommendation(connectionID: String, latitude: Double?, longitude: Double?) async throws -> EventRecommendation? {
        var query: [URLQueryItem] = []
        if let latitude, let longitude {
            query = [URLQueryItem(name: "lat", value: String(latitude)), URLQueryItem(name: "lng", value: String(longitude))]
        }
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/connections/\(connectionID)/event-recommendation", queryItems: query))
        guard let row = JSONFields.dictionary(try JSONFields.object(data)["recommendation"]),
              let beaconID = JSONFields.string(row["beacon_id"]),
              let title = JSONFields.string(row["title"]) else { return nil }
        return EventRecommendation(
            beaconID: beaconID,
            title: title,
            startsAt: JSONFields.date(row["event_start_at"]),
            locationName: JSONFields.string(row["location_name"]).flatMap { $0 == "Current location" ? nil : $0 },
            peerName: JSONFields.string(row["peer_name"])
        )
    }

    private func rest(_ method: String, query: [URLQueryItem], body: Data? = nil) async throws -> Data {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        let (data, _) = try await api.executeRaw(APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/connection_encounters",
            method: HTTPMethod(rawValue: method) ?? .get,
            queryItems: query,
            headers: ["apikey": supabaseAnonKey, "Prefer": "return=minimal"],
            body: body
        ))
        return data
    }
}
