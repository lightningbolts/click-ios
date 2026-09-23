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
        segment: ConnectionSegment = .all
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
    }
}

/// Snapshot representation of the Clicks tab.
public struct ClicksSnapshot: Codable, Equatable, Sendable {
    public let connections: [ConnectionItem]

    public init(connections: [ConnectionItem]) {
        self.connections = connections
    }

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
                    encounterCount: 3
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
                    encounterCount: 2
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
                    encounterCount: 1
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
                    encounterCount: 1
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
