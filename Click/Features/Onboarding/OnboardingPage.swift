import SwiftUI

/// The frame every sign-in, setup and onboarding screen shares: a Manrope title with one
/// supporting line, content on the grouped background, and the screen's actions pinned to the
/// bottom, where they ride above the keyboard so the next step is always in reach.
struct OnboardingPage<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    /// The brand mark above the title, on the screens that open the app (sign-in, Welcome).
    var showsLogo = false
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    if showsLogo {
                        ClickLogo(size: 56).padding(.bottom, ClickSpacing.md)
                    }
                    Text(title)
                        .font(ClickTypography.largeTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 4)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, ClickSpacing.sm)
            .padding(.bottom, ClickSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ClickColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: ClickSpacing.xs) { actions }
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.top, ClickSpacing.sm)
                .padding(.bottom, ClickSpacing.sm)
                .background(ClickColors.background)
        }
    }
}

extension OnboardingPage where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, showsLogo: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, showsLogo: showsLogo, content: content, actions: { EmptyView() })
    }
}

/// The quiet text action under a primary one ("Skip for now", "Use a different account").
struct OnboardingTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClickTypography.button)
            .foregroundStyle(ClickColors.textSecondary)
            .frame(maxWidth: .infinity, minHeight: ClickMetrics.secondaryActionHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == OnboardingTextButtonStyle {
    static var onboardingText: OnboardingTextButtonStyle { OnboardingTextButtonStyle() }
}

/// Back and step progress above an onboarding step: one segment per step, filled up to here.
struct OnboardingStepBar: View {
    let step: Int
    let count: Int
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: ClickSpacing.md) {
            Button {
                onBack?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ClickColors.textPrimary)
                    .frame(width: ClickMetrics.minimumHitTarget, height: ClickMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(onBack == nil ? 0 : 1)
            .disabled(onBack == nil)
            .accessibilityLabel("Back")

            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? ClickColors.primaryActionFill : ClickColors.fillStrong)
                        .frame(height: 4)
                }
            }
            .animation(ClickMotion.content, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of \(count)")

            Color.clear.frame(width: ClickMetrics.minimumHitTarget, height: 1)
        }
        .padding(.horizontal, ClickSpacing.xs)
        .frame(height: 52)
        .background(ClickColors.background)
    }
}

/// A selectable capsule (interests, personality): the app's chip look, tinted when picked.
struct SelectableChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
            }
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(isSelected ? ClickColors.accentForeground : ClickColors.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.chipHeight)
            .background(isSelected ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
            .contentShape(Capsule())
            .animation(ClickMotion.selection, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An inline status line for a form: what went wrong, or what to do next.
struct FormNotice: View {
    enum Kind { case error, info }
    let text: String
    var kind: Kind = .error

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind == .error ? "exclamationmark.circle.fill" : "envelope.fill")
        }
        .font(ClickTypography.supporting)
        .foregroundStyle(kind == .error ? ClickColors.destructive : ClickColors.accentForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ClickSpacing.surfacePadding)
        .padding(.vertical, 12)
        .background(kind == .error ? ClickColors.destructive.opacity(0.12) : ClickColors.selectionTint,
                    in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

/// A grouped-surface row led by a tinted symbol tile: Welcome's value props, Home's setup steps.
/// With `showsChevron` it reads as a link (wrap it in a Button).
struct IconTileRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    var showsChevron = false

    var body: some View {
        HStack(alignment: showsChevron ? .center : .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(detail)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .padding(.horizontal, ClickSpacing.surfacePadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
