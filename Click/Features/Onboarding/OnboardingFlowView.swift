import SwiftUI

/// Top-level coordinator view rendering the Phase 2 onboarding step sequence.
public struct OnboardingFlowView: View {
    @Bindable var coordinator: OnboardingCoordinator
    let firstName: String?
    let onFinished: () -> Void

    public init(
        coordinator: OnboardingCoordinator,
        firstName: String? = nil,
        onFinished: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.firstName = firstName
        self.onFinished = onFinished
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Navigation Chrome
            OnboardingShellChrome(
                currentStepIndex: coordinator.visibleStepIndex,
                totalSteps: coordinator.visibleStepCount,
                canGoBack: coordinator.canGoBack,
                onBack: {
                    coordinator.goBack()
                }
            )

            // Step Content
            Group {
                switch coordinator.step {
                case .loading:
                    LaunchLoadingShimmerView()
                case .welcome:
                    WelcomeView(firstName: firstName) {
                        coordinator.onWelcomeAcknowledged()
                    }
                case .interests:
                    InterestsPickerView { tags in
                        // Remote save hook
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        coordinator.onInterestsSaved()
                    }
                case .personality:
                    PersonalityTaggingView { traits in
                        // Remote save hook
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        coordinator.onPersonalitySaved()
                    }
                case .avatar:
                    AvatarUploadView(
                        onUpload: { data in
                            // Remote upload hook
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            coordinator.onAvatarSetOrSkipped()
                        },
                        onSkip: {
                            coordinator.onAvatarSetOrSkipped()
                        }
                    )
                case .priorConnections:
                    PriorConnectionsView(
                        onComplete: {
                            coordinator.onPriorConnectionsSetOrSkipped()
                            onFinished()
                        },
                        onSkip: {
                            coordinator.onPriorConnectionsSetOrSkipped()
                            onFinished()
                        }
                    )
                case .complete:
                    LaunchLoadingShimmerView()
                        .onAppear {
                            onFinished()
                        }
                }
            }
            .animation(ClickMotion.subtleFade, value: coordinator.step)
        }
        .background(ClickColors.background.ignoresSafeArea())
    }
}

/// Subtle loading view shown while onboarding step data is hydrating.
private struct LaunchLoadingShimmerView: View {
    var body: some View {
        ZStack {
            ClickColors.background.ignoresSafeArea()
            VStack(spacing: ClickSpacing.md) {
                ClickLogo(style: .mark, size: 52)
                ProgressView()
                    .tint(ClickColors.primary)
            }
        }
    }
}
