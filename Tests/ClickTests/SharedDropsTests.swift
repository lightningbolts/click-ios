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

    @Test("Past the daily cap, sharing says so plainly")
    func capReached() async {
        SharedDropsMockURLProtocol.handler = { _ in (409, #"{"code":"cap_reached"}"#) }
        await #expect(throws: SharedDropPostError.capReached) {
            try await service().shareDrop(photo, audience: .all, clientDropID: UUID())
        }
    }

    @Test("Sharing sends the audience and returns the new drop")
    func shares() async throws {
        SharedDropsMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/me/shared-drops")
            return (201, #"{"drop":{"id":"n","user":{"id":"me","name":"Me"},"is_mine":true,"audience":"all","reveal_at":"2999-01-01T00:00:00Z"}}"#)
        }
        let drop = try await service().shareDrop(photo, audience: .all, clientDropID: UUID())
        #expect(drop.isMine)
        #expect(drop.state().isPending)
    }
}
