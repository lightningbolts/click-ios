import Testing
import Foundation
@testable import Click

/// Isolated mock transport so these tests never share a handler with other suites.
final class MeMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("Me / Settings server truth", .serialized)
struct MeSettingsTests {
    private func repository() -> MeRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeMockURLProtocol.self]
        let client = ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        )
        return MeRepository(
            api: client,
            cache: CacheStore(defaults: UserDefaults(suiteName: "MeSettingsTests.\(UUID().uuidString)")!),
            supabaseURL: URL(string: "https://project.supabase.co")!,
            supabaseAnonKey: "anon"
        )
    }

    @Test("A missing notification row means server defaults (on); a failed read is an error, not 'on'")
    func notificationDefaultsVersusFailure() async throws {
        MeMockURLProtocol.handler = { _ in (200, "[]") }
        let prefs = try await repository().notificationPreferences(userID: "u1")
        #expect(prefs[.messages] && prefs[.hubMessages])

        MeMockURLProtocol.handler = { _ in (500, "boom") }
        await #expect(throws: APIError.self) {
            _ = try await repository().notificationPreferences(userID: "u1")
        }
    }

    @Test("Saving a preference returns the server's resulting row")
    func savePreference() async throws {
        MeMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/user/preferences")
            return (200, #"{"ok":true,"message_push_enabled":false,"hub_message_push_enabled":true}"#)
        }
        let saved = try await repository().setNotificationPreference(.messages, enabled: false)
        #expect(saved[.messages] == false)
        #expect(saved[.hubMessages] == true)
    }

    @Test("A location-privacy write that affects no rows is a failure")
    func zeroRowWriteFails() async {
        MeMockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
            return (200, "[]")
        }
        await #expect(throws: APIError.self) {
            _ = try await repository().setLocationPrivacy(
                LocationPrivacy(connectionSnap: true, memoryMap: false, businessInsights: false),
                userID: "u1"
            )
        }
    }

    @Test("Location privacy columns default off (no accidental opt-in)")
    func locationDefaultsOff() async throws {
        MeMockURLProtocol.handler = { _ in (200, #"[{"location_show_on_map_enabled":true}]"#) }
        let privacy = try await repository().locationPrivacy(userID: "u1")
        #expect(privacy.memoryMap)
        #expect(!privacy.connectionSnap)
        #expect(!privacy.businessInsights)
    }

    @Test("Self profile reads Free currently from the availability row")
    func selfProfileFree() async throws {
        MeMockURLProtocol.handler = { _ in
            (200, #"{"user":{"first_name":"Maya","last_name":"Chen","image":"https://x/y.jpg"},"tags":["Coffee"],"personality_tags":["Kind"],"availability":{"is_free_this_week":true}}"#)
        }
        let profile = try await repository().selfProfile(userID: "u1")
        #expect(profile.displayName == "Maya Chen")
        #expect(profile.isFreeCurrently == true)
        #expect(profile.interests == ["Coffee"])
    }

    @Test("Free currently is only reported saved when the server echoes it")
    func freeCurrentlyRequiresEcho() async {
        MeMockURLProtocol.handler = { _ in (200, #"{"availability":null}"#) }
        await #expect(throws: APIError.self) {
            _ = try await repository().setFreeCurrently(true)
        }
    }
}
