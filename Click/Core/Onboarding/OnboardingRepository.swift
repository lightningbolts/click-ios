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

    /// Resolves onboarding requirements from server truth plus the minimum local state
    /// needed for non-server-backed/skippable steps. Remote failure never fabricates a new-user
    /// state, which would make returning users flash Welcome or Avatar.
    public func resolveOnboardingState(for userId: String, prefetchedProfile: Data? = nil) async throws -> (state: OnboardingState, hasAvatar: Bool) {
        let legacyCompleted = settings.hasCompletedOnboarding
        let cached = settings.onboardingState(for: userId)

        do {
            let res: SelfProfileResponse
            if let prefetchedProfile, let decoded = try? JSONDecoder().decode(SelfProfileResponse.self, from: prefetchedProfile) {
                res = decoded
            } else {
                res = try await client.execute(APIRequest(path: "/api/users/\(userId)/profile", method: .get, requiresAuth: true))
            }

            let interests = res.tags ?? []
            let personality = res.personalityTags ?? res.user?.personalityTags ?? []
            let hasAvatar = (res.user?.image?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

            let interestsDone = interests.count >= 5
            let personalityDone = personality.count == 5
            // A user with the pre-Phase-2 durable combination of interests + avatar and no
            // native per-user onboarding cache is a returning legacy account.
            let inferredLegacyComplete = legacyCompleted || (cached == nil && interestsDone && hasAvatar)
            let hasProfileIdentity =
                res.user?.firstName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                res.user?.birthday?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

            var state = cached ?? OnboardingState()

            // Welcome has no server column. A native signup seeds an explicit empty cached state,
            // while an account with no native cache but durable profile signals is returning.
            if cached == nil {
                state.welcomeSeen = inferredLegacyComplete || interestsDone || hasAvatar || hasProfileIdentity
            }

            // These two steps are durable server truth.
            state.interestsCompleted = interestsDone
            state.personalityCompleted = inferredLegacyComplete ? true : personalityDone

            // Avatar and Prior Connections are skippable and therefore need their per-user local
            // completion markers when no remote artifact exists.
            state.avatarSetOrSkipped = hasAvatar || cached?.avatarSetOrSkipped == true || inferredLegacyComplete
            state.priorConnectionsSetOrSkipped = cached?.priorConnectionsSetOrSkipped == true || inferredLegacyComplete

            let fullyComplete =
                state.welcomeSeen &&
                state.interestsCompleted &&
                state.personalityCompleted &&
                state.avatarSetOrSkipped &&
                state.priorConnectionsSetOrSkipped

            state.completedAt = fullyComplete ? (cached?.completedAt ?? Date()) : nil
            if fullyComplete {
                settings.hasCompletedOnboarding = true
            }
            settings.saveOnboardingState(state, for: userId)
            return (state, hasAvatar)
        } catch {
            // Offline/update compatibility: a previously completed legacy account or a native
            // per-user cache can be admitted without inventing missing server state.
            if legacyCompleted {
                let state = OnboardingState(
                    welcomeSeen: true,
                    interestsCompleted: true,
                    personalityCompleted: true,
                    avatarSetOrSkipped: true,
                    priorConnectionsSetOrSkipped: true,
                    completedAt: cached?.completedAt ?? Date()
                )
                return (state, cached?.avatarSetOrSkipped == true)
            }
            if let cached {
                return (cached, cached.avatarSetOrSkipped)
            }
            throw error
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
