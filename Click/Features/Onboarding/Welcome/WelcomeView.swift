import SwiftUI

/// Phase 2 Welcome screen highlighting Click's value proposition.
public struct WelcomeView: View {
    let firstName: String?
    let onContinue: () -> Void

    public init(firstName: String? = nil, onContinue: @escaping () -> Void) {
        self.firstName = firstName
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderView(
                title: headlineText,
                subtitle: "Real connections with the people around you — without the feed, ads, or the performance."
            ) {
                ClickLogo(style: .mark, size: 40)
            }

            ScrollView {
                VStack(spacing: ClickSpacing.md) {
                    // 3 Value Pillars
                    WelcomePill(
                        systemImage: "person.2.circle.fill",
                        title: "In-person first",
                        description: "Nearby people, verified encounters, and no algorithmic timeline."
                    )

                    WelcomePill(
                        systemImage: "lock.shield.fill",
                        title: "End-to-end encrypted",
                        description: "Messages, photos, and files are encrypted on your device — we can't read them."
                    )

                    WelcomePill(
                        systemImage: "sparkles",
                        title: "Your tribe, not a network",
                        description: "Click builds around the interests you pick next — small circles, not reach."
                    )
                }

                Spacer(minLength: ClickSpacing.lg)

                // Bottom CTA & Hint
                VStack(spacing: ClickSpacing.sm) {
                    Button(action: {
                        ClickHaptics.impact(.medium)
                        onContinue()
                    }) {
                        HStack(spacing: ClickSpacing.sm) {
                            Text("Let's get started")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(.clickPrimary)

                    Text("Next — pick a few interests and add a photo.")
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.bottom, ClickSpacing.xl)
        }
        .background(ClickColors.background.ignoresSafeArea())
    }

    private var headlineText: String {
        if let name = firstName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Welcome, \(name)."
        }
        return "Welcome to Click."
    }
}

/// A value-prop callout row on the welcome screen.
private struct WelcomePill: View {
    let systemImage: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: ClickSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(ClickColors.accentForeground)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: ClickSpacing.xxs) {
                Text(title)
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)

                Text(description)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(ClickSpacing.md)
        .background(ClickColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface))
        .overlay(
            RoundedRectangle(cornerRadius: ClickRadius.surface)
                .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
        )
    }
}
