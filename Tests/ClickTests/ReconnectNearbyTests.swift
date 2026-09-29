import CoreLocation
import Foundation
import Testing
@testable import Click

/// Isolated mock transport so these tests never share a handler with other suites.
final class ReconnectMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Reconnect near here", .serialized)
struct ReconnectNearbyTests {
    private func repository() -> RelationshipRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReconnectMockURLProtocol.self]
        return RelationshipRepository(api: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ))
    }

    @Test("Only a ~100 m position leaves the phone")
    func sendsCoarsePosition() async throws {
        ReconnectMockURLProtocol.requests = []
        ReconnectMockURLProtocol.handler = { _ in (200, #"{"nudge":null}"#) }
        let nudge = try await repository().reconnectNearby(at: CLLocationCoordinate2D(latitude: 47.655341, longitude: -122.303517))
        #expect(nudge == nil)
        let query = URLComponents(url: try #require(ReconnectMockURLProtocol.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "lat" }?.value == "47.655")
        #expect(query.first { $0.name == "lng" }?.value == "-122.304")
    }

    @Test("A card parses with the past meeting only")
    func parsesCard() async throws {
        ReconnectMockURLProtocol.handler = { _ in (200, """
        {"nudge":{"id":"n1","connection_id":"c1","user":{"id":"u1","name":"Maya Chen"},
          "met_at":"2026-06-12T18:00:00Z","place_name":"Suzzallo",
          "title":"You met Maya near here","body":"You met Maya near here in June. Say hi?"}}
        """) }
        let nudge = try #require(try await repository().reconnectNearby(at: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)))
        #expect(nudge.firstName == "Maya")
        #expect(nudge.connectionID == "c1")
        #expect(nudge.body == "You met Maya near here in June. Say hi?")
    }
}
