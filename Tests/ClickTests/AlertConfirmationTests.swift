import CoreLocation
import Foundation
import Testing
@testable import Click

/// Isolated mock transport so these tests never share a handler with other suites.
final class AlertMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("Alert confirmations", .serialized)
struct AlertConfirmationTests {
    private func repository() -> BeaconRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlertMockURLProtocol.self]
        return BeaconRepository(api: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ))
    }

    @Test("State parses the last sighting and my vote, never counts")
    func parsesState() {
        let state = AlertConfirmationState.parse([
            "state": "active", "expires_at": "2026-10-05T20:00:00Z", "last_still_here_at": "2026-10-05T18:00:00Z",
            "my_vote": ["status": "still_here", "created_at": "2026-10-05T18:00:00Z"], "is_creator": false, "radius_meters": 300
        ])
        #expect(state.phase == .active)
        #expect(state.myVote == .stillHere)
        #expect(state.lastStillHereAt == ISO8601DateFormatter().date(from: "2026-10-05T18:00:00Z"))
        #expect(AlertConfirmationState.parse([:]).phase == .expired)
    }

    @Test("Server refusals map to plain reasons")
    func mapsRejections() {
        #expect(AlertVoteRejection.from(APIError.forbidden) == .tooFar)
        #expect(AlertVoteRejection.from(APIError.conflict(code: nil)) == .alreadyVoted)
        #expect(AlertVoteRejection.from(APIError.server(status: 410, code: nil, message: nil)) == .ended)
        #expect(AlertVoteRejection.from(APIError.validation(code: "400", message: nil)) == .needsLocation)
        #expect(AlertVoteRejection.from(APIError.offline) == nil)
    }

    @Test("A vote sends the status and the voter's position, and returns the new expiry")
    func castsVote() async throws {
        AlertMockURLProtocol.requests = []
        AlertMockURLProtocol.handler = { _ in (200, #"{"outcome":"extended","expires_at":"2026-10-05T20:00:00Z"}"#) }
        let expires = try await repository().confirmAlert(
            beaconID: "b1", vote: .stillHere, at: CLLocationCoordinate2D(latitude: 47.65, longitude: -122.30)
        )
        #expect(expires == ISO8601DateFormatter().date(from: "2026-10-05T20:00:00Z"))
        let request = try #require(AlertMockURLProtocol.requests.first)
        #expect(request.url?.path == "/api/beacons/b1/confirm")
        #expect(request.httpMethod == "POST")
    }

    @Test("Out of range comes back as a rejection, not a generic error")
    func rejectsOutOfRange() async {
        AlertMockURLProtocol.handler = { _ in (403, #"{"code":"out_of_range"}"#) }
        await #expect(throws: AlertVoteRejection.tooFar) {
            try await repository().confirmAlert(beaconID: "b1", vote: .cleared, at: nil)
        }
    }
}
