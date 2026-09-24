import Foundation

/// A community or event hub as the server describes it (`GET /api/hub/{id}`).
public struct HubInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String?
    public let creatorID: String?
    public let eventBeaconID: String?

    public var isEventHub: Bool { eventBeaconID != nil }
}

/// Bounded outcomes of the canonical event-chat resolver (spec §56.2.1).
public enum EventChatResolution: Equatable, Sendable {
    case ready(hubID: String, title: String, creatorID: String?)
    case requiresRSVP
    case unavailable
    case notReady
    case ended
    case failed(String)
}

/// Hub lifecycle (spec §61). Access policy (geofence, RSVP, check-in, host) is decided by the
/// server; this repository only carries evidence and maps the answers.
public actor HubRepository {
    private let api: ClickAPIClient
    private let supabaseURL: URL?
    private let supabaseAnonKey: String

    public init(api: ClickAPIClient, supabaseURL: URL?, supabaseAnonKey: String) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    public func hub(id: String) async throws -> HubInfo {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/hub/\(id)", method: .get))
        guard let row = JSONFields.dictionary(try JSONFields.object(data)["hub"]) else { throw APIError.decoding }
        return HubInfo(
            id: JSONFields.string(row["id"]) ?? id,
            name: JSONFields.string(row["name"]) ?? "Hub",
            category: JSONFields.string(row["category"]),
            creatorID: JSONFields.string(row["creator_id"]),
            eventBeaconID: JSONFields.string(row["event_beacon_id"])
        )
    }

    /// Event hubs join through click-web (RSVP/check-in/host); standalone hubs through the
    /// `verify-hub-proximity` Edge Function with a fresh fix (KMP `HubConnectionManager`).
    public func join(hubID: String, isEventHub: Bool, coordinates: (latitude: Double, longitude: Double)?) async throws {
        do {
            if isEventHub {
                let body = try JSONSerialization.data(withJSONObject: ["hub_id": hubID])
                _ = try await api.executeRaw(APIRequest(path: "/api/hub/join", method: .post, body: body))
                return
            }
            guard let coordinates else { throw HubChatError.locationRequired }
            guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
            let body = try JSONSerialization.data(withJSONObject: [
                "hub_id": hubID, "user_lat": coordinates.latitude, "user_long": coordinates.longitude
            ])
            _ = try await api.executeRaw(APIRequest(
                baseURL: supabaseURL,
                path: "/functions/v1/verify-hub-proximity",
                method: .post,
                headers: ["apikey": supabaseAnonKey],
                body: body
            ))
        } catch {
            throw HubChatError.map(error)
        }
    }

    /// `POST /api/hub/create` — a permanent community hub at the creator's location.
    /// The creator is added as a participant by the server. Returns the new hub ID.
    public func create(name: String, category: String, latitude: Double, longitude: Double, radiusMeters: Int = 50) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "category": category,
            "location": ["latitude": latitude, "longitude": longitude, "radius_meters": radiusMeters]
        ])
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/hub/create", method: .post, body: body))
        guard let id = JSONFields.string(try JSONFields.object(data)["hub_id"]) else { throw APIError.decoding }
        return id
    }

    public func leave(hubID: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/hub/\(hubID)/participants/me", method: .delete))
    }

    public func rename(hubID: String, to name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await api.executeRaw(APIRequest(path: "/api/hub/\(hubID)", method: .patch, body: body))
    }

    public func delete(hubID: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/hub/\(hubID)", method: .delete))
    }

    public enum LatestResult: Sendable {
        case message(text: String, senderName: String?, date: Date?)
        case empty
        /// The server says the hub is gone or no longer accessible to this user.
        case gone
    }

    /// Newest hub message for the Groups list. v2 bodies are not decrypted here (no key
    /// fetch while listing), so they read as "Encrypted message".
    public func latest(hubID: String) async -> LatestResult? {
        do {
            let (data, _) = try await api.executeRaw(APIRequest(
                path: "/api/hub/messages",
                method: .get,
                queryItems: [URLQueryItem(name: "hubId", value: hubID), URLQueryItem(name: "limit", value: "1")]
            ))
            guard let row = JSONFields.rows(try JSONFields.object(data)["messages"]).last else { return .empty }
            let body = JSONFields.string(row["body"]) ?? ""
            let type = JSONFields.string(row["message_type"]) ?? "text"
            let text: String
            switch type {
            case "image": text = "Photo"
            case "audio": text = "Voice note"
            case "file": text = "File"
            default: text = ClickCryptoV2.isEncrypted(body) || ClickCryptoV1.isAnyV1WireContent(body) ? "Encrypted message" : body
            }
            var sender: String?
            if let userID = JSONFields.string(row["user_id"]),
               let payload = try? JSONSerialization.data(withJSONObject: ["userIds": [userID]]),
               let (names, _) = try? await api.executeRaw(APIRequest(path: "/api/users/display-names", method: .post, body: payload)),
               let root = try? JSONFields.object(names) {
                sender = (root["names"] as? [String: Any]).flatMap { JSONFields.string($0[userID]) }
            }
            return .message(text: text, senderName: sender, date: JSONFields.date(row["created_at"]))
        } catch {
            switch error as? APIError {
            case .forbidden, .notFound, .server(410, _, _): return .gone
            default: return nil
            }
        }
    }

    /// `GET /api/beacons/{id}/event-chat`. Never trusts a cached hub ID from event metadata.
    public func resolveEventChat(beaconID: String) async -> EventChatResolution {
        do {
            let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/event-chat", method: .get))
            let root = try JSONFields.object(data)
            guard let hubID = JSONFields.string(root["hub_id"]) else { return .failed("Couldn't open this event chat.") }
            return .ready(
                hubID: hubID,
                title: JSONFields.string(root["title"]) ?? "Event",
                creatorID: JSONFields.string(root["creator_id"])
            )
        } catch {
            return Self.resolution(for: error)
        }
    }

    static func resolution(for error: Error) -> EventChatResolution {
        switch error as? APIError {
        case .forbidden: .requiresRSVP
        case .notFound: .unavailable
        case .conflict: .notReady
        case .server(410, _, _): .ended
        default: .failed(error.userFacingMessage)
        }
    }
}
