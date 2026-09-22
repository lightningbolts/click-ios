import SwiftUI

/// Standardized onboarding screen header component ensuring rock-solid vertical alignment across all flow steps.
public struct OnboardingHeaderView<TrailingContent: View>: View {
    let title: String
    let subtitle: String?
    let trailingContent: TrailingContent

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingContent = trailingContent()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
            HStack(alignment: .top, spacing: ClickSpacing.md) {
                Text(title)
                    .font(ClickTypography.headlineLarge)
                    .tracking(-0.5)
                    .foregroundStyle(ClickColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                trailingContent
            }

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ClickSpacing.lg)
        .padding(.top, ClickSpacing.md)
        .padding(.bottom, ClickSpacing.sm)
    }
}

extension OnboardingHeaderView where TrailingContent == EmptyView {
    public init(
        title: String,
        subtitle: String? = nil
    ) {
        self.init(title: title, subtitle: subtitle, trailingContent: { EmptyView() })
    }
}
