import Foundation

/// Reactions on soundtracks and shared drops (Locket-style): one emoji per person, replaceable.
/// The server decides who may react and whose reactions a viewer sees (owners see everyone).
public enum ReactionTarget: String, Sendable {
    case soundtrack
    case sharedDrop = "shared_drop"
}

public struct ReactionsState: Sendable, Equatable {
    public struct Reaction: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let avatarURL: String?
        public let emoji: String
    }

    /// The fixed palette (matches the server's allowlist).
    public static let palette = ["❤️", "🔥", "😂", "😍", "👏", "😮"]

    public var mine: String?
    public let reactions: [Reaction]
    public let isOwner: Bool

    /// Nothing reacted yet, as a non-owner sees it (the palette shown while reactions load).
    static let empty = ReactionsState(mine: nil, reactions: [], isOwner: false)

    static func parse(_ root: [String: Any]) -> ReactionsState {
        ReactionsState(
            mine: JSONFields.string(root["mine"]),
            reactions: JSONFields.rows(root["reactions"]).compactMap { row in
                guard let id = JSONFields.string(row["user_id"]), let emoji = JSONFields.string(row["emoji"]) else { return nil }
                return Reaction(id: id, name: JSONFields.string(row["name"]) ?? "Someone",
                                avatarURL: JSONFields.string(row["avatar_url"]), emoji: emoji)
            },
            isOwner: JSONFields.bool(root["is_owner"]) ?? false
        )
    }
}

extension ClickDropService {
    public func reactions(_ target: ReactionTarget, id: String) async throws -> ReactionsState {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/reactions/\(target.rawValue)/\(id)"))
        return ReactionsState.parse(try JSONFields.object(data))
    }

    /// `nil` takes your reaction back.
    public func react(_ target: ReactionTarget, id: String, emoji: String?) async throws -> ReactionsState {
        let (data, _) = try await api.executeRaw(APIRequest(
            path: "/api/reactions/\(target.rawValue)/\(id)",
            method: .put,
            body: try JSONSerialization.data(withJSONObject: ["emoji": emoji.map { $0 as Any } ?? NSNull()]),
            idempotent: true
        ))
        return ReactionsState.parse(try JSONFields.object(data))
    }
}
