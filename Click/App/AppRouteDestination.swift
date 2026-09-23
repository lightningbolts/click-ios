import SwiftUI

/// The one canonical destination for every typed `AppRoute`.
///
/// Every tab's `NavigationStack` registers this same destination, so a route renders identically
/// no matter which stack it is pushed onto. The switch is intentionally exhaustive (no
/// `default`): adding an `AppRoute` case without a destination is a compile error rather than a
/// silent blank screen.
struct AppRouteDestination: View {
    @Environment(AppEnvironment.self) private var env
    let route: AppRoute

    var body: some View {
        switch route {
        case .chat(let chat):
            ChatView(
                model: ConversationModel(
                    identity: chat.conversationIdentity,
                    chatRepository: env.chat,
                    currentUserID: env.session.currentSession?.userId ?? "",
                    currentUserName: "You"
                )
            )
        case .userProfile(let userID, let connectionID):
            ProfileView(userID: userID, connectionID: connectionID)
        case .groupProfile:
            // Group profiles are not implemented yet and nothing links here; show an honest
            // state instead of a blank pushed screen if a route ever arrives.
            ContentUnavailableView(
                "Group profile unavailable",
                systemImage: "person.3",
                description: Text("Group profiles aren't available in this version of Click yet.")
            )
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
        case .event(let beaconID), .beacon(let beaconID):
            MapRouteDetailView(kind: .beacon, id: beaconID)
        case .hub(let hubID):
            MapRouteDetailView(kind: .hub, id: hubID)
        case .myQR:
            MyClickCodeView()
        case .scanQR:
            ScanClickCodeView()
        case .tapConnect:
            TapConnectCapabilityView()
        case .connectionInvocation(let invocation):
            ConnectionInvocationView(invocation: invocation)
        case .savedEvents:
            SavedEventsSettingsView()
        }
    }
}

extension View {
    /// Registers the canonical `AppRoute` destinations on a tab's navigation stack root.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppRouteDestination(route: route)
        }
    }
}
