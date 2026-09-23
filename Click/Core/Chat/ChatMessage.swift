import Foundation

/// Canonical Chat models for Click native iOS direct chat.
/// Aligned with `click-web/lib/chat/types.ts` and `compose.project.click.click.data.model.Message`.

public enum MessageType: String, Codable, Sendable {
    case text
    case image
    case audio
    case file
    case beacon
    case callLog = "call_log"
}

public enum MessageDeliveryStatus: String, Codable, Sendable {
    case pending
    case sending
    case sent
    case delivered
    case read
    case failed
}

public struct ReactionSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { reactionType }
    public let reactionType: String
    public var count: Int
    public var userReacted: Bool

    public init(reactionType: String, count: Int, userReacted: Bool) {
        self.reactionType = reactionType
        self.count = count
        self.userReacted = userReacted
    }
}

public struct ChatMessageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let chatID: String
    public let senderID: String
    public let senderName: String
    public let senderAvatarURL: String?
    public var content: String
    public let rawContent: String
    public let messageType: MessageType
    public let createdAt: Date
    public var deliveryStatus: MessageDeliveryStatus
    public let isOutgoing: Bool
    public var replyToID: String?
    public var replyToSnippet: String?
    public var replyToSenderName: String?
    public var reactions: [ReactionSummary]
    public var isEdited: Bool

    public init(
        id: String,
        chatID: String,
        senderID: String,
        senderName: String,
        senderAvatarURL: String? = nil,
        content: String,
        rawContent: String? = nil,
        messageType: MessageType = .text,
        createdAt: Date = Date(),
        deliveryStatus: MessageDeliveryStatus = .sent,
        isOutgoing: Bool,
        replyToID: String? = nil,
        replyToSnippet: String? = nil,
        replyToSenderName: String? = nil,
        reactions: [ReactionSummary] = [],
        isEdited: Bool = false
    ) {
        self.id = id
        self.chatID = chatID
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.content = content
        self.rawContent = rawContent ?? content
        self.messageType = messageType
        self.createdAt = createdAt
        self.deliveryStatus = deliveryStatus
        self.isOutgoing = isOutgoing
        self.replyToID = replyToID
        self.replyToSnippet = replyToSnippet
        self.replyToSenderName = replyToSenderName
        self.reactions = reactions
        self.isEdited = isEdited
    }

    public var formattedTime: String {
        createdAt.formatted(date: .omitted, time: .shortened)
    }
}

public struct ConversationIdentity: Hashable, Sendable {
    /// Canonical chat UUID after the repository resolves the route. May begin as a connection ID.
    public var chatID: String
    public let connectionID: String?
    public let peerUserID: String
    public let peerDisplayName: String
    public let peerHandle: String
    public let peerAvatarURL: String?
    public var isOnline: Bool
    public var lastActiveText: String

    public init(
        chatID: String,
        connectionID: String? = nil,
        peerUserID: String,
        peerDisplayName: String,
        peerHandle: String = "",
        peerAvatarURL: String? = nil,
        isOnline: Bool = false,
        lastActiveText: String = ""
    ) {
        self.chatID = chatID
        self.connectionID = connectionID
        self.peerUserID = peerUserID
        self.peerDisplayName = peerDisplayName
        self.peerHandle = peerHandle
        self.peerAvatarURL = peerAvatarURL
        self.isOnline = isOnline
        self.lastActiveText = lastActiveText
    }

    public var initials: String {
        let parts = peerDisplayName.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        } else if let first = parts.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}
