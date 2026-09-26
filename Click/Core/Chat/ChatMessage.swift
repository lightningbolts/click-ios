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

/// Text for a `call_log` row. The caller writes the row (`metadata.call_state`: completed,
/// missed, declined; `duration_seconds`), so "outgoing" means this user placed the call.
enum CallLogFormatting {
    static func label(metadata: [String: Any]?, isOutgoing: Bool) -> String {
        switch JSONFields.string(metadata?["call_state"])?.lowercased() {
        case "missed": return isOutgoing ? "No answer" : "Missed call"
        case "declined": return isOutgoing ? "Call declined" : "Declined call"
        default:
            let seconds = JSONFields.int(metadata?["duration_seconds"]) ?? 0
            guard seconds > 0 else { return isOutgoing ? "Outgoing call" : "Incoming call" }
            let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
            return (isOutgoing ? "Outgoing call · " : "Incoming call · ") + Duration.seconds(seconds).formatted(.time(pattern: pattern))
        }
    }

    /// Missed and declined calls are drawn in the alert color.
    static func isUnanswered(_ label: String) -> Bool {
        !label.hasPrefix("Outgoing call") && !label.hasPrefix("Incoming call")
    }
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
    /// Who reacted (for the "who reacted" sheet); may be empty for older cached rows.
    public var userIDs: [String]

    public init(reactionType: String, count: Int, userReacted: Bool, userIDs: [String] = []) {
        self.reactionType = reactionType
        self.count = count
        self.userReacted = userReacted
        self.userIDs = userIDs
    }
}

public struct ChatMessageItem: Identifiable, Hashable, Sendable, Codable {
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
    /// Image, voice note, or file carried by this message.
    public var media: MessageMedia?
    /// Decrypted local copy (outgoing optimistic media, or after a download).
    public var localMediaURL: URL?
    /// A shared event/beacon card (`message_type: beacon`).
    public var beacon: SharedBeacon?
    /// The sender's client message ID (`metadata.client_message_id`). For our own messages it
    /// is the optimistic row's ID, kept after the server row replaces it.
    public var clientMessageID: String?
    /// Encrypting/uploading stage while an outgoing attachment is in flight (never persisted).
    public var uploadProgress: MediaUploadProgress?
    /// "Message deleted" placeholder (server tombstone or a realtime delete seen live).
    public var isDeleted = false
    /// `metadata.forwarded`: re-sent from another chat (shown as "Forwarded"). Optional so rows
    /// stored before it existed still decode.
    public var forwarded: Bool?
    public var isForwarded: Bool { forwarded == true }
    /// A hangout proposed in chat (`metadata.plan`).
    public var plan: HangoutPlan?

    /// Persisted fields (LocalStore). The local media path and upload progress are
    /// device/session-specific and never stored.
    private enum CodingKeys: String, CodingKey {
        case id, chatID, senderID, senderName, senderAvatarURL, content, rawContent, messageType
        case createdAt, deliveryStatus, isOutgoing, replyToID, replyToSnippet, replyToSenderName
        case reactions, isEdited, media, beacon, clientMessageID, isDeleted, forwarded, plan
    }

    /// The placeholder that replaces a deleted message in place.
    public func tombstoned() -> ChatMessageItem {
        var copy = ChatMessageItem(id: id, chatID: chatID, senderID: senderID, senderName: senderName,
                                   senderAvatarURL: senderAvatarURL, content: "", messageType: .text,
                                   createdAt: createdAt, deliveryStatus: deliveryStatus, isOutgoing: isOutgoing,
                                   clientMessageID: clientMessageID)
        copy.isDeleted = true
        return copy
    }

    public var isMedia: Bool { media != nil }

    /// View identity for the whole life of a message: the client ID when known, so swapping
    /// the optimistic row for the server row (or a refresh) never re-inserts the view.
    public var stableID: String { clientMessageID ?? id }

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
        isEdited: Bool = false,
        media: MessageMedia? = nil,
        localMediaURL: URL? = nil,
        beacon: SharedBeacon? = nil,
        clientMessageID: String? = nil,
        forwarded: Bool? = nil,
        plan: HangoutPlan? = nil
    ) {
        self.forwarded = forwarded
        self.plan = plan
        self.clientMessageID = clientMessageID
        self.beacon = beacon
        self.media = media
        self.localMediaURL = localMediaURL
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

/// The supported conversation kinds (spec §31.1). Common UI is shared; transport, encryption,
/// and access rules differ per kind and are owned by `ChatRepository`.
public enum ConversationKind: Hashable, Sendable {
    case direct
    case group(groupID: String)
    case hub(hubID: String)
}

public struct ConversationIdentity: Hashable, Sendable {
    /// Canonical chat UUID after the repository resolves the route. May begin as a connection ID.
    /// For hubs this is the hub ID (hub v2 envelopes bind to it).
    public var chatID: String
    public let connectionID: String?
    /// Direct chats only; empty for groups and hubs.
    public let peerUserID: String
    /// The peer's name for direct chats, otherwise the group or hub name.
    public let peerDisplayName: String
    public let peerHandle: String
    public let peerAvatarURL: String?
    public var isOnline: Bool
    public var lastActiveText: String
    public let kind: ConversationKind
    /// Group members (including the viewer). Hub participants are loaded with the timeline.
    public var participantUserIDs: [String]

    public init(
        chatID: String,
        connectionID: String? = nil,
        peerUserID: String,
        peerDisplayName: String,
        peerHandle: String = "",
        peerAvatarURL: String? = nil,
        isOnline: Bool = false,
        lastActiveText: String = "",
        kind: ConversationKind = .direct,
        participantUserIDs: [String] = []
    ) {
        self.chatID = chatID
        self.connectionID = connectionID
        self.peerUserID = peerUserID
        self.peerDisplayName = peerDisplayName
        self.peerHandle = peerHandle
        self.peerAvatarURL = peerAvatarURL
        self.isOnline = isOnline
        self.lastActiveText = lastActiveText
        self.kind = kind
        self.participantUserIDs = participantUserIDs
    }

    public var isDirect: Bool { kind == .direct }

    public var groupID: String? {
        if case .group(let id) = kind { return id }
        return nil
    }

    public var hubID: String? {
        if case .hub(let id) = kind { return id }
        return nil
    }

    /// Hubs have no read/delivery receipts (spec §62).
    public var supportsReceipts: Bool { hubID == nil }

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

/// Card data for a shared beacon/event (KMP `toBeaconChatMetadata`). The card metadata is
/// plaintext by design (public beacon fields only).
/// A proposed hangout sent into a chat (`metadata.plan`). The readable summary is the message
/// text (so any client shows it); RSVPs are reactions (✅ going, ❌ can't make it).
public struct HangoutPlan: Hashable, Sendable, Codable {
    public var title: String
    public var startsAt: Date
    public var placeName: String?
    public var latitude: Double?
    public var longitude: Double?

    public static let goingReaction = "✅"
    public static let declinedReaction = "❌"

    public init(title: String, startsAt: Date, placeName: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.title = title
        self.startsAt = startsAt
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The message text: readable anywhere, even where plans aren't understood.
    public var summary: String {
        let when = startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return "📅 \(title) · \(when)" + (placeName.map { " · 📍 \($0)" } ?? "")
    }

    var wire: [String: Any] {
        var plan: [String: Any] = ["title": title, "starts_at": Int64(startsAt.timeIntervalSince1970 * 1000)]
        if let placeName { plan["place_name"] = placeName }
        if let latitude, let longitude {
            plan["lat"] = latitude
            plan["lon"] = longitude
        }
        return plan
    }

    static func parse(metadata: [String: Any]?) -> HangoutPlan? {
        guard let plan = metadata?["plan"] as? [String: Any],
              let title = JSONFields.string(plan["title"]),
              let startsMs = JSONFields.double(plan["starts_at"]) else { return nil }
        return HangoutPlan(title: title, startsAt: Date(timeIntervalSince1970: startsMs / 1000),
                           placeName: JSONFields.string(plan["place_name"]),
                           latitude: JSONFields.double(plan["lat"]), longitude: JSONFields.double(plan["lon"]))
    }
}

public struct SharedBeacon: Hashable, Sendable, Codable {
    public let beaconID: String
    public let kind: BeaconKind
    public let title: String
    public let scheduleLabel: String?
    public let locationName: String?
    public let imageURL: String?
    public let start: Date?

    public var isEvent: Bool { kind == .event }

    static func parse(messageType: String, metadata: [String: Any]?, content: String) -> SharedBeacon? {
        guard let meta = metadata,
              let id = JSONFields.string(meta, "beacon_id", "beaconId"),
              messageType.lowercased() == "beacon" || !id.isEmpty else { return nil }
        let title = JSONFields.string(meta["title"])
            ?? content.replacingOccurrences(of: "Beacon:", with: "").trimmingCharacters(in: .whitespaces)
        return SharedBeacon(
            beaconID: id,
            kind: BeaconKind(raw: JSONFields.string(meta, "beacon_type", "beaconType")),
            title: title.isEmpty ? "Beacon" : title,
            scheduleLabel: JSONFields.string(meta, "schedule_label", "scheduleLabel"),
            locationName: JSONFields.string(meta, "location_name", "locationName"),
            imageURL: JSONFields.string(meta, "album_art_url", "image_url", "cover_url"),
            start: JSONFields.date(meta["event_start_at"])
        )
    }
}
