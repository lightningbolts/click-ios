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

    public var unreadCount: Int { unread ?? 0 }
    public var isCore: Bool { core ?? false }

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
        isCore: Bool = false
    ) {
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
    public func with(unreadCount: Int? = nil, isCore: Bool? = nil) -> ConnectionItem {
        ConnectionItem(
            id: id, userID: userID, connectionID: connectionID, displayName: displayName,
            handle: handle, avatarUrl: avatarUrl, initials: initials, isOnline: isOnline,
            presenceKnown: presenceKnown, lastActiveRelative: lastActiveRelative,
            encounterLocation: encounterLocation, mutualTags: mutualTags,
            encounterCount: encounterCount, segment: segment, lastMessagePreview: lastMessagePreview,
            chatID: chatID, lastMessage: lastMessage, lastActivityAt: lastActivityAt,
            sayHiDeadline: sayHiDeadline, unreadCount: unreadCount ?? self.unreadCount,
            isCore: isCore ?? self.isCore
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

    public init(content: String, messageType: String, isOutgoing: Bool, isRead: Bool, isDisposable: Bool = false) {
        self.content = content
        self.messageType = messageType
        self.isOutgoing = isOutgoing
        self.isRead = isRead
        self.isDisposable = isDisposable
    }
}


public struct CliqueItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let chatID: String
    public let name: String
    public let memberCount: Int
    public let lastActiveRelative: String

    public init(
        id: String,
        chatID: String,
        name: String,
        memberCount: Int,
        lastActiveRelative: String = ""
    ) {
        self.id = id
        self.chatID = chatID
        self.name = name
        self.memberCount = memberCount
        self.lastActiveRelative = lastActiveRelative
    }

    public var initials: String {
        let words = name.split(separator: " ")
        let value = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "C" : value.uppercased()
    }
}

/// Snapshot representation of the Clicks tab.
public struct ClicksSnapshot: Codable, Equatable, Sendable {
    public let connections: [ConnectionItem]
    public let archivedConnections: [ConnectionItem]?
    public let groups: [CliqueItem]?

    public init(
        connections: [ConnectionItem],
        archivedConnections: [ConnectionItem]? = nil,
        groups: [CliqueItem]? = nil
    ) {
        self.connections = connections
        self.archivedConnections = archivedConnections
        self.groups = groups
    }

    public var archived: [ConnectionItem] { archivedConnections ?? [] }
    public var cliques: [CliqueItem] { groups ?? [] }

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
