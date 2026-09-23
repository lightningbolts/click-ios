import SwiftUI

/// The single strongly filled action in a region: full width, capsule, 50pt minimum height.
/// Labels inherit the button font and a white foreground/tint, so a `ProgressView` inside the
/// label needs no extra styling.
public struct ClickPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClickTypography.button)
            .foregroundStyle(ClickColors.primaryActionForeground)
            .tint(ClickColors.primaryActionForeground)
            .padding(.horizontal, ClickSpacing.md)
            .frame(maxWidth: .infinity, minHeight: ClickMetrics.primaryActionHeight)
            .background(ClickColors.primaryActionFill.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(ClickMotion.press, value: configuration.isPressed)
    }
}

/// A neutral secondary action: full width, capsule, subtle fill, 44pt minimum height.
public struct ClickSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClickTypography.button)
            .foregroundStyle(ClickColors.textPrimary)
            .padding(.horizontal, ClickSpacing.md)
            .frame(maxWidth: .infinity, minHeight: ClickMetrics.secondaryActionHeight)
            .background(configuration.isPressed ? ClickColors.fillStrong : ClickColors.fillSubtle, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(ClickMotion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ClickPrimaryButtonStyle {
    public static var clickPrimary: ClickPrimaryButtonStyle { ClickPrimaryButtonStyle() }
}

extension ButtonStyle where Self == ClickSecondaryButtonStyle {
    public static var clickSecondary: ClickSecondaryButtonStyle { ClickSecondaryButtonStyle() }
}
