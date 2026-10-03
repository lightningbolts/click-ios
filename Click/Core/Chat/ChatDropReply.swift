import Foundation

/// A chat message that answers a shared Click Drop, Instagram-story style (`metadata.drop_reply`):
/// a typed reply, or a reaction whose (encrypted) text is the emoji. The drop is referenced by ID
/// only; each side loads its photo through its own access to it. Clients without this marker
/// show the plain text.
public struct ChatDropReply: Hashable, Sendable, Codable {
    public let dropID: String
    public let isReaction: Bool

    static let metadataKey = "drop_reply"

    public init(dropID: String, isReaction: Bool) {
        self.dropID = dropID
        self.isReaction = isReaction
    }

    var wire: [String: Any] { ["kind": "shared", "id": dropID, "reaction": isReaction] }

    static func parse(messageType: String, metadata: [String: Any]?) -> ChatDropReply? {
        guard messageType.lowercased() == "text",
              let reply = metadata?[metadataKey] as? [String: Any],
              JSONFields.string(reply["kind"]) == "shared",
              let id = JSONFields.string(reply["id"]), !id.isEmpty else { return nil }
        return ChatDropReply(dropID: id, isReaction: JSONFields.bool(reply["reaction"]) ?? false)
    }
}
