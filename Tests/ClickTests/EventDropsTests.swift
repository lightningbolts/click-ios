import Foundation
import Testing
import UIKit
@testable import Click

/// Isolated mock transport so these tests never share a handler with other suites.
final class EventDropsMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Event drops and history", .serialized)
struct EventDropsTests {
    private func repository() -> BeaconRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EventDropsMockURLProtocol.self]
        return BeaconRepository(api: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ))
    }

    private var photo: Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }.jpegData(compressionQuality: 0.9)!
    }

    @Test("State parses timing, access, and drops with pixelated previews only")
    func parsesState() {
        let state = EventDropsState.parse([
            "state": "revealed", "reveal_at": "2026-10-03T17:00:00Z", "event_title": "Launch", "access": "absentee",
            "can_post": false, "remaining": 0, "show_to_absentees": true,
            "drops": [["id": "d1", "user": ["id": "u1", "name": "Maya"], "is_mine": false, "filter_seed": 7,
                       "preview_url": "https://signed.example/p"]]
        ])
        #expect(state.phase == .revealed)
        #expect(state.access == .absentee)
        #expect(state.drops.first?.userName == "Maya")
        #expect(state.drops.first?.previewURL == URL(string: "https://signed.example/p"))
        #expect(EventDropsState.parse([:]).access == .none)
    }

    @Test("Recap looks are deterministic per seed and never Natural")
    func recapLooks() {
        for seed in [0, 1, 8, 9, 123_456_789, -3] {
            let look = ClickDropFilter.recapLook(seed: seed)
            #expect(look != .natural)
            #expect(look == ClickDropFilter.recapLook(seed: seed))
        }
        #expect(ClickDropFilter.recapLook(seed: 0) != ClickDropFilter.recapLook(seed: 1))
    }

    @Test("Posting refusals come back as plain reasons")
    func postRefusals() async {
        EventDropsMockURLProtocol.handler = { _ in (403, #"{"code":"not_checked_in"}"#) }
        await #expect(throws: EventDropPostError.notAllowedNow) {
            try await repository().postEventDrop(beaconID: "b1", clientDropID: UUID(), jpeg: photo, showToAbsentees: nil)
        }
        EventDropsMockURLProtocol.handler = { _ in (409, #"{"code":"cap_reached"}"#) }
        await #expect(throws: EventDropPostError.capReached) {
            try await repository().postEventDrop(beaconID: "b1", clientDropID: UUID(), jpeg: photo, showToAbsentees: nil)
        }
        await #expect(throws: EventDropPostError.invalidPhoto) {
            try await repository().postEventDrop(beaconID: "b1", clientDropID: UUID(), jpeg: Data([1, 2, 3]), showToAbsentees: nil)
        }
    }

    @Test("A successful post returns the server's drop")
    func postSucceeds() async throws {
        EventDropsMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/beacons/b1/drops")
            return (201, #"{"drop":{"id":"d9","user":{"id":"me","name":"Me"},"is_mine":true,"filter_seed":3}}"#)
        }
        let drop = try await repository().postEventDrop(beaconID: "b1", clientDropID: UUID(), jpeg: photo, showToAbsentees: nil)
        #expect(drop.id == "d9")
        #expect(drop.isMine)
    }

    @Test("History parses events, beacons and hangouts")
    func parsesHistory() async throws {
        EventDropsMockURLProtocol.handler = { request in
            #expect(request.url?.query?.contains("kind=hangouts") == true)
            return (200, """
            {"items":[
              {"kind":"event","id":"e1","title":"Launch","detail":"Went","at":"2026-10-03T05:00:00Z","recap":{"state":"ready","reveal_at":"2026-10-03T17:00:00Z"}},
              {"kind":"hangout","id":"h1","title":"Hangout with Maya","detail":"Hangout","at":"2026-10-02T05:00:00Z","connection_id":"c1","peer":{"id":"u1","name":"Maya"}}
            ],"next_cursor":null}
            """)
        }
        let page = try await repository().history(.hangouts, cursor: nil)
        #expect(page.items.map(\.kind) == [.event, .hangout])
        #expect(page.items[0].recap == .ready)
        #expect(page.items[1].peerName == "Maya")
        #expect(page.nextCursor == nil)
    }

    @Test("The recap push opens the recap")
    func pushRoute() {
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "event_drop_recap", "beacon_id": "e1"]) == .route(.eventRecap(beaconID: "e1")))
        #expect(ClickNotificationCoordinator.tapRoute(for: ["type": "event_drop_recap"]) == ClickNotificationCoordinator.TapRoute.none)
    }
}
