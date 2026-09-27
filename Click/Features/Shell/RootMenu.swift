import SwiftUI

/// The leading "…" menu shared by every tab root (Home, Add Click, Clicks, Map, Me), so the
/// same slot always holds the same kind of control. Root-specific actions come first.
struct RootMenu<Extra: View>: View {
    @Environment(AppEnvironment.self) private var env
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            extra()
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
        } label: {
            Label("Menu", systemImage: "ellipsis")
        }
        .accessibilityLabel("Menu")
    }
}

extension RootMenu where Extra == EmptyView {
    init() {
        self.extra = { EmptyView() }
    }
}
