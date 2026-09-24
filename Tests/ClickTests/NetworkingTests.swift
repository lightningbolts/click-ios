import Foundation
import Testing
@testable import Click

/// Thread-safe counter for URLProtocol handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private func response(_ request: URLRequest, _ status: Int, _ body: String = "{}") -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
}

extension ClickAPIClientTests {
    @Test("A 5xx GET is retried exactly once")
    func getRetriesOnceOn5xx() async throws {
        let calls = Counter()
        MockURLProtocol.requestHandler = { request in
            calls.increment() == 1 ? response(request, 503) : response(request, 200, #"{"ok":true}"#)
        }
        let client = ClickAPIClient(baseURL: URL(string: "https://api.example.com")!, session: makeMockSession())
        let (data, _) = try await client.executeRaw(APIRequest(path: "/api/x", requiresAuth: false))
        #expect(calls.count == 2)
        #expect(String(decoding: data, as: UTF8.self).contains("ok"))
    }

    @Test("A 5xx POST is never retried")
    func postNotRetried() async {
        let calls = Counter()
        MockURLProtocol.requestHandler = { request in
            calls.increment()
            return response(request, 500)
        }
        let client = ClickAPIClient(baseURL: URL(string: "https://api.example.com")!, session: makeMockSession())
        await #expect(throws: APIError.self) {
            _ = try await client.executeRaw(APIRequest(path: "/api/x", method: .post, body: Data("{}".utf8), requiresAuth: false))
        }
        #expect(calls.count == 1)
    }

    @Test("A persistent 5xx GET fails after one retry, not more")
    func getGivesUpAfterOneRetry() async {
        let calls = Counter()
        MockURLProtocol.requestHandler = { request in
            calls.increment()
            return response(request, 502)
        }
        let client = ClickAPIClient(baseURL: URL(string: "https://api.example.com")!, session: makeMockSession())
        await #expect(throws: APIError.self) {
            _ = try await client.executeRaw(APIRequest(path: "/api/x", requiresAuth: false))
        }
        #expect(calls.count == 2)
    }

    @Test("Concurrent 401s share one token refresh")
    func concurrent401sShareOneRefresh() async throws {
        let refreshes = Counter()
        MockURLProtocol.requestHandler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? response(request, 200) : response(request, 401)
        }
        let gate = SingleFlightProbe(counter: refreshes)
        let client = ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: makeMockSession(),
            tokenProvider: { "old" },
            tokenRefresher: { try await gate.refresh() }
        )
        async let a = client.executeRaw(APIRequest(path: "/api/a"))
        async let b = client.executeRaw(APIRequest(path: "/api/b"))
        async let c = client.executeRaw(APIRequest(path: "/api/c"))
        _ = try await (a, b, c)
        #expect(refreshes.count == 1)
    }
}

/// Mirrors `SessionController.refreshSession`'s single-flight contract for the client test.
private actor SingleFlightProbe {
    let counter: Counter
    private var task: Task<String, Error>?
    init(counter: Counter) { self.counter = counter }
    func refresh() async throws -> String {
        if let task { return try await task.value }
        let task = Task<String, Error> {
            self.counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return "new"
        }
        self.task = task
        return try await task.value
    }
}

@Suite("Offline banner, cancellation and caches")
struct NetworkingTests {
    @Test("Offline notice appears only when the device is offline")
    func noticeOnlyWhenOffline() {
        #expect(NetworkMonitor.notice(isOnline: true, hasCachedValue: true, refreshFailed: true) == .refreshFailed)
        #expect(NetworkMonitor.notice(isOnline: true, hasCachedValue: true, refreshFailed: false) == .none)
        #expect(NetworkMonitor.notice(isOnline: false, hasCachedValue: true, refreshFailed: false) == .offline)
        #expect(NetworkMonitor.notice(isOnline: false, hasCachedValue: true, refreshFailed: true) == .offline)
        #expect(NetworkMonitor.notice(isOnline: false, hasCachedValue: false, refreshFailed: true) == .none)
    }

    @Test("Cancellation is not a failure and restores the previous phase")
    func cancellationKeepsPhase() {
        var state = ModuleState<[String]>()
        state.begin()
        state.succeed(["a"])
        state.begin()
        state.fail(APIError.cancelled)
        #expect(state.phase == .loaded)
        #expect(!state.isStale)

        state.begin()
        state.fail(CancellationError())
        #expect(state.phase == .loaded)

        state.begin()
        state.fail(URLError(.cancelled))
        #expect(state.phase == .loaded)

        state.begin()
        state.fail(APIError.server(status: 500, code: nil, message: nil))
        #expect(state.isStale)
        #expect(state.value == ["a"])
    }

    @Test("Cancellation before any value returns to idle")
    func cancellationFromIdle() {
        var state = ModuleState<Int>()
        state.begin()
        state.fail(CancellationError())
        #expect(state.phase == .idle)
        #expect(state.errorMessage == nil)
    }

    @Test("Fresh cached values are not refetched; stale ones are")
    func freshnessWindow() async throws {
        let cache = FreshnessCache()
        let fetches = Counter()
        let fetch: @Sendable () async throws -> Int = { fetches.increment() }
        let first = try await cache.value("k", maxAge: 60, fetch: fetch)
        let second = try await cache.value("k", maxAge: 60, fetch: fetch)
        #expect(first == 1 && second == 1)
        #expect(fetches.count == 1)
        let later = try await cache.value("k", maxAge: 60, now: Date().addingTimeInterval(61), fetch: fetch)
        #expect(later == 2)
        #expect(fetches.count == 2)
    }

    @Test("Concurrent cache misses coalesce onto one fetch")
    func freshnessCoalesces() async throws {
        let cache = FreshnessCache()
        let fetches = Counter()
        let fetch: @Sendable () async throws -> Int = {
            try await Task.sleep(for: .milliseconds(50))
            return fetches.increment()
        }
        async let a = cache.value("k", maxAge: 60, fetch: fetch)
        async let b = cache.value("k", maxAge: 60, fetch: fetch)
        _ = try await (a, b)
        #expect(fetches.count == 1)
    }

    @Test("Proactive refresh triggers inside the five-minute window only")
    func proactiveRefreshWindow() {
        let now = Date()
        #expect(SessionController.needsProactiveRefresh(expiresAt: now.addingTimeInterval(120), now: now))
        #expect(!SessionController.needsProactiveRefresh(expiresAt: now.addingTimeInterval(600), now: now))
        #expect(!SessionController.needsProactiveRefresh(expiresAt: nil, now: now))
    }
}

extension ClickAPIClientTests {
    @Test("Cold-start expired token and a concurrent API call spend the refresh token once")
    @MainActor
    func coldStartRefreshIsSingleFlight() async throws {
        let refreshes = Counter()
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/auth/v1/token") {
                refreshes.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return response(request, 200, #"{"access_token":"new","refresh_token":"r2","expires_in":3600,"user":{"id":"u1"}}"#)
            }
            return response(request, 200, #"{"user":{"id":"u1","first_name":"A","last_name":"B","birthday":"2000-01-01"}}"#)
        }
        let vault = KeychainSessionVault(account: "test_\(UUID().uuidString)")
        defer { vault.deleteSession() }
        vault.saveSession(SessionSnapshot(userId: "u1", jwt: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-60)))
        let controller = SessionController(
            vault: vault,
            authService: SupabaseAuthService(baseURL: URL(string: "https://sb.example.com")!, anonKey: "anon", session: makeMockSession())
        )
        controller.apiClient = ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: makeMockSession(),
            tokenProvider: { [weak controller] in await controller?.validAccessToken() }
        )
        async let restore: Void = controller.restoreSession()
        async let token = controller.validAccessToken()
        _ = await (restore, token)
        #expect(refreshes.count == 1)
        #expect(controller.currentSession?.jwt == "new")
    }
}
