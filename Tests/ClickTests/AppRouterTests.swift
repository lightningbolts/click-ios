import Testing
import Foundation
@testable import Click

@Suite("App Router Deep Link & Navigation Tests")
@MainActor
struct AppRouterTests {
    let router = AppRouter()

    @Test("Parses click:// custom scheme connection URL")
    func parseClickCustomSchemeConnection() {
        let url = URL(string: "click://c/usr_123456")!
        let route = router.parseIncomingURL(url)
        #expect(route == .userProfile(userID: "usr_123456", connectionID: nil))
    }

    @Test("Parses click:// custom scheme event URL")
    func parseClickCustomSchemeEvent() {
        let url = URL(string: "click://e/bcn_9988")!
        let route = router.parseIncomingURL(url)
        #expect(route == .event(beaconID: "bcn_9988"))
    }

    @Test("Parses universal link connection URL")
    func parseUniversalLinkConnection() {
        let url = URL(string: "https://joinclick.co/c/usr_universal_789")!
        let route = router.parseIncomingURL(url)
        #expect(route == .userProfile(userID: "usr_universal_789", connectionID: nil))
    }

    @Test("Parses universal link event URL")
    func parseUniversalLinkEvent() {
        let url = URL(string: "https://joinclick.co/e/bcn_event_555")!
        let route = router.parseIncomingURL(url)
        #expect(route == .event(beaconID: "bcn_event_555"))
    }

    @Test("Enqueues deep link while unauthenticated and flushes after auth")
    func enqueueAndFlushDeepLink() {
        let url = URL(string: "click://c/usr_pending")!
        router.handleIncomingURL(url, isAuthenticated: false)

        #expect(router.pendingRoute == .userProfile(userID: "usr_pending", connectionID: nil))
        #expect(router.connectionsPath.isEmpty)

        router.flushPendingRoute()
        #expect(router.pendingRoute == nil)
        #expect(router.selectedTab == .connections)
        #expect(router.connectionsPath.count == 1)
        #expect(router.connectionsPath.first == .userProfile(userID: "usr_pending", connectionID: nil))
    }
}
