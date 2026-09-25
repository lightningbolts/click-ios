import Foundation

/// Filter segment choices for the Clicks directory tab.
public enum ConnectionSegment: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "All"
    case active = "Active"
    case encounters = "Encounters"
    case circles = "Circles"

    public var id: String { rawValue }
}

/// A connection record rendered within the Clicks directory.
public struct ConnectionItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let userID: String
    public let connectionID: String
    public let displayName: String
    public let handle: String
    public let avatarUrl: String?
    public let initials: String
    public let isOnline: Bool
    public let presenceKnown: Bool
    public let lastActiveRelative: String
    public let encounterLocation: String
    public let mutualTags: [String]
    public let encounterCount: Int
    public let segment: ConnectionSegment
    public let lastMessagePreview: String?

    // Inbox state. Optional so snapshots cached by earlier builds still decode.
    public let chatID: String?
    public let lastMessage: InboxLastMessage?
    public let lastActivityAt: Date?
    public let sayHiDeadline: Date?
    private let unread: Int?
    private let core: Bool?
    /// A pending self-reported "we already know each other" request that this user must
    /// accept or decline (`source = prior`, viewer is not the initiator).
    private let priorPending: Bool?

    public var unreadCount: Int { unread ?? 0 }
    public var isCore: Bool { core ?? false }
    public var awaitsPriorResponse: Bool { priorPending ?? false }

    public init(
        id: String,
        userID: String = "",
        connectionID: String = "",
        displayName: String,
        handle: String,
        avatarUrl: String? = nil,
        initials: String,
        isOnline: Bool,
        presenceKnown: Bool = true,
        lastActiveRelative: String,
        encounterLocation: String,
        mutualTags: [String] = [],
        encounterCount: Int = 0,
        segment: ConnectionSegment = .all,
        lastMessagePreview: String? = nil,
        chatID: String? = nil,
        lastMessage: InboxLastMessage? = nil,
        lastActivityAt: Date? = nil,
        sayHiDeadline: Date? = nil,
        unreadCount: Int = 0,
        isCore: Bool = false,
        awaitsPriorResponse: Bool = false
    ) {
        self.priorPending = awaitsPriorResponse
        self.id = id
        self.userID = userID
        self.connectionID = connectionID
        self.displayName = displayName
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.initials = initials
        self.isOnline = isOnline
        self.presenceKnown = presenceKnown
        self.lastActiveRelative = lastActiveRelative
        self.encounterLocation = encounterLocation
        self.mutualTags = mutualTags
        self.encounterCount = encounterCount
        self.segment = segment
        self.lastMessagePreview = lastMessagePreview
        self.chatID = chatID
        self.lastMessage = lastMessage
        self.lastActivityAt = lastActivityAt
        self.sayHiDeadline = sayHiDeadline
        self.unread = unreadCount
        self.core = isCore
    }

    /// Returns a copy with inbox-local state changed (optimistic updates).
    public func with(
        unreadCount: Int? = nil,
        isCore: Bool? = nil,
        lastMessage: InboxLastMessage? = nil,
        lastActivityAt: Date? = nil
    ) -> ConnectionItem {
        ConnectionItem(
            id: id, userID: userID, connectionID: connectionID, displayName: displayName,
            handle: handle, avatarUrl: avatarUrl, initials: initials, isOnline: isOnline,
            presenceKnown: presenceKnown, lastActiveRelative: lastActiveRelative,
            encounterLocation: encounterLocation, mutualTags: mutualTags,
            encounterCount: encounterCount, segment: segment, lastMessagePreview: lastMessagePreview,
            chatID: chatID, lastMessage: lastMessage ?? self.lastMessage, lastActivityAt: lastActivityAt ?? self.lastActivityAt,
            sayHiDeadline: sayHiDeadline, unreadCount: unreadCount ?? self.unreadCount,
            isCore: isCore ?? self.isCore, awaitsPriorResponse: awaitsPriorResponse
        )
    }
}

extension ConnectionItem {
    /// Fills enrichment the latest refresh couldn't fetch (names/avatars or the inbox preview)
    /// from the previously known row, so a transient failure never caches "Click user" rows
    /// without chat IDs or unread counts.
    func filling(from previous: ConnectionItem?, identityMissing: Bool, previewMissing: Bool) -> ConnectionItem {
        guard let previous, identityMissing || previewMissing else { return self }
        return ConnectionItem(
            id: id, userID: userID, connectionID: connectionID,
            displayName: identityMissing ? previous.displayName : displayName,
            handle: handle,
            avatarUrl: identityMissing ? previous.avatarUrl : avatarUrl,
            initials: identityMissing ? previous.initials : initials,
            isOnline: isOnline, presenceKnown: presenceKnown, lastActiveRelative: lastActiveRelative,
            encounterLocation: encounterLocation, mutualTags: mutualTags, encounterCount: encounterCount,
            segment: segment, lastMessagePreview: lastMessagePreview,
            chatID: previewMissing ? (chatID ?? previous.chatID) : chatID,
            lastMessage: previewMissing ? (lastMessage ?? previous.lastMessage) : lastMessage,
            lastActivityAt: previewMissing ? max(lastActivityAt ?? .distantPast, previous.lastActivityAt ?? .distantPast) : lastActivityAt,
            sayHiDeadline: sayHiDeadline,
            unreadCount: previewMissing ? previous.unreadCount : unreadCount,
            isCore: isCore, awaitsPriorResponse: awaitsPriorResponse
        )
    }
}

/// The newest message of a direct conversation, as returned by `get_inbox_previews`.
/// `content` is the wire value — ciphertext for encrypted chats — so it is safe to cache;
/// decrypted preview text is only ever held in memory.
public struct InboxLastMessage: Codable, Equatable, Sendable {
    public let content: String
    public let messageType: String
    public let isOutgoing: Bool
    public let isRead: Bool
    public let isDisposable: Bool
    /// Group rows prefix incoming previews with the sender ("Lena: …").
    public var senderName: String? = nil

    public init(content: String, messageType: String, isOutgoing: Bool, isRead: Bool, isDisposable: Bool = false, senderName: String? = nil) {
        self.senderName = senderName
        self.content = content
        self.messageType = messageType
        self.isOutgoing = isOutgoing
        self.isRead = isRead
        self.isDisposable = isDisposable
    }
}


/// A verified group (clique) in the inbox. `id` is the group ID; `chatID` its chat.
/// Newer fields are optional so snapshots cached by earlier builds still decode.
public struct CliqueItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let chatID: String
    public let name: String
    public let memberCount: Int
    public let lastActiveRelative: String
    public let createdBy: String?
    public let avatarURL: String?
    private let memberList: [GroupMember]?
    public let lastActivityAt: Date?
    public let lastMessage: InboxLastMessage?
    private let unread: Int?

    public init(
        id: String,
        chatID: String,
        name: String,
        memberCount: Int,
        lastActiveRelative: String = "",
        createdBy: String? = nil,
        avatarURL: String? = nil,
        members: [GroupMember] = [],
        lastActivityAt: Date? = nil,
        lastMessage: InboxLastMessage? = nil,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.chatID = chatID
        self.name = name
        self.memberCount = memberCount
        self.lastActiveRelative = lastActiveRelative
        self.createdBy = createdBy
        self.avatarURL = avatarURL
        self.memberList = members
        self.lastActivityAt = lastActivityAt
        self.lastMessage = lastMessage
        self.unread = unreadCount
    }

    public var members: [GroupMember] { memberList ?? [] }
    public var unreadCount: Int { unread ?? 0 }

    public var initials: String {
        let words = name.split(separator: " ")
        let value = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "G" : value.uppercased()
    }

    public var chatRoute: GroupChatRoute {
        GroupChatRoute(chatID: chatID, groupID: id, name: name, avatarURL: avatarURL, memberUserIDs: members.map(\.userID))
    }

    public func with(unreadCount: Int, lastMessage: InboxLastMessage? = nil, lastActivityAt: Date? = nil) -> CliqueItem {
        CliqueItem(
            id: id, chatID: chatID, name: name, memberCount: memberCount, lastActiveRelative: lastActiveRelative,
            createdBy: createdBy, avatarURL: avatarURL, members: members,
            lastActivityAt: lastActivityAt ?? self.lastActivityAt,
            lastMessage: lastMessage ?? self.lastMessage, unreadCount: unreadCount
        )
    }
}

/// One map pin per peer (spec §50): stored `geo_location`, else the first-meet (origin)
/// encounter GPS — never the latest encounter, so reconnects do not move or duplicate pins.
public struct ConnectionPin: Codable, Equatable, Identifiable, Sendable {
    public let connectionID: String
    public let userID: String
    public let displayName: String
    public let avatarURL: String?
    public let latitude: Double
    public let longitude: Double
    public let locationName: String?
    public let isCore: Bool

    public var id: String { userID }
    public var initials: String { Phase3Repository.initials(from: displayName) }
}

/// Snapshot representation of the Clicks tab.
public struct ClicksSnapshot: Codable, Equatable, Sendable {
    public let connections: [ConnectionItem]
    public let archivedConnections: [ConnectionItem]?
    public let groups: [CliqueItem]?
    /// Map pins from the same dashboard bundle (`map`: every non-hidden connection).
    public let mapPins: [ConnectionPin]?

    public init(
        connections: [ConnectionItem],
        archivedConnections: [ConnectionItem]? = nil,
        groups: [CliqueItem]? = nil,
        mapPins: [ConnectionPin]? = nil
    ) {
        self.connections = connections
        self.archivedConnections = archivedConnections
        self.groups = groups
        self.mapPins = mapPins
    }

    public var archived: [ConnectionItem] { archivedConnections ?? [] }
    public var cliques: [CliqueItem] { groups ?? [] }
    public var pins: [ConnectionPin] { mapPins ?? [] }

    public func filtered(by segment: ConnectionSegment, query: String = "") -> [ConnectionItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connections.filter { item in
            let matchesSegment: Bool = {
                switch segment {
                case .all:
                    return true
                case .active:
                    return item.isOnline
                        || item.lastActiveRelative.contains("Just now")
                        || item.lastActiveRelative.contains("m ago")
                        || item.lastActiveRelative.contains("1h ago")
                case .encounters:
                    return item.encounterCount > 0 || !item.encounterLocation.isEmpty
                case .circles:
                    return item.segment == .circles
                }
            }()

            guard matchesSegment else { return false }
            if cleanQuery.isEmpty { return true }
            return item.displayName.lowercased().contains(cleanQuery)
                || item.handle.lowercased().contains(cleanQuery)
                || item.encounterLocation.lowercased().contains(cleanQuery)
                || item.mutualTags.contains { $0.lowercased().contains(cleanQuery) }
        }
    }
}

extension ClicksSnapshot {
    public static var preview: ClicksSnapshot {
        ClicksSnapshot(
            connections: [
                ConnectionItem(
                    id: "conn_marcus",
                    userID: "usr_marcus",
                    connectionID: "conn_marcus",
                    displayName: "Marcus Vance",
                    handle: "@marcusv",
                    initials: "MV",
                    isOnline: true,
                    lastActiveRelative: "Active now",
                    encounterLocation: "Sightglass Coffee",
                    mutualTags: ["Coffee", "Producing", "Synthesizers"],
                    encounterCount: 3,
                    lastMessage: InboxLastMessage(content: "", messageType: "audio", isOutgoing: false, isRead: false),
                    lastActivityAt: Date().addingTimeInterval(-12 * 60),
                    unreadCount: 2,
                    isCore: true
                ),
                ConnectionItem(
                    id: "conn_elena",
                    userID: "usr_elena",
                    connectionID: "conn_elena",
                    displayName: "Elena Rostova",
                    handle: "@erostova",
                    initials: "ER",
                    isOnline: true,
                    lastActiveRelative: "5m ago",
                    encounterLocation: "Mission Climbing Gym",
                    mutualTags: ["Bouldering", "Hiking", "Techno"],
                    encounterCount: 2,
                    lastMessage: InboxLastMessage(content: "lifesaver. coffee on me", messageType: "text", isOutgoing: true, isRead: true),
                    lastActivityAt: Date().addingTimeInterval(-26 * 3600),
                    isCore: true
                ),
                ConnectionItem(
                    id: "conn_sam",
                    userID: "usr_sam",
                    connectionID: "conn_sam",
                    displayName: "Samira Khan",
                    handle: "@samirak",
                    initials: "SK",
                    isOnline: false,
                    lastActiveRelative: "2h ago",
                    encounterLocation: "Dolores Park Sunset",
                    mutualTags: ["Film Photography", "Reading", "Philosophy"],
                    encounterCount: 1,
                    lastMessage: InboxLastMessage(content: "see you at hack night!", messageType: "text", isOutgoing: true, isRead: false),
                    lastActivityAt: Date().addingTimeInterval(-3 * 86_400)
                ),
                ConnectionItem(
                    id: "conn_jordan",
                    userID: "usr_jordan",
                    connectionID: "conn_jordan",
                    displayName: "Jordan Reed",
                    handle: "@jreed",
                    initials: "JR",
                    isOnline: false,
                    lastActiveRelative: "Yesterday",
                    encounterLocation: "Crypto Corner Meetup",
                    mutualTags: ["Hardware", "Rust", "Startups"],
                    encounterCount: 1,
                    lastActivityAt: Date().addingTimeInterval(-2 * 3600),
                    sayHiDeadline: Date().addingTimeInterval(36 * 3600)
                ),
                ConnectionItem(
                    id: "conn_chloe",
                    userID: "usr_chloe",
                    connectionID: "conn_chloe",
                    displayName: "Chloe Lin",
                    handle: "@chloelin",
                    initials: "CL",
                    isOnline: true,
                    lastActiveRelative: "Active now",
                    encounterLocation: "SF Jazz Center",
                    mutualTags: ["Live Shows", "Jazz", "Piano"],
                    encounterCount: 4
                ),
                ConnectionItem(
                    id: "cir_dogpatch",
                    userID: "",
                    connectionID: "cir_dogpatch",
                    displayName: "Dogpatch Boulders Circle",
                    handle: "@dogpatch-climb",
                    initials: "DB",
                    isOnline: true,
                    lastActiveRelative: "12 members",
                    encounterLocation: "Dogpatch Boulders",
                    mutualTags: ["Bouldering", "Training"],
                    segment: .circles
                )
            ]
        )
    }
}
