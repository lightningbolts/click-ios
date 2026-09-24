import SwiftUI

/// The leading "…" menu shared by every tab root (Home, Add Click, Clicks, Map, Me), so the
/// same slot always holds the same kind of control. Root-specific actions come first.
struct RootMenu<Extra: View>: View {
    @Environment(AppEnvironment.self) private var env
    /// Floating glass circle (Map) instead of a toolbar item.
    var floating = false
    /// Roots with their own focused actions (Map) can omit the account shortcuts.
    var includesAccountItems = true
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            extra()
            if includesAccountItems {
            Section {
                Button("Saved events", systemImage: "bookmark") { env.router.navigate(to: .savedEvents) }
                Button("My QR code", systemImage: "qrcode") { env.router.navigate(to: .myQR) }
                Button("Alerts", systemImage: "bell") { env.router.navigate(to: .settings(.alerts)) }
                Button("Privacy & data", systemImage: "hand.raised") { env.router.navigate(to: .settings(.privacy)) }
            }
            Section {
                Link(destination: URL(string: "https://joinclick.co")!) {
                    Label("Open web dashboard", systemImage: "safari")
                }
            }
            }
        } label: {
            if floating {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClickColors.accentForeground)
                    .frame(width: ClickMetrics.minimumHitTarget, height: ClickMetrics.minimumHitTarget)
                    .background(.regularMaterial, in: Circle())
            } else {
                Label("Menu", systemImage: "ellipsis")
            }
        }
        .accessibilityLabel("Menu")
    }
}

extension RootMenu where Extra == EmptyView {
    init(floating: Bool = false) {
        self.floating = floating
        self.extra = { EmptyView() }
    }
}
