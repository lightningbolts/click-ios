import Testing
import Foundation
@testable import Click

@Suite("App Router Deep Link & Navigation Tests")
@MainActor
struct AppRouterTests {
    let router = AppRouter()

    @Test("With a sheet open, everything pushes inside it; outside arrivals close it")
    func sheetsHostPushes() {
        router.selectedTab = .map
        router.nearbyPath = []
        router.navigate(to: .event(beaconID: "e1"))
        router.navigate(to: .eventChat(beaconID: "e1"))
        router.navigate(to: .userProfile(userID: "u1", connectionID: nil))
        router.navigate(to: .eventChat(beaconID: "e1"))
        #expect(router.presentedSheet == nil)
        #expect(router.mapPath.isEmpty)
        // Opening the chat again pops back to it instead of stacking a second copy.
        #expect(router.nearbyPath == [.event(beaconID: "e1"), .eventChat(beaconID: "e1")])

        router.nearbyPath = nil
        router.navigate(to: .event(beaconID: "e2"))
        router.navigate(to: .eventPeople(beaconID: "e2"))
        #expect(router.presentedSheet?.route == .event(beaconID: "e2"))
        #expect(router.sheetPath == [.eventPeople(beaconID: "e2")])

        router.resolveRoute(.conversation(chatID: "c1", messageID: nil))
        #expect(router.presentedSheet == nil)
        #expect(router.sheetPath.isEmpty)
        #expect(router.connectionsPath == [.conversation(chatID: "c1", messageID: nil)])
    }

    @Test("Parses click:// custom scheme connection URL with parameters")
    func parseClickCustomSchemeConnection() {
        let url = URL(string: "click://c/usr_123456?token=tok_abc&exp=1700000000&iat=1699990000&venue=ven_42")!
        let route = router.parseIncomingURL(url)
        #expect(route == .connectionInvocation(ConnectionInvocation(
            userID: "usr_123456",
            token: "tok_abc",
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            issuedAt: Date(timeIntervalSince1970: 1699990000),
            venueID: "ven_42"
        )))
    }

    @Test("Parses click:// custom scheme event URL")
    func parseClickCustomSchemeEvent() {
        let url = URL(string: "click://e/bcn_9988")!
        let route = router.parseIncomingURL(url)
        #expect(route == .event(beaconID: "bcn_9988"))
    }

    @Test("Parses universal link connection URL with token shorthand")
    func parseUniversalLinkConnection() {
        let url = URL(string: "https://joinclick.co/c/usr_universal_789?t=quick_token")!
        let route = router.parseIncomingURL(url)
        #expect(route == .connectionInvocation(ConnectionInvocation(
            userID: "usr_universal_789",
            token: "quick_token",
            expiresAt: nil,
            issuedAt: nil,
            venueID: nil
        )))
    }

    @Test("Parses canonical QR token aliases and millisecond timestamps")
    func parseCanonicalTokenAliasesAndMilliseconds() {
        let url = URL(string: "https://joinclick.co/c/usr_ms?qr_token=tok_alias&exp=1700000000000&iat=1699990000000&venue_id=ven_99")!
        let route = router.parseIncomingURL(url)
        #expect(route == .connectionInvocation(ConnectionInvocation(
            userID: "usr_ms",
            token: "tok_alias",
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            issuedAt: Date(timeIntervalSince1970: 1699990000),
            venueID: "ven_99"
        )))

        let qtURL = URL(string: "click://c/usr_qt?qt=short_token")!
        #expect(router.parseIncomingURL(qtURL) == .connectionInvocation(ConnectionInvocation(
            userID: "usr_qt",
            token: "short_token"
        )))
    }

    @Test("Parses universal link event URL")
    func parseUniversalLinkEvent() {
        let url = URL(string: "https://joinclick.co/e/bcn_event_555")!
        let route = router.parseIncomingURL(url)
        #expect(route == .event(beaconID: "bcn_event_555"))
    }

    @Test("Enqueues connection deep link while unauthenticated and flushes to addClick tab")
    func enqueueAndFlushDeepLink() {
        let url = URL(string: "click://c/usr_pending?token=tok_xyz")!
        let expected = ConnectionInvocation(
            userID: "usr_pending",
            token: "tok_xyz",
            expiresAt: nil,
            issuedAt: nil,
            venueID: nil
        )

        router.handleIncomingURL(url, isAuthenticated: false)

        #expect(router.pendingRoute == .connectionInvocation(expected))
        #expect(router.addClickPath.isEmpty)

        router.flushPendingRoute()
        #expect(router.pendingRoute == nil)
        #expect(router.selectedTab == .addClick)
        #expect(router.addClickPath.first == .connectionInvocation(expected))
    }

    private func chat(_ chatID: String? = "chat_1", connectionID: String? = "conn_1", peer: String = "usr_peer") -> AppRoute {
        .chat(DirectChatRoute(chatID: chatID, connectionID: connectionID, peerUserID: peer, peerDisplayName: "Lena"))
    }

    @Test("Chat → profile → Message pops back to the open chat instead of stacking a copy")
    func messageFromProfilePopsBack() {
        router.selectedTab = .connections
        router.navigate(to: chat())
        router.navigate(to: .userProfile(userID: "usr_peer", connectionID: "conn_1"))
        router.navigate(to: chat(nil))
        #expect(router.connectionsPath == [chat()])
    }

    @Test("A push for the open chat keeps one copy, even when it names the chat differently")
    func pushForOpenChatDoesNotDuplicate() {
        router.selectedTab = .connections
        router.navigate(to: chat(nil))
        router.resolveRoute(chat("chat_1", connectionID: nil))
        #expect(router.connectionsPath.count == 1)
        router.resolveRoute(.conversation(chatID: "conn_1", messageID: nil))
        #expect(router.connectionsPath.count == 1)
    }

    @Test("A push for an open chat on another tab stays on that tab")
    func pushStaysOnTabHostingChat() {
        router.selectedTab = .home
        router.navigate(to: chat())
        router.resolveRoute(chat())
        #expect(router.selectedTab == .home)
        #expect(router.homePath == [chat()])
        #expect(router.connectionsPath.isEmpty)
    }

    @Test("Different conversations and profiles still push; a focus is queued for message links")
    func differentScreensPush() {
        router.selectedTab = .connections
        router.navigate(to: chat())
        router.navigate(to: .userProfile(userID: "usr_peer", connectionID: "conn_1"))
        router.navigate(to: chat("chat_2", connectionID: "conn_2", peer: "usr_other"))
        #expect(router.connectionsPath.count == 3)
        router.navigate(to: .userProfile(userID: "usr_peer", connectionID: nil))
        #expect(router.connectionsPath.count == 2)
        router.navigate(to: .conversation(chatID: "chat_1", messageID: "m_1"))
        #expect(router.connectionsPath == [chat()])
        #expect(router.pendingMessageFocus == MessageFocus(conversationIDs: ["chat_1"], messageID: "m_1"))
    }
}



@Suite("Notification tap routing")
@MainActor
struct NotificationTapRouteTests {
    private func route(_ payload: [String: String]) -> ClickNotificationCoordinator.TapRoute {
        ClickNotificationCoordinator.tapRoute(for: payload)
    }

    @Test("Chat messages and Click Drop reveals open the chat")
    func chat() {
        for type in ["chat_message", "new_message", "disposable_reveal"] {
            #expect(route(["type": type, "chat_id": "c", "connection_id": "k", "sender_user_id": "u", "sender_name": "Lena"])
                    == .chat(chatID: "c", connectionID: "k", senderUserID: "u", senderName: "Lena"))
        }
        #expect(route(["category": "new_message", "chatId": " c "]) == .chat(chatID: "c", connectionID: nil, senderUserID: nil, senderName: nil))
    }

    @Test("Events, hubs and profiles route by their IDs; missing IDs stay put")
    func routes() {
        #expect(route(["type": "event_reminder", "beacon_id": "b"]) == .route(.event(beaconID: "b")))
        #expect(route(["type": "shared_upcoming_event", "event_id": "e"]) == .route(.event(beaconID: "e")))
        #expect(route(["type": "event_teaser"]) == .none)
        #expect(route(["type": "hub_message", "venue_id": "h"]) == .route(.hub(hubID: "h")))
        #expect(route(["type": "reconnect_nudge", "user_id": "u", "connection_id": "k"]) == .route(.userProfile(userID: "u", connectionID: "k")))
        #expect(route(["type": "archive_warning"]) == .connections)
        #expect(route(["type": "availability_match"]) == .connections)
        #expect(route(["type": "something_new"]) == .none)
    }
}
