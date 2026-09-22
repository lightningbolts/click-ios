import Testing
import Foundation
@testable import Click

@Suite("App Router Deep Link & Navigation Tests")
@MainActor
struct AppRouterTests {
    let router = AppRouter()

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
}


