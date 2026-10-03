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
    public func resolveOnboardingState(for userId: String, prefetchedProfile: Data? = nil) async throws -> (state: OnboardingState, hasAvatar: Bool, firstName: String?) {
        let legacyCompleted = settings.hasCompletedOnboarding
        let cached = settings.onboardingState(for: userId)

        do {
            let res: SelfProfileResponse
            if let prefetchedProfile, let decoded = try? JSONDecoder().decode(SelfProfileResponse.self, from: prefetchedProfile) {
                res = decoded
            } else {
                res = try await client.execute(APIRequest(path: "/api/users/\(userId)/profile", method: .get, requiresAuth: true))
            }

            let hasAvatar = (res.user?.image?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let state = Self.reconcile(
                cached: cached,
                legacyCompleted: legacyCompleted,
                interestCount: (res.tags ?? []).count,
                personalityCount: (res.personalityTags ?? res.user?.personalityTags ?? []).count,
                hasAvatar: hasAvatar,
                hasProfileIdentity:
                    res.user?.firstName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                    res.user?.birthday?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            )
            if state.completedAt != nil {
                settings.hasCompletedOnboarding = true
            }
            settings.saveOnboardingState(state, for: userId)
            let firstName = res.user?.firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (state, hasAvatar, firstName?.isEmpty == false ? firstName : nil)
        } catch {
            // Offline/update compatibility: a previously completed legacy account or a native
            // per-user cache can be admitted without inventing missing server state.
            if legacyCompleted {
                let state = OnboardingState(
                    welcomeSeen: true,
                    interestsCompleted: true,
                    avatarSetOrSkipped: true,
                    completedAt: cached?.completedAt ?? Date()
                )
                return (state, cached?.avatarSetOrSkipped == true, nil)
            }
            if let cached {
                return (cached, cached.avatarSetOrSkipped, nil)
            }
            throw error
        }
    }

    /// Merges server truth with this device's per-user markers. With no local markers (a new phone,
    /// or a sign-in after signing out, which clears them) an account whose server profile already
    /// has its interests is returning: the skippable Photo step was seen on another install and
    /// is not asked again. Personality is optional and never gates the shell.
    nonisolated static func reconcile(
        cached: OnboardingState?,
        legacyCompleted: Bool,
        interestCount: Int,
        personalityCount: Int,
        hasAvatar: Bool,
        hasProfileIdentity: Bool
    ) -> OnboardingState {
        let interestsDone = interestCount >= 5
        let returningComplete = legacyCompleted || (cached == nil && interestsDone)

        var state = cached ?? OnboardingState()

        // Welcome has no server column. A native signup seeds an explicit empty cached state,
        // while an account with no native cache but durable profile signals is returning.
        if cached == nil {
            state.welcomeSeen = returningComplete || interestsDone || hasAvatar || hasProfileIdentity
        }

        // Durable server truth.
        state.interestsCompleted = interestsDone
        state.personalityCompleted = personalityCount == kPersonalityRequiredTagCount
        // Photo is skippable, so a skip lives in the per-user local marker.
        state.avatarSetOrSkipped = hasAvatar || cached?.avatarSetOrSkipped == true || returningComplete

        let finished = state.welcomeSeen && state.interestsCompleted && state.avatarSetOrSkipped
        state.completedAt = finished ? (cached?.completedAt ?? Date()) : nil
        return state
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
