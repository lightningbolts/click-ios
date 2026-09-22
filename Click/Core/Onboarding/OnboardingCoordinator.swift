import Foundation
import Observation

/// Pure state machine coordinating the Phase 2 onboarding flow.
/// Target order: Loading → Welcome → Interests → Personality → Avatar → PriorConnections → Complete
@Observable
@MainActor
public final class OnboardingCoordinator {
    public enum Step: String, CaseIterable, Equatable, Sendable {
        case loading
        case welcome
        case interests
        case personality
        case avatar
        case priorConnections
        case complete
    }

    public private(set) var state: OnboardingState
    public private(set) var step: Step = .loading

    private var stepOverride: Step?
    private let userId: String
    private let userHasAvatarClosure: () -> Bool?
    private let userDefaults: UserDefaults

    public init(
        userId: String,
        initialState: OnboardingState? = nil,
        userHasAvatar: @escaping () -> Bool? = { false },
        userDefaults: UserDefaults = .standard
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

        self.step = computeStep(self.state)
    }

    /// Hydrates remote or cached state into the coordinator.
    public func hydrate(_ next: OnboardingState) {
        self.state = next
        self.step = computeStep(next)
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

    /// User selected exactly 5 personality traits.
    public func onPersonalitySaved() {
        updateState {
            $0.personalityCompleted = true
        }
    }

    /// User uploaded an avatar or tapped "Skip for now".
    public func onAvatarSetOrSkipped() {
        updateState {
            $0.avatarSetOrSkipped = true
        }
    }

    /// User completed or skipped prior connections.
    public func onPriorConnectionsSetOrSkipped() {
        updateState {
            $0.priorConnectionsSetOrSkipped = true
            if $0.interestsCompleted && $0.welcomeSeen {
                $0.completedAt = Date()
            }
        }
    }

    /// Back-navigation without wiping remotely saved data.
    public func goBack() {
        let target: Step? = switch step {
        case .priorConnections: .avatar
        case .avatar: .personality
        case .personality: .interests
        case .interests: .welcome
        default: nil
        }

        if let target {
            stepOverride = target
            step = target
        }
    }

    public var canGoBack: Bool {
        step == .interests || step == .personality || step == .avatar || step == .priorConnections
    }

    /// 0-indexed visible step indicator.
    public var visibleStepIndex: Int {
        switch step {
        case .loading, .welcome: 0
        case .interests: 1
        case .personality: 2
        case .avatar: 3
        case .priorConnections, .complete: 4
        }
    }

    public var visibleStepCount: Int { 5 }

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
        let legacyComplete = s.interestsCompleted && (s.avatarSetOrSkipped || hasAvatar)

        if !s.welcomeSeen && !s.interestsCompleted {
            return .welcome
        } else if !s.interestsCompleted {
            return .interests
        } else if !s.personalityCompleted && !legacyComplete {
            return .personality
        } else if !s.avatarSetOrSkipped && !hasAvatar {
            return .avatar
        } else if !s.priorConnectionsSetOrSkipped && s.personalityCompleted {
            return .priorConnections
        } else {
            return .complete
        }
    }

    private func updateState(_ mutator: (inout OnboardingState) -> Void) {
        stepOverride = nil
        mutator(&state)
        step = computeStep(state)
        persist(state)
    }

    private func persist(_ s: OnboardingState) {
        if let encoded = try? JSONEncoder().encode(s) {
            userDefaults.set(encoded, forKey: "click_onboarding_\(userId)")
        }
    }
}
