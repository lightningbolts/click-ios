import SwiftUI

/// The leading "…" menu on every tab root (Home, Add Click, Clicks, Map, Me). Like WhatsApp's,
/// it holds that screen's own actions, so the same slot is useful everywhere without every tab
/// repeating one generic list. Each root passes its items; the only shared entry is Settings.
struct RootMenu<Items: View>: View {
    @Environment(AppEnvironment.self) private var env
    /// Off on Me, which is where Settings lives.
    var showsSettings = true
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
            if showsSettings {
                Section {
                    Button("Settings", systemImage: "gearshape") { env.router.selectTab(.settings) }
                }
            }
        } label: {
            Label("Menu", systemImage: "ellipsis")
        }
        .accessibilityLabel("Menu")
    }
}

/// Saved events, or the fuller History when that's on: the same place every menu links to.
struct EventHistoryMenuItem: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.features.isEnabled(.eventHistory) {
            Button("History", systemImage: "clock.arrow.circlepath") { env.router.navigate(to: .history) }
        } else {
            Button("Saved events", systemImage: "bookmark") { env.router.navigate(to: .savedEvents) }
        }
    }
}
