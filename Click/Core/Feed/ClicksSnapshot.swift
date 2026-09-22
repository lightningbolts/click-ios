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
    public let displayName: String
    public let handle: String
    public let avatarUrl: String?
    public let initials: String
    public let isOnline: Bool
    public let lastActiveRelative: String
    public let encounterLocation: String
    public let mutualTags: [String]
    public let segment: ConnectionSegment

    public init(
        id: String,
        displayName: String,
        handle: String,
        avatarUrl: String? = nil,
        initials: String,
        isOnline: Bool,
        lastActiveRelative: String,
        encounterLocation: String,
        mutualTags: [String] = [],
        segment: ConnectionSegment = .all
    ) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.initials = initials
        self.isOnline = isOnline
        self.lastActiveRelative = lastActiveRelative
        self.encounterLocation = encounterLocation
        self.mutualTags = mutualTags
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
                    return item.isOnline || item.lastActiveRelative.contains("m ago") || item.lastActiveRelative.contains("1h ago")
                case .encounters:
                    return !item.encounterLocation.isEmpty
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
                    id: "usr_marcus",
                    displayName: "Marcus Vance",
                    handle: "@marcusv",
                    initials: "MV",
                    isOnline: true,
                    lastActiveRelative: "Active now",
                    encounterLocation: "Sightglass Coffee",
                    mutualTags: ["Coffee", "Producing", "Synthesizers"],
                    segment: .all
                ),
                ConnectionItem(
                    id: "usr_elena",
                    displayName: "Elena Rostova",
                    handle: "@erostova",
                    initials: "ER",
                    isOnline: true,
                    lastActiveRelative: "5m ago",
                    encounterLocation: "Mission Climbing Gym",
                    mutualTags: ["Bouldering", "Hiking", "Techno"],
                    segment: .active
                ),
                ConnectionItem(
                    id: "usr_sam",
                    displayName: "Samira Khan",
                    handle: "@samirak",
                    initials: "SK",
                    isOnline: false,
                    lastActiveRelative: "2h ago",
                    encounterLocation: "Dolores Park Sunset",
                    mutualTags: ["Film Photography", "Reading", "Philosophy"],
                    segment: .encounters
                ),
                ConnectionItem(
                    id: "usr_jordan",
                    displayName: "Jordan Reed",
                    handle: "@jreed",
                    initials: "JR",
                    isOnline: false,
                    lastActiveRelative: "Yesterday",
                    encounterLocation: "Crypto Corner Meetup",
                    mutualTags: ["Hardware", "Rust", "Startups"],
                    segment: .all
                ),
                ConnectionItem(
                    id: "usr_chloe",
                    displayName: "Chloe Lin",
                    handle: "@chloelin",
                    initials: "CL",
                    isOnline: true,
                    lastActiveRelative: "Active now",
                    encounterLocation: "SF Jazz Center",
                    mutualTags: ["Live Shows", "Jazz", "Piano"],
                    segment: .active
                ),
                ConnectionItem(
                    id: "cir_dogpatch",
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
