import Foundation

/// Persisted state representing an account's progress through the onboarding flow.
public struct OnboardingState: Codable, Equatable, Sendable {
    public var welcomeSeen: Bool
    public var interestsCompleted: Bool
    public var personalityCompleted: Bool
    public var avatarSetOrSkipped: Bool
    public var priorConnectionsSetOrSkipped: Bool
    public var completedAt: Date?

    public init(
        welcomeSeen: Bool = false,
        interestsCompleted: Bool = false,
        personalityCompleted: Bool = false,
        avatarSetOrSkipped: Bool = false,
        priorConnectionsSetOrSkipped: Bool = false,
        completedAt: Date? = nil
    ) {
        self.welcomeSeen = welcomeSeen
        self.interestsCompleted = interestsCompleted
        self.personalityCompleted = personalityCompleted
        self.avatarSetOrSkipped = avatarSetOrSkipped
        self.priorConnectionsSetOrSkipped = priorConnectionsSetOrSkipped
        self.completedAt = completedAt
    }

    /// Returns a pre-hydrated state for returning accounts so onboarding does not flash.
    public static func hydratedForReturningUser(
        hasInterests: Bool,
        hasAvatar: Bool
    ) -> OnboardingState {
        OnboardingState(
            welcomeSeen: true,
            interestsCompleted: hasInterests,
            personalityCompleted: true, // Legacy returning users skip personality
            avatarSetOrSkipped: hasAvatar,
            priorConnectionsSetOrSkipped: true,
            completedAt: hasInterests ? Date() : nil
        )
    }
}
