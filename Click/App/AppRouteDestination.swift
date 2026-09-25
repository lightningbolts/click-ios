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
        Group {
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
            case .conversation(let chatID, let messageID):
                ConversationByIDView(chatID: chatID, messageID: messageID)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .background { TabBarTransitionFader().frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

/// Opens a conversation known only by chat ID: looks it up in the inbox (refreshing once if
/// it isn't there yet), then shows the chat, focused on `messageID` when given.
private struct ConversationByIDView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations: ConversationListModel?
    let chatID: String
    let messageID: String?
    @State private var resolved: ConversationIdentity?
    @State private var missing = false

    var body: some View {
        Group {
            if let resolved {
                ChatView(model: env.conversationModel(for: resolved))
            } else if missing {
                ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                       description: Text("It may have been removed, or you're no longer part of it."))
            } else {
                ClickLoadingView()
            }
        }
        .task {
            if let messageID {
                env.pendingMessageFocus = MessageFocus(conversationIDs: [chatID], messageID: messageID)
            }
            if let identity = lookup() {
                resolved = identity
                return
            }
            await conversations?.refresh()
            if let identity = lookup() { resolved = identity } else { missing = true }
        }
    }

    private func lookup() -> ConversationIdentity? {
        guard let conversations else { return nil }
        if let group = conversations.groups.first(where: { $0.chatID == chatID }) {
            return group.chatRoute.conversationIdentity
        }
        if let item = (conversations.active + conversations.archived).first(where: { $0.chatID == chatID || $0.connectionID == chatID }) {
            return DirectChatRoute(chatID: item.chatID, connectionID: item.connectionID, peerUserID: item.userID,
                                   peerDisplayName: item.displayName, peerHandle: item.handle, peerAvatarURL: item.avatarUrl)
                .conversationIdentity
        }
        if let hub = conversations.hubs.first(where: { $0.hubID == chatID }) {
            return ConversationIdentity(chatID: hub.hubID, peerUserID: "", peerDisplayName: hub.name, kind: .hub(hubID: hub.hubID))
        }
        return nil
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
