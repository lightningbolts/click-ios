import CoreLocation
import Foundation

/// "You met Maya near here in June" (spec F6, flag `reconnect_nearby`): a Home card when you're
/// back where you met someone 2+ weeks ago. Only a coarse position (~100 m) leaves the phone, and
/// the card only recalls the past meeting — never where anyone is now.
public struct ReconnectNearbyNudge: Identifiable, Sendable, Equatable {
    public let id: String
    public let connectionID: String
    public let userID: String
    public let name: String
    public let avatarURL: String?
    public let metAt: Date?
    public let placeName: String?
    public let title: String
    public let body: String
    /// Set when the meeting was at a listed Click Place (click-web spec 5.11).
    public var placeID: String? = nil
    public var placeSlug: String? = nil

    public var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    static func parse(_ root: [String: Any]) -> ReconnectNearbyNudge? {
        guard let row = JSONFields.dictionary(root["nudge"]), let id = JSONFields.string(row["id"]),
              let connectionID = JSONFields.string(row["connection_id"]) else { return nil }
        let user = JSONFields.dictionary(row["user"]) ?? [:]
        return ReconnectNearbyNudge(
            id: id,
            connectionID: connectionID,
            userID: JSONFields.string(user["id"]) ?? "",
            name: JSONFields.string(user["name"]) ?? "Someone",
            avatarURL: JSONFields.string(user["avatar_url"]),
            metAt: JSONFields.date(row["met_at"]),
            placeName: JSONFields.string(row["place_name"]),
            title: JSONFields.string(row["title"]) ?? "",
            body: JSONFields.string(row["body"]) ?? "",
            placeID: JSONFields.string(row["place_id"]),
            placeSlug: JSONFields.string(row["place_slug"])
        )
    }

    /// ~100 m: three decimal places, applied on the phone before anything is sent.
    public static func coarse(_ value: CLLocationDegrees) -> Double {
        (value * 1000).rounded() / 1000
    }
}

public enum ReconnectNearbyMute: String, Sendable { case person, place }

extension RelationshipRepository {
    public func reconnectNearby(at coordinate: CLLocationCoordinate2D) async throws -> ReconnectNearbyNudge? {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/nudges/reconnect", queryItems: [
            URLQueryItem(name: "lat", value: String(ReconnectNearbyNudge.coarse(coordinate.latitude))),
            URLQueryItem(name: "lng", value: String(ReconnectNearbyNudge.coarse(coordinate.longitude)))
        ]))
        return ReconnectNearbyNudge.parse(try JSONFields.object(data))
    }

    public func resolveReconnectNearby(id: String, acted: Bool, mute: ReconnectNearbyMute? = nil) async throws {
        var body: [String: Any] = ["action": acted ? "acted" : "dismissed"]
        if let mute { body["mute"] = mute.rawValue }
        _ = try await api.executeRaw(APIRequest(
            path: "/api/nudges/reconnect/\(id)",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: body),
            idempotent: true
        ))
    }
}
