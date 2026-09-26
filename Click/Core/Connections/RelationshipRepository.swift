import CoreLocation
import Foundation

/// A hangout logged without a tap, waiting for both people to confirm (`/api/hangouts`).
public struct PendingHangout: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case manual, nearby }

    public let id: String
    public let connectionID: String
    public let peerUserID: String?
    public let source: Source
    public let occurredAt: Date?
    public let locationName: String?
    public let confirmedByMe: Bool
    public let requestedByMe: Bool
    public let expiresAt: Date?

    static func decode(_ row: [String: Any]) -> PendingHangout? {
        guard let id = JSONFields.string(row["id"]), let connectionID = JSONFields.string(row["connection_id"]) else { return nil }
        return PendingHangout(
            id: id,
            connectionID: connectionID,
            peerUserID: JSONFields.string(row["peer_user_id"]),
            source: Source(rawValue: JSONFields.string(row["source"]) ?? "") ?? .manual,
            occurredAt: JSONFields.date(row["occurred_at"]),
            locationName: JSONFields.string(row["location_name"]),
            confirmedByMe: row["confirmed_by_me"] as? Bool ?? false,
            requestedByMe: row["requested_by_me"] as? Bool ?? false,
            expiresAt: JSONFields.date(row["expires_at"])
        )
    }
}

/// What confirming a hangout did.
public enum HangoutConfirmation: Equatable, Sendable {
    /// Recorded; waiting for the other person.
    case waiting
    /// Both confirmed: it's on the shared timeline (`alreadyLogged` when a tap had logged it).
    case logged(alreadyLogged: Bool)
}

/// Relationship actions that aren't messages: logging and confirming hangouts, waves, and the
/// opt-in presence pings behind hangout detection.
public actor RelationshipRepository {
    private let api: ClickAPIClient

    public init(api: ClickAPIClient) {
        self.api = api
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Logs a hangout for the other person to confirm (you're confirmed already).
    public func logHangout(connectionID: String, occurredAt: Date, coordinate: CLLocationCoordinate2D?, locationName: String?) async throws -> PendingHangout {
        var body: [String: Any] = [
            "connection_id": connectionID,
            "occurred_at": ISO8601DateFormatter().string(from: occurredAt)
        ]
        if let coordinate {
            body["lat"] = coordinate.latitude
            body["lon"] = coordinate.longitude
        }
        if let locationName, !locationName.trimmingCharacters(in: .whitespaces).isEmpty { body["location_name"] = locationName }
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/hangouts", method: .post, body: try json(body)))
        guard let row = JSONFields.dictionary(try JSONFields.object(data)["hangout"]), let hangout = PendingHangout.decode(row) else {
            throw APIError.decoding
        }
        return hangout
    }

    /// Hangouts waiting on anyone, newest first.
    public func pendingHangouts() async throws -> [PendingHangout] {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/hangouts"))
        return JSONFields.rows(try JSONFields.object(data)["hangouts"]).compactMap(PendingHangout.decode)
    }

    public func confirmHangout(id: String) async throws -> HangoutConfirmation {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/hangouts/\(id)/confirm", method: .post))
        let root = try JSONFields.object(data)
        return JSONFields.string(root["status"]) == "confirmed"
            ? .logged(alreadyLogged: root["already_logged"] as? Bool ?? false)
            : .waiting
    }

    public func declineHangout(id: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/hangouts/\(id)/decline", method: .post))
    }

    /// Returns false when you'd already waved at them today (nothing new was sent).
    public func wave(connectionID: String) async throws -> Bool {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/connections/\(connectionID)/wave", method: .post))
        return (try JSONFields.object(data)["sent"] as? Bool) ?? false
    }

    /// Hangout detection ping (only while the user has it turned on). Returns how many
    /// "hanging out?" prompts it started.
    @discardableResult
    public func reportPresence(_ coordinate: CLLocationCoordinate2D) async throws -> Int {
        let (data, _) = try await api.executeRaw(APIRequest(
            path: "/api/me/presence", method: .post,
            body: try json(["lat": coordinate.latitude, "lon": coordinate.longitude])
        ))
        return JSONFields.int(try JSONFields.object(data)["prompted"]) ?? 0
    }

    public func clearPresence() async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/me/presence", method: .delete, idempotent: true))
    }
}
