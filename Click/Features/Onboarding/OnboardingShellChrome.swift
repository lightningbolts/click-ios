import SwiftUI

/// Shared top navigation chrome for onboarding steps.
/// Provides back-navigation and discrete step indicator dots/pills.
public struct OnboardingShellChrome: View {
    let currentStepIndex: Int
    let totalSteps: Int
    let canGoBack: Bool
    let onBack: () -> Void

    public init(
        currentStepIndex: Int,
        totalSteps: Int = 5,
        canGoBack: Bool,
        onBack: @escaping () -> Void
    ) {
        self.currentStepIndex = currentStepIndex
        self.totalSteps = totalSteps
        self.canGoBack = canGoBack
        self.onBack = onBack
    }

    public var body: some View {
        HStack(spacing: ClickSpacing.md) {
            // Back Button
            if canGoBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(ClickTypography.bodyLarge)
                        .foregroundStyle(ClickColors.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else {
                Spacer()
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // Step Progress Indicator
            HStack(spacing: ClickSpacing.xs) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentStepIndex ? ClickColors.primary : ClickColors.quietBorder.opacity(0.4))
                        .frame(
                            width: index == currentStepIndex ? 24 : 8,
                            height: 6
                        )
                        .animation(ClickMotion.subtleFade, value: currentStepIndex)
                }
            }

            Spacer()

            // Balance spacer
            Spacer()
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, ClickSpacing.sm)
        .frame(height: 52)
        .background(ClickColors.background)
    }
}
