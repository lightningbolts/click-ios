import Foundation
import Observation

/// Pure state machine coordinating onboarding: Loading → Welcome → Interests → Photo → Complete.
/// Personality and Find Friends are optional and offered later in the app (Home's setup card).
@Observable
@MainActor
public final class OnboardingCoordinator {
    public enum Step: String, CaseIterable, Equatable, Sendable {
        case loading
        case welcome
        case interests
        case avatar
        case complete
    }

    public private(set) var state: OnboardingState
    public private(set) var step: Step = .loading
    public private(set) var loadErrorMessage: String?
    /// True once server (or its offline fallback) resolution has hydrated this coordinator.
    /// Before that, a cached completion may already show the shell, but nothing else does.
    public private(set) var isResolved = false
    /// The account's first name once resolved, for the Welcome greeting.
    public private(set) var firstName: String?

    private var stepOverride: Step?
    private let userId: String
    private var userHasAvatarClosure: () -> Bool?
    private let userDefaults: UserDefaults

    public init(
        userId: String,
        initialState: OnboardingState? = nil,
        userHasAvatar: @escaping () -> Bool? = { false },
        userDefaults: UserDefaults = UserDefaults(suiteName: "click_auth_prefs") ?? .standard
    ) {
        self.userId = userId
        self.userHasAvatarClosure = userHasAvatar
        self.userDefaults = userDefaults

        if let provided = initialState {
            self.state = provided
        } else if let savedData = userDefaults.data(forKey: "click_onboarding_\(userId)"),
                  let decoded = try? JSONDecoder().decode(OnboardingState.self, from: savedData) {
            self.state = decoded
        } else {
            self.state = OnboardingState()
        }

        // Production coordinators without an explicit injected state must remain on Loading
        // until server/cache reconciliation finishes. This prevents Welcome/Avatar flashes for
        // returning users during cold start.
        self.step = initialState == nil ? .loading : computeStep(self.state)
    }

    /// Hydrates remote or cached state into the coordinator.
    public func hydrate(_ next: OnboardingState, hasAvatar: Bool? = nil, firstName: String? = nil) {
        loadErrorMessage = nil
        isResolved = true
        if let firstName { self.firstName = firstName }
        if let hasAvatar = hasAvatar {
            self.userHasAvatarClosure = { hasAvatar }
        }
        self.state = next
        self.step = computeStep(next)
    }

    /// Cold start: a returning user whose last resolved state was complete goes straight to the
    /// shell while the server re-check runs in the background. Anything short of complete stays
    /// on Loading until resolved, so no onboarding step ever flashes.
    public func adoptCachedCompletion(_ cached: OnboardingState) {
        guard !isResolved, cached.completedAt != nil else { return }
        state = cached
        userHasAvatarClosure = { cached.avatarSetOrSkipped }
        if computeStep(cached) == .complete {
            step = .complete
        }
    }

    public func beginLoading() {
        loadErrorMessage = nil
        step = .loading
    }

    public func markLoadFailed(_ message: String) {
        loadErrorMessage = message
        step = .loading
    }

    /// Advances from Loading to the first actionable step once prerequisites are loaded.
    public func onDataLoaded() {
        if step == .loading {
            step = computeStep(state)
        }
    }

    /// User acknowledged the Welcome screen.
    public func onWelcomeAcknowledged() {
        updateState {
            $0.welcomeSeen = true
        }
    }

    /// User selected ≥ 5 interests and saved them remotely.
    public func onInterestsSaved() {
        updateState {
            $0.interestsCompleted = true
        }
    }

    /// User uploaded an avatar or tapped "Skip for now": the last step.
    public func onAvatarSetOrSkipped() {
        updateState {
            $0.avatarSetOrSkipped = true
        }
    }

    /// Back-navigation without wiping remotely saved data.
    public func goBack() {
        let target: Step? = switch step {
        case .avatar: .interests
        case .interests: .welcome
        default: nil
        }
        if let target {
            stepOverride = target
            step = target
        }
    }

    public var canGoBack: Bool { step == .interests || step == .avatar }

    /// 0-indexed visible step indicator.
    public var visibleStepIndex: Int {
        switch step {
        case .loading, .welcome: 0
        case .interests: 1
        case .avatar, .complete: 2
        }
    }

    public static let visibleStepCount = 3

    /// Returns true if the account needs onboarding before accessing the main shell.
    public var needsOnboarding: Bool {
        step != .complete
    }

    // MARK: - Internal Computation

    internal func computeStep(_ s: OnboardingState) -> Step {
        if let override = stepOverride {
            return override
        }

        let avatarPresent = userHasAvatarClosure()
        if avatarPresent == nil && s.welcomeSeen && s.interestsCompleted && !s.avatarSetOrSkipped {
            return .loading
        }

        let hasAvatar = avatarPresent == true
        if !s.welcomeSeen && !s.interestsCompleted {
            return .welcome
        } else if !s.interestsCompleted {
            return .interests
        } else if !s.avatarSetOrSkipped && !hasAvatar {
            return .avatar
        } else {
            return .complete
        }
    }

    private func updateState(_ mutator: (inout OnboardingState) -> Void) {
        stepOverride = nil
        mutator(&state)
        step = computeStep(state)
        // Reaching the end (an existing photo counts for the Photo step) completes onboarding.
        if step == .complete, state.completedAt == nil {
            state.avatarSetOrSkipped = true
            state.completedAt = Date()
        }
        persist(state)
    }

    private func persist(_ s: OnboardingState) {
        if let encoded = try? JSONEncoder().encode(s) {
            userDefaults.set(encoded, forKey: "click_onboarding_\(userId)")
        }
        if s.isComplete {
            userDefaults.set(true, forKey: "has_completed_onboarding")
        }
    }
}
