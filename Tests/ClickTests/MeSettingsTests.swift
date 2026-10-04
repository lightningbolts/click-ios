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
                LocationPrivacy(connectionSnap: true, businessInsights: false),
                userID: "u1"
            )
        }
    }

    @Test("Location privacy columns default off (no accidental opt-in)")
    func locationDefaultsOff() async throws {
        MeMockURLProtocol.handler = { _ in (200, #"[{"location_include_in_insights_enabled":null}]"#) }
        let privacy = try await repository().locationPrivacy(userID: "u1")
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

@Suite("Calendar free/busy")
struct CalendarAvailabilityTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Today at `hour`:`minute` UTC, on a fixed day.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: hour, minute: minute))!
    }

    private func slot(_ from: Date, _ to: Date) -> DateInterval { DateInterval(start: from, end: to) }

    @Test func mergesOverlappingAndTouchingTimes() {
        let merged = CalendarAvailability.merged([slot(at(14), at(15)), slot(at(9), at(10)), slot(at(9, 30), at(11)), slot(at(11), at(12))])
        #expect(merged == [slot(at(9), at(12)), slot(at(14), at(15))])
    }

    @Test func touchingIsFree() {
        let busy = [slot(at(18), at(19))]
        #expect(CalendarAvailability.fit(slot(at(19), at(20)), busy: busy, calendar: utc) == .free)
        #expect(CalendarAvailability.fit(slot(at(17), at(18)), busy: busy, calendar: utc) == .free)
    }

    @Test func overlapSuggestsTheNextFreeQuarterHour() {
        let busy = CalendarAvailability.merged([slot(at(18, 30), at(19, 20)), slot(at(20), at(21))])
        // 19:30–20:30 would hit the 20:00 meeting, so the hour fits from 21:00.
        #expect(CalendarAvailability.fit(slot(at(19), at(20)), busy: busy, calendar: utc) == .busy(nextFree: at(21)))
        // A half hour fits in the gap at 19:30.
        #expect(CalendarAvailability.fit(slot(at(19), at(19, 30)), busy: busy, calendar: utc) == .busy(nextFree: at(19, 30)))
    }

    @Test func noSuggestionPastTheDay() {
        let busy = [slot(at(21), at(23, 30))]
        #expect(CalendarAvailability.fit(slot(at(22), at(23)), busy: busy, calendar: utc) == .busy(nextFree: nil))
    }
}
