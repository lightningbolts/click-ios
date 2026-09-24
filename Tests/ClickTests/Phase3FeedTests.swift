import Testing
import Foundation
@testable import Click

final class Phase3MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Phase 3 Feeds, Clicks, and Profile Tests")
struct Phase3FeedTests {
    @Test("Time-based salutation handles different hours correctly")
    func testSalutations() {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 22

        // Morning: 9am
        comps.hour = 9
        let morningDate = calendar.date(from: comps)!
        #expect(HomeGreeting.salutation(for: "Alex", date: morningDate) == "Good morning, Alex")

        // Afternoon: 2pm (14:00)
        comps.hour = 14
        let afternoonDate = calendar.date(from: comps)!
        #expect(HomeGreeting.salutation(for: "Alex", date: afternoonDate) == "Good afternoon, Alex")

        // Evening: 8pm (20:00)
        comps.hour = 20
        let eveningDate = calendar.date(from: comps)!
        #expect(HomeGreeting.salutation(for: "Alex", date: eveningDate) == "Good evening, Alex")

        // Late night: 2am
        comps.hour = 2
        let lateNightDate = calendar.date(from: comps)!
        #expect(HomeGreeting.salutation(for: "Alex", date: lateNightDate) == "Hello, Alex")

        // Empty name fallback
        #expect(HomeGreeting.salutation(for: "", date: morningDate) == "Good morning")
    }

    @Test("ClicksSnapshot segments filter correctly")
    func testClicksFiltering() {
        let snapshot = ClicksSnapshot.preview

        let all = snapshot.filtered(by: .all)
        #expect(all.count == 6)

        let active = snapshot.filtered(by: .active)
        #expect(active.allSatisfy { $0.isOnline || $0.lastActiveRelative.contains("m ago") || $0.lastActiveRelative.contains("1h ago") })

        let encounters = snapshot.filtered(by: .encounters)
        #expect(encounters.allSatisfy { !$0.encounterLocation.isEmpty })

        let circles = snapshot.filtered(by: .circles)
        #expect(circles.allSatisfy { $0.segment == .circles })
    }

    @Test("ClicksSnapshot search query matches name, handle, location, or tags")
    func testClicksSearch() {
        let snapshot = ClicksSnapshot.preview

        let byName = snapshot.filtered(by: .all, query: "Marcus")
        #expect(byName.count == 1)
        #expect(byName.first?.displayName == "Marcus Vance")

        let byHandle = snapshot.filtered(by: .all, query: "@samirak")
        #expect(byHandle.count == 1)
        #expect(byHandle.first?.handle == "@samirak")

        let byLocation = snapshot.filtered(by: .all, query: "Dolores")
        #expect(byLocation.count == 1)

        let byTag = snapshot.filtered(by: .all, query: "Synthesizers")
        #expect(byTag.count == 1)
        #expect(byTag.first?.displayName == "Marcus Vance")
    }

    @Test("UserProfileSnapshot encodes and decodes accurately")
    func testUserProfileSnapshot() throws {
        let profile = UserProfileSnapshot.preview
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(UserProfileSnapshot.self, from: data)

        #expect(decoded.userId == profile.userId)
        #expect(decoded.displayName == "Alex Rivera")
        #expect(decoded.interests.count == 6)
        #expect(decoded.personalityTraits.count == 5)
        #expect(decoded.totalClicks == 28)
    }

    @Test("Phase 3 repository maps authenticated backend data and never fabricates presence")
    func testRepositoryUsesBackendData() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase3MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let requests = Phase3RequestLog()
        Phase3MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            requests.append(request)
            let body: String
            if path == "/api/connections" {
                body = """
                {"active":[{"id":"conn_1","user_ids":["self","peer"],"created":1700000000000,"has_begun":true,"connection_encounters":[{"location_name":"UW Quad","encountered_at":"2026-09-22T19:00:00Z"}]}],"archived":[],"core":["conn_1"]}
                """
            } else if path == "/api/users/display-names" {
                body = """
                {"names":{"peer":"Taylor Kim"},"images":{"peer":"https://example.com/taylor.jpg"}}
                """
            } else if path == "/rest/v1/rpc/get_inbox_previews" {
                body = """
                [{"chat_id":"chat_1","connection_id":"conn_1","last_message_user_id":"peer","last_message_content":"hey!","last_message_time_created":1790000000000,"last_message_type":"text","last_message_is_read":false,"unread_count":2}]
                """
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type":"application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let client = ClickAPIClient(
            baseURL: URL(string: "https://api.joinclick.co")!,
            session: session,
            tokenProvider: { "token" }
        )
        let defaults = UserDefaults(suiteName: "Phase3FeedTests.\(UUID().uuidString)")!
        let repository = Phase3Repository(
            api: client,
            defaults: defaults,
            supabaseURL: URL(string: "https://project.supabase.co")!,
            supabaseAnonKey: "anon-key"
        )

        let snapshot = try await repository.refreshClicks(for: "self")
        #expect(snapshot.connections.count == 1)
        #expect(snapshot.connections[0].displayName == "Taylor Kim")
        #expect(snapshot.connections[0].avatarUrl == "https://example.com/taylor.jpg")
        #expect(snapshot.connections[0].encounterLocation == "UW Quad")
        #expect(snapshot.connections[0].presenceKnown == false)
        #expect(snapshot.connections[0].isOnline == false)
        #expect(snapshot.connections[0].unreadCount == 2)
        #expect(snapshot.connections[0].isCore)
        #expect(snapshot.connections[0].chatID == "chat_1")

        // Three requests regardless of inbox size: no per-connection profile fetches.
        let recorded = requests.all
        #expect(recorded.count == 3)
        #expect(!recorded.contains { ($0.url?.path ?? "").hasPrefix("/api/users/peer") })
        let rpc = try #require(recorded.first { $0.url?.path == "/rest/v1/rpc/get_inbox_previews" })
        #expect(rpc.url?.host == "project.supabase.co")
        #expect(rpc.value(forHTTPHeaderField: "apikey") == "anon-key")
        #expect(rpc.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        let cached = await repository.cachedClicks(for: "self")
        #expect(cached == snapshot)
    }
}

/// Thread-safe capture of requests seen by the mock protocol.
private final class Phase3RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    var all: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}
