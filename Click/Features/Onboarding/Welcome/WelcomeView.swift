import SwiftUI

/// Onboarding step 1: what Click is, and what the next two steps are.
public struct WelcomeView: View {
    let firstName: String?
    let onContinue: () -> Void

    public init(firstName: String? = nil, onContinue: @escaping () -> Void) {
        self.firstName = firstName
        self.onContinue = onContinue
    }

    public var body: some View {
        OnboardingPage(
            title: firstName?.nonEmptyTrimmed.map { "Welcome, \($0)." } ?? "Welcome to Click.",
            subtitle: "Real connections with the people around you, without the feed, ads, or performance.",
            showsLogo: true
        ) {
            VStack(spacing: 0) {
                IconTileRow(systemImage: "person.2.fill", tint: ClickColors.primaryActionFill,
                           title: "In-person first",
                           detail: "Connect with people you actually meet. No algorithmic timeline.")
                HomeDivider(inset: 68)
                IconTileRow(systemImage: "lock.fill", tint: ClickColors.online,
                           title: "Private by default",
                           detail: "Messages, photos, and files are end-to-end encrypted.")
                HomeDivider(inset: 68)
                IconTileRow(systemImage: "sparkles", tint: ClickColors.warning,
                           title: "Small circles, not reach",
                           detail: "Click builds around the interests you pick next.")
            }
            .padding(.vertical, 6)
            .groupedSurface()
        } actions: {
            Button {
                ClickHaptics.impact(.medium)
                onContinue()
            } label: {
                Text("Get started")
            }
            .buttonStyle(.clickPrimary)

            Text("Two quick steps: your interests and a photo.")
                .font(ClickTypography.metadata)
                .foregroundStyle(ClickColors.textTertiary)
                .frame(minHeight: ClickMetrics.secondaryActionHeight)
        }
    }
}
