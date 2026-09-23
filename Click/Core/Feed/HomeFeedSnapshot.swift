import Foundation

/// Snapshot representation of the Home tab data state.
public struct HomeFeedSnapshot: Codable, Equatable, Sendable {
    public let greetingName: String
    public let greetingSubtitle: String
    public let intents: [AvailabilityIntent]
    public let featuredEvent: HomeFeaturedEvent?
    public let nearbyBeacons: [ExploreBeaconItem]
    public let recentConnections: [RecentConnectionSummary]
    public let stats: HomeStats

    public init(
        greetingName: String,
        greetingSubtitle: String = "Ready to connect today?",
        intents: [AvailabilityIntent],
        featuredEvent: HomeFeaturedEvent?,
        nearbyBeacons: [ExploreBeaconItem],
        recentConnections: [RecentConnectionSummary],
        stats: HomeStats
    ) {
        self.greetingName = greetingName
        self.greetingSubtitle = greetingSubtitle
        self.intents = intents
        self.featuredEvent = featuredEvent
        self.nearbyBeacons = nearbyBeacons
        self.recentConnections = recentConnections
        self.stats = stats
    }

    public static func timeBasedSalutation(for name: String, date: Date = Date()) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let prefix: String
        switch hour {
        case 5..<12:
            prefix = "Good morning"
        case 12..<17:
            prefix = "Good afternoon"
        case 17..<22:
            prefix = "Good evening"
        default:
            prefix = "Hello"
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanName.isEmpty ? "\(prefix)." : "\(prefix), \(cleanName)."
    }
}

public struct AvailabilityIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let emoji: String
    public let label: String
    public var isSelected: Bool

    public init(id: String, emoji: String, label: String, isSelected: Bool = false) {
        self.id = id
        self.emoji = emoji
        self.label = label
        self.isSelected = isSelected
    }
}

public struct HomeFeaturedEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let timeDescription: String
    public let locationName: String
    public let category: String
    public let attendeeCount: Int

    public init(
        id: String,
        title: String,
        timeDescription: String,
        locationName: String,
        category: String,
        attendeeCount: Int
    ) {
        self.id = id
        self.title = title
        self.timeDescription = timeDescription
        self.locationName = locationName
        self.category = category
        self.attendeeCount = attendeeCount
    }
}

public struct ExploreBeaconItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let iconName: String
    public let distanceFormatted: String
    public let memberCount: Int

    public init(
        id: String,
        title: String,
        subtitle: String,
        iconName: String,
        distanceFormatted: String,
        memberCount: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.distanceFormatted = distanceFormatted
        self.memberCount = memberCount
    }
}

public struct RecentConnectionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let userID: String
    public let connectionID: String
    public let displayName: String
    public let handle: String
    public let avatarUrl: String?
    public let initials: String
    public let encounterLocation: String
    public let lastActiveRelative: String
    public let isOnline: Bool
    public let presenceKnown: Bool

    public init(
        id: String,
        userID: String = "",
        connectionID: String = "",
        displayName: String,
        handle: String,
        avatarUrl: String? = nil,
        initials: String,
        encounterLocation: String,
        lastActiveRelative: String,
        isOnline: Bool,
        presenceKnown: Bool = true
    ) {
        self.id = id
        self.userID = userID
        self.connectionID = connectionID
        self.displayName = displayName
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.initials = initials
        self.encounterLocation = encounterLocation
        self.lastActiveRelative = lastActiveRelative
        self.isOnline = isOnline
        self.presenceKnown = presenceKnown
    }
}

public struct HomeStats: Codable, Equatable, Sendable {
    public let totalClicks: Int
    public let totalEncounters: Int
    public let totalCircles: Int

    public init(totalClicks: Int, totalEncounters: Int, totalCircles: Int) {
        self.totalClicks = totalClicks
        self.totalEncounters = totalEncounters
        self.totalCircles = totalCircles
    }
}

extension HomeFeedSnapshot {
    public static var preview: HomeFeedSnapshot {
        HomeFeedSnapshot(
            greetingName: "Alex",
            greetingSubtitle: "Ready to connect today?",
            intents: [
                AvailabilityIntent(id: "coffee", emoji: "☕️", label: "Coffee", isSelected: true),
                AvailabilityIntent(id: "working", emoji: "💻", label: "Co-working", isSelected: true),
                AvailabilityIntent(id: "bouldering", emoji: "🧗", label: "Climbing", isSelected: false),
                AvailabilityIntent(id: "shows", emoji: "🎵", label: "Live shows", isSelected: false),
                AvailabilityIntent(id: "dinner", emoji: "🍕", label: "Grab food", isSelected: false)
            ],
            featuredEvent: HomeFeaturedEvent(
                id: "ev_sunset_acoustic",
                title: "Sunset Acoustic Session & Vinyl Night",
                timeDescription: "Tonight · 7:00 PM",
                locationName: "SoMa Arts Collective",
                category: "Live Music",
                attendeeCount: 18
            ),
            nearbyBeacons: [
                ExploreBeaconItem(
                    id: "bc_blue_bottle",
                    title: "Blue Bottle Coffee",
                    subtitle: "Active Click Beacon",
                    iconName: "cup.and.saucer.fill",
                    distanceFormatted: "0.2 mi",
                    memberCount: 5
                ),
                ExploreBeaconItem(
                    id: "bc_dogpatch_climb",
                    title: "Dogpatch Boulders",
                    subtitle: "Weekend Circle",
                    iconName: "figure.climbing",
                    distanceFormatted: "0.8 mi",
                    memberCount: 12
                ),
                ExploreBeaconItem(
                    id: "bc_sf_tech",
                    title: "Hardware Hackers Bay Area",
                    subtitle: "Community Hub",
                    iconName: "wrench.and.screwdriver.fill",
                    distanceFormatted: "1.4 mi",
                    memberCount: 42
                )
            ],
            recentConnections: [
                RecentConnectionSummary(
                    id: "usr_marcus",
                    displayName: "Marcus Vance",
                    handle: "@marcusv",
                    initials: "MV",
                    encounterLocation: "Sightglass Coffee",
                    lastActiveRelative: "12m ago",
                    isOnline: true
                ),
                RecentConnectionSummary(
                    id: "usr_elena",
                    displayName: "Elena Rostova",
                    handle: "@erostova",
                    initials: "ER",
                    encounterLocation: "Mission Climbing Gym",
                    lastActiveRelative: "1h ago",
                    isOnline: true
                ),
                RecentConnectionSummary(
                    id: "usr_sam",
                    displayName: "Samira Khan",
                    handle: "@samirak",
                    initials: "SK",
                    encounterLocation: "Dolores Park",
                    lastActiveRelative: "3h ago",
                    isOnline: false
                ),
                RecentConnectionSummary(
                    id: "usr_jordan",
                    displayName: "Jordan Reed",
                    handle: "@jreed",
                    initials: "JR",
                    encounterLocation: "Crypto Corner Meetup",
                    lastActiveRelative: "Yesterday",
                    isOnline: false
                )
            ],
            stats: HomeStats(
                totalClicks: 28,
                totalEncounters: 34,
                totalCircles: 6
            )
        )
    }
}
