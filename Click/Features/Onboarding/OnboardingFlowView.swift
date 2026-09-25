import SwiftUI

/// Top-level coordinator view rendering the Phase 2 onboarding step sequence.
public struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var env
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
                    if let message = coordinator.loadErrorMessage {
                        OnboardingLoadErrorView(message: message) {
                            if let userId = env.session.currentSession?.userId {
                                env.retryOnboardingResolution(for: userId)
                            }
                        }
                    } else {
                        LaunchLoadingShimmerView()
                    }
                case .welcome:
                    WelcomeView(firstName: firstName) {
                        coordinator.onWelcomeAcknowledged()
                    }
                case .interests:
                    InterestsPickerView { tags in
                        guard let userId = env.session.currentSession?.userId else {
                            throw APIError.unauthorized
                        }
                        try await env.onboardingRepository.saveInterests(userId: userId, tags: tags)
                        coordinator.onInterestsSaved()
                    }
                case .personality:
                    PersonalityTaggingView { traits in
                        guard let userId = env.session.currentSession?.userId else {
                            throw APIError.unauthorized
                        }
                        try await env.onboardingRepository.savePersonality(userId: userId, traits: traits)
                        coordinator.onPersonalitySaved()
                    }
                case .avatar:
                    AvatarUploadView(
                        onUpload: { data in
                            _ = try await env.avatarService.uploadAvatar(imageData: data, client: env.api)
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
            ClickLoadingView(size: 52)
        }
    }
}


private struct OnboardingLoadErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: ClickSpacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(ClickColors.accentForeground)
            Text("Couldn't finish loading")
                .font(ClickTypography.sectionTitle)
                .foregroundStyle(ClickColors.textPrimary)
            Text(message)
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ClickSpacing.xl)
            Button("Try Again", action: onRetry)
                .font(ClickTypography.bodyEmphasized)
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClickColors.background)
    }
}
