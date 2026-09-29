import Foundation

/// "Listening now" on a soundtrack beacon (spec F5, flag `soundtrack_presence`): a count of people
/// listening (from anywhere), with names only for your own connections. No likes, no rankings.
public struct ListeningNow: Sendable, Equatable {
    public struct Person: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let avatarURL: String?
    }

    public let count: Int
    public let isListening: Bool
    public let connections: [Person]
    /// How often a listener re-confirms while they stay (half the server's TTL).
    public let heartbeatSeconds: Int

    static func parse(_ root: [String: Any]) -> ListeningNow {
        ListeningNow(
            count: JSONFields.int(root["count"]) ?? 0,
            isListening: JSONFields.bool(root["is_listening"]) ?? false,
            connections: JSONFields.rows(root["connections"]).compactMap { row in
                guard let id = JSONFields.string(row["user_id"]) else { return nil }
                return Person(id: id, name: JSONFields.string(row["name"]) ?? "Someone", avatarURL: JSONFields.string(row["avatar_url"]))
            },
            heartbeatSeconds: max(60, JSONFields.int(root["heartbeat_seconds"]) ?? 360)
        )
    }

    /// "Maya is listening", "Maya and Sam are listening", "Maya and 3 others are listening".
    public var summary: String? {
        guard count > 0 else { return nil }
        let others = count - connections.count - (isListening ? 1 : 0)
        let names = connections.prefix(2).map(\.name)
        switch (names.count, others) {
        case (0, _):
            return isListening && count == 1 ? "You're listening here" : "\(count) listening now"
        case (1, ...0): return "\(names[0]) is listening"
        case (2, ...0): return "\(names[0]) and \(names[1]) are listening"
        default:
            let rest = count - names.count - (isListening ? 1 : 0)
            return "\(names.joined(separator: ", ")) and \(rest) other\(rest == 1 ? "" : "s") are listening"
        }
    }
}

extension BeaconRepository {
    public func listening(beaconID: String) async throws -> ListeningNow {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/listening"))
        return ListeningNow.parse(try JSONFields.object(data))
    }

    /// One heartbeat; repeat every `heartbeatSeconds` while listening. Works from anywhere:
    /// people listen on the map, not only at the pin.
    public func heartbeat(beaconID: String) async throws -> ListeningNow {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/listening", method: .post))
        return ListeningNow.parse(try JSONFields.object(data))
    }

    public func stopListening(beaconID: String) async throws -> ListeningNow {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/beacons/\(beaconID)/listening", method: .delete, idempotent: true))
        return ListeningNow.parse(try JSONFields.object(data))
    }
}
