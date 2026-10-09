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

    /// Today, since a drop's develop state reads the real clock.
    private static let now = Date.now

    /// A drop `hoursAgo` old, developed (seen) unless `ready` or `pending`.
    private func drop(_ id: String, _ user: String, hoursAgo: Double, mine: Bool = false, ready: Bool = false, pending: Bool = false) -> SharedDrop {
        let created = Self.now.addingTimeInterval(-hoursAgo * 3600)
        return SharedDrop(
            id: id, userID: user, userName: user, avatarURL: nil, isMine: mine, audience: nil, connectionID: nil,
            createdAt: created,
            revealAt: pending ? Self.now.addingTimeInterval(600) : created.addingTimeInterval(60),
            developedAt: ready || pending ? nil : Self.now,
            previewURL: nil
        )
    }

    @Test("No drops in the last day: no stacks")
    func groupsNothing() {
        #expect(SharedDropGroup.group([], now: Self.now).isEmpty)
        #expect(SharedDropGroup.group([drop("old", "maya", hoursAgo: 30)], now: Self.now).isEmpty)
        #expect(SharedDropGroup.nextExpiry([]) == nil)
    }

    @Test("A rolling 24 hours by when each drop was created")
    func groupsWindow() throws {
        let groups = SharedDropGroup.group([
            drop("in", "maya", hoursAgo: 23.99),
            drop("edge", "maya", hoursAgo: 24),
            drop("out", "maya", hoursAgo: 24.01),
        ], now: Self.now)
        #expect(groups.map(\.userID) == ["maya"])
        #expect(groups[0].drops.map(\.id) == ["in"])
        let expiry = try #require(SharedDropGroup.nextExpiry(groups))
        #expect(abs(expiry.timeIntervalSince(Self.now) - 36) < 0.001)
    }

    @Test("One, five, and more than five drops: one stack each, holding the newest five")
    func groupsPerPerson() {
        let one = SharedDropGroup.group([drop("a1", "ari", hoursAgo: 1)], now: Self.now)
        #expect(one.count == 1 && one[0].drops.count == 1)

        let five = (1...5).map { drop("f\($0)", "fay", hoursAgo: Double($0)) }
        #expect(SharedDropGroup.group(five, now: Self.now).map { $0.drops.map(\.id) } == [["f5", "f4", "f3", "f2", "f1"]])

        let seven = (1...7).map { drop("s\($0)", "sam", hoursAgo: Double($0)) }
        let groups = SharedDropGroup.group(seven.shuffled(), now: Self.now)
        // No second stack for the extra two: they're the oldest, and live in the archive.
        #expect(groups.count == 1)
        #expect(groups[0].drops.map(\.id) == ["s5", "s4", "s3", "s2", "s1"])
    }

    @Test("Stacks are ordered by their newest drop, newest first, yours included; a story starts at the first unseen")
    func groupsOrder() {
        let groups = SharedDropGroup.group([
            drop("me1", "me", hoursAgo: 5, mine: true, pending: true),
            drop("m1", "maya", hoursAgo: 4),
            drop("m2", "maya", hoursAgo: 3, ready: true),
            drop("j1", "jo", hoursAgo: 1),
            drop("k1", "kai", hoursAgo: 2, ready: true),
        ], now: Self.now)
        #expect(groups.map(\.userID) == ["jo", "kai", "maya", "me"])
        #expect(groups[2].drops.map(\.id) == ["m1", "m2"])
        #expect(groups[2].start.id == "m2")
        #expect(groups[2].cover.id == "m2")
        #expect(groups[2].hasUnwatched)
        #expect(groups[0].start.id == "j1")
        // A stack of only pending drops still opens, on its newest.
        #expect(groups[3].start.id == "me1")
        #expect(groups[3].cover.id == "me1")
    }

    @Test("A new pending drop is its stack's cover; the story starts at the first unseen, else the cover")
    func groupsPendingCover() {
        let mixed = SharedDropGroup.group([
            drop("z1", "zoe", hoursAgo: 3),
            drop("z2", "zoe", hoursAgo: 2, ready: true),
            drop("z3", "zoe", hoursAgo: 0.1, pending: true),
        ], now: Self.now)[0]
        #expect(mixed.drops.map(\.id) == ["z1", "z2", "z3"])
        #expect(mixed.cover.id == "z3")
        #expect(mixed.start.id == "z2")

        let watched = SharedDropGroup.group([
            drop("w1", "wes", hoursAgo: 3),
            drop("w2", "wes", hoursAgo: 0.1, pending: true),
        ], now: Self.now)[0]
        #expect(watched.cover.id == "w2")
        #expect(watched.start.id == "w2")
        #expect(!watched.hasUnwatched)
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
