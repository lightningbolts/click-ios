import Foundation

/// Reconciles remote server truth and local hints into authoritative onboarding state.
@MainActor
public final class OnboardingRepository {
    private let client: ClickAPIClient
    private let settings: SettingsStore

    public init(client: ClickAPIClient, settings: SettingsStore) {
        self.client = client
        self.settings = settings
    }

    public struct SelfProfileResponse: Decodable, Sendable {
        public struct UserObj: Decodable, Sendable {
            public let id: String?
            public let firstName: String?
            public let lastName: String?
            public let image: String?
            public let birthday: String?
            public let personalityTags: [String]?

            enum CodingKeys: String, CodingKey {
                case id
                case firstName = "first_name"
                case lastName = "last_name"
                case image
                case birthday
                case personalityTags = "personality_tags"
            }
        }
        public let user: UserObj?
        public let tags: [String]?
        public let personalityTags: [String]?

        enum CodingKeys: String, CodingKey {
            case user
            case tags
            case personalityTags = "personality_tags"
        }
    }

    /// Resolves onboarding requirements from server truth and legacy preferences.
    /// Never marks a step complete locally before durable state is confirmed.
    public func resolveOnboardingState(for userId: String) async -> (state: OnboardingState, hasAvatar: Bool) {
        let legacyCompleted = settings.hasCompletedOnboarding

        do {
            let request = APIRequest(path: "/api/users/\(userId)/profile", method: .get, requiresAuth: true)
            let res: SelfProfileResponse = try await client.execute(request)

            let interests = res.tags ?? []
            let personality = res.personalityTags ?? res.user?.personalityTags ?? []
            let hasAvatar = (res.user?.image != nil && !(res.user?.image?.isEmpty ?? true))

            let interestsDone = interests.count >= 5
            let personalityDone = personality.count == 5

            var state = OnboardingState()
            state.welcomeSeen = true
            state.interestsCompleted = interestsDone
            state.personalityCompleted = personalityDone
            state.avatarSetOrSkipped = hasAvatar
            state.priorConnectionsSetOrSkipped = legacyCompleted || (interestsDone && personalityDone && hasAvatar)

            if state.interestsCompleted && (state.personalityCompleted || legacyCompleted) {
                state.completedAt = Date()
                settings.hasCompletedOnboarding = true
            }

            return (state, hasAvatar)
        } catch {
            // On network failure, retain legacy hints if available to avoid regressively showing finished steps
            var state = OnboardingState()
            if legacyCompleted {
                state.welcomeSeen = true
                state.interestsCompleted = true
                state.personalityCompleted = true
                state.avatarSetOrSkipped = true
                state.priorConnectionsSetOrSkipped = true
                state.completedAt = Date()
            }
            return (state, legacyCompleted)
        }
    }

    /// Persists selected interests to the backend before advancing local flow.
    public func saveInterests(userId: String, tags: [String]) async throws {
        let payload = ["tags": tags]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = APIRequest(
            path: "/api/users/\(userId)/profile",
            method: .patch,
            body: body,
            requiresAuth: true
        )
        _ = try await client.executeRaw(request)
    }

    /// Persists exactly 5 personality traits to the backend before advancing local flow.
    public func savePersonality(userId: String, traits: [String]) async throws {
        guard traits.count == 5 else {
            throw APIError.validation(code: "invalid_traits", message: "Must provide exactly 5 personality traits.")
        }
        let payload = ["personality_tags": traits]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = APIRequest(
            path: "/api/users/\(userId)/profile",
            method: .patch,
            body: body,
            requiresAuth: true
        )
        _ = try await client.executeRaw(request)
    }
}
