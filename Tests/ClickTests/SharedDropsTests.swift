import Foundation
import Testing
import UIKit
@testable import Click

/// Isolated mock transport so these tests never share a handler with other suites.
final class SharedDropsMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("Shared drops", .serialized)
struct SharedDropsTests {
    private func service() -> ClickDropService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SharedDropsMockURLProtocol.self]
        return ClickDropService(api: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ))
    }

    private var photo: Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }.jpegData(compressionQuality: 0.9)!
    }

    @Test("The strip parses states from reveal time and my developed_at")
    func parsesStrip() async throws {
        SharedDropsMockURLProtocol.handler = { _ in (200, """
        {"teaser":"pixelated","drops":[
          {"id":"a","user":{"id":"u1","name":"Maya"},"is_mine":false,"connection_id":"c1",
           "reveal_at":"2000-01-01T00:00:00Z","developed_at":null},
          {"id":"b","user":{"id":"u1","name":"Maya"},"is_mine":false,"connection_id":"c1",
           "reveal_at":"2000-01-01T00:00:00Z","developed_at":"2000-01-02T00:00:00Z"},
          {"id":"c","user":{"id":"me","name":"Me"},"is_mine":true,"audience":"core",
           "reveal_at":"2999-01-01T00:00:00Z"}
        ]}
        """) }
        let drops = try await service().sharedDrops()
        #expect(drops.map { $0.state() } == [.ready, .developed, .pending(revealAt: ISO8601DateFormatter().date(from: "2999-01-01T00:00:00Z")!)])
        #expect(drops[0].connectionID == "c1")
        #expect(drops[2].audience == .core)
        #expect(drops[0].audience == nil)
    }

    @Test("The strip groups by person: yours first, then by newest drop; a story starts at the first unseen")
    func groupsByPerson() async throws {
        let past = "2000-01-01T00:00:00Z", seen = "\"2000-01-02T00:00:00Z\""
        func row(_ id: String, _ user: String, mine: Bool = false, developed: String = "null", reveal: String = past) -> String {
            #"{"id":"\#(id)","user":{"id":"\#(user)","name":"\#(user)"},"is_mine":\#(mine),"reveal_at":"\#(reveal)","developed_at":\#(developed)}"#
        }
        // Newest first, as the server sends them.
        let rows = [
            row("m3", "maya", developed: seen),
            row("j2", "jo", developed: seen),
            row("me1", "me", mine: true, reveal: "2999-01-01T00:00:00Z"),
            row("m2", "maya"),
            row("m1", "maya", developed: seen),
            row("j1", "jo", developed: seen)
        ]
        SharedDropsMockURLProtocol.handler = { _ in (200, #"{"drops":[\#(rows.joined(separator: ","))]}"#) }
        let groups = SharedDropGroup.group(try await service().sharedDrops())
        #expect(groups.map(\.userID) == ["me", "maya", "jo"])
        #expect(groups[1].drops.map(\.id) == ["m1", "m2", "m3"])
        #expect(groups[1].start?.id == "m2")
        #expect(groups[1].cover.id == "m2")
        #expect(groups[2].start?.id == "j1")
        #expect(groups[0].start == nil)
        #expect(groups[0].cover.id == "me1")
    }

    @Test("The archive pages with its cursor")
    func archivePage() async throws {
        var asked: URL?
        SharedDropsMockURLProtocol.handler = { request in
            asked = request.url
            return (200, #"{"drops":[{"id":"a","user":{"id":"u1","name":"Maya"},"reveal_at":"2000-01-01T00:00:00Z"}],"next_before":"2026-10-01T00:00:00Z"}"#)
        }
        let page = try await service().sharedDropArchive(before: "2026-10-03T00:00:00Z")
        #expect(page.drops.map(\.id) == ["a"])
        #expect(page.nextBefore == "2026-10-01T00:00:00Z")
        #expect(asked?.path == "/api/me/shared-drops/archive")
        #expect(asked?.query?.contains("before=2026-10-03T00:00:00Z") == true)
    }

    @Test("Past the daily cap, sharing says so plainly")
    func capReached() async {
        SharedDropsMockURLProtocol.handler = { _ in (409, #"{"code":"cap_reached"}"#) }
        await #expect(throws: SharedDropPostError.capReached) {
            try await service().shareDrop(photo, audience: .all, caption: nil, clientDropID: UUID())
        }
    }

    @Test("Sharing sends the audience and caption and returns the new drop")
    func shares() async throws {
        SharedDropsMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/me/shared-drops")
            return (201, #"{"drop":{"id":"n","user":{"id":"me","name":"Me"},"is_mine":true,"audience":"all","reveal_at":"2999-01-01T00:00:00Z","caption":"sunset"}}"#)
        }
        let drop = try await service().shareDrop(photo, audience: .all, caption: "sunset", clientDropID: UUID())
        #expect(drop.isMine)
        #expect(drop.caption == "sunset")
        #expect(drop.state().isPending)
    }
}
