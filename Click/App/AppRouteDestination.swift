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
            ChatView(model: env.conversationModel(for: chat.conversationIdentity))
        case .publicProfile(let userID):
            PublicProfileView(userID: userID)
        case .userProfile(let userID, let connectionID):
            ProfileView(userID: userID, connectionID: connectionID)
        case .groupChat(let group):
            ChatView(model: env.conversationModel(for: group.conversationIdentity))
        case .groupProfile(let chatID):
            GroupProfileView(chatID: chatID)
        case .eventChat(let beaconID):
            EventChatView(beaconID: beaconID)
        case .event(let beaconID), .beacon(let beaconID):
            BeaconDetailView(beaconID: beaconID)
        case .hub(let hubID):
            HubChatView(hubID: hubID)
        case .myQR:
            MyClickCodeView()
        case .scanQR:
            ScanClickCodeView()
        case .tapConnect:
            TapConnectView()
        case .connectionInvocation(let invocation):
            ConnectionInvocationView(invocation: invocation)
        case .savedEvents:
            SavedEventsView()
        case .settings(let page):
            SettingsPageView(page: page)
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
