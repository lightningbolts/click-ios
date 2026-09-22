import Foundation

/// Snapshot representation of the active user profile ("Me" tab).
public struct UserProfileSnapshot: Codable, Equatable, Sendable {
    public let userId: String
    public let displayName: String
    public let handle: String
    public let avatarUrl: String?
    public let initials: String
    public let bio: String
    public let interests: [String]
    public let personalityTraits: [String]
    public let totalClicks: Int
    public let totalEncounters: Int
    public let totalCircles: Int
    public let memberSince: String

    public init(
        userId: String,
        displayName: String,
        handle: String,
        avatarUrl: String? = nil,
        initials: String,
        bio: String,
        interests: [String],
        personalityTraits: [String],
        totalClicks: Int,
        totalEncounters: Int,
        totalCircles: Int,
        memberSince: String
    ) {
        self.userId = userId
        self.displayName = displayName
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.initials = initials
        self.bio = bio
        self.interests = interests
        self.personalityTraits = personalityTraits
        self.totalClicks = totalClicks
        self.totalEncounters = totalEncounters
        self.totalCircles = totalCircles
        self.memberSince = memberSince
    }
}

extension UserProfileSnapshot {
    public static var preview: UserProfileSnapshot {
        UserProfileSnapshot(
            userId: "usr_alex_preview",
            displayName: "Alex Rivera",
            handle: "@arivera",
            avatarUrl: nil,
            initials: "AR",
            bio: "Building hardware prototypes & discovering modular synth tracks. Often climbing in Dogpatch or drinking espresso in Mission.",
            interests: [
                "Coffee",
                "Producing",
                "Synthesizers",
                "Bouldering",
                "Film Photography",
                "Hiking"
            ],
            personalityTraits: [
                "Curious",
                "Thoughtful",
                "Playful",
                "Spontaneous",
                "Supportive"
            ],
            totalClicks: 28,
            totalEncounters: 34,
            totalCircles: 6,
            memberSince: "Joined Sept 2026"
        )
    }
}
