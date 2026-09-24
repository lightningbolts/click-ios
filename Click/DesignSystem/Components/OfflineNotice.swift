import SwiftUI

/// Inline notice above cached content.
///
/// "Offline" is claimed only when the device really is offline (`NetworkMonitor`). When the
/// device is online and this section's refresh failed, the copy is a quiet
/// "Couldn't refresh · Retry" instead. Otherwise nothing is shown.
public struct OfflineNotice: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment?

    private let savedLabel: String
    private let hasCachedValue: Bool
    private let refreshFailed: Bool
    private let onRetry: () -> Void

    /// - Parameters:
    ///   - savedLabel: what is on screen, e.g. "saved Clicks" → "Offline — showing saved Clicks".
    ///   - hasCachedValue: cached content is visible.
    ///   - refreshFailed: this section's latest refresh failed (not cancelled).
    public init(showing savedLabel: String, hasCachedValue: Bool, refreshFailed: Bool, onRetry: @escaping () -> Void) {
        self.savedLabel = savedLabel
        self.hasCachedValue = hasCachedValue
        self.refreshFailed = refreshFailed
        self.onRetry = onRetry
    }

    public var body: some View {
        switch NetworkMonitor.notice(isOnline: env?.network.isOnline ?? true, hasCachedValue: hasCachedValue, refreshFailed: refreshFailed) {
        case .none:
            EmptyView()
        case .offline:
            row(icon: "wifi.slash", text: "Offline — showing \(savedLabel)")
        case .refreshFailed:
            row(icon: "arrow.clockwise", text: "Couldn't refresh")
        }
    }

    private func row(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(text)
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
