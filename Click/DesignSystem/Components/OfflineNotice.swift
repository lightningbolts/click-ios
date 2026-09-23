import SwiftUI

/// Compact inline notice shown above cached content when a refresh failed, with a retry action.
public struct OfflineNotice: View {
    private let message: String
    private let onRetry: () -> Void

    public init(_ message: String, onRetry: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi.exclamationmark")
                .accessibilityHidden(true)
            Text(message)
                .font(ClickTypography.metadata)
            Spacer()
            Button("Retry", action: onRetry)
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
    }
}
