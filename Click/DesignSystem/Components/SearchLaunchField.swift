import SwiftUI

/// A search-field-looking control that opens the one global search (every search bar in the
/// app is this control, so results and routing are identical everywhere).
struct SearchLaunchField: View {
    @Environment(AppEnvironment.self) private var env
    var prompt = "Search people, messages, places, events"
    /// Closes the sheet this field sits in (search is presented by the shell, which can't
    /// present over another sheet).
    var closeContainingSheet: (() -> Void)?

    var body: some View {
        Button {
            ClickHaptics.selection()
            if let closeContainingSheet {
                closeContainingSheet()
                let router = env.router
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    router.presentSearch()
                }
            } else {
                env.router.presentSearch()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text(prompt)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(ClickTypography.body)
            .foregroundStyle(ClickColors.textTertiary)
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.searchMinHeight)
            .background(ClickColors.fillSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
        .accessibilityHint("Opens search for people, messages, places and events")
    }
}
