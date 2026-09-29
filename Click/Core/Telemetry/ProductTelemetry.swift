import Foundation

/// Pilot product events a client alone can see (spec §11, `POST /api/telemetry/events`): the
/// install, one app open a day, and opening an event recap. Everything else (drops posted,
/// beacons, nudges, day-2/day-7 returns) is recorded by the server where it happens. No IDs,
/// content or coordinates; the server drops events for users outside the pilot cohort.
public struct ProductTelemetry: Sendable {
    public enum Event: String, Sendable {
        case install
        case appOpen = "app_open"
        case recapOpened = "recap_opened"
    }

    static let path = "/api/telemetry/events"
    private static let installKey = "telemetry.product.install-sent"
    private static let lastOpenDayKey = "telemetry.product.last-open-day"

    private let queue: TelemetryQueue
    /// nil uses standard defaults; tests pass their own suite.
    private let suiteName: String?

    public init(queue: TelemetryQueue, suiteName: String? = nil) {
        self.queue = queue
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// First launch of this install (queued until a signed-in flush can send it).
    public func installedIfNeeded(now: Date = .now) async {
        guard !defaults.bool(forKey: Self.installKey) else { return }
        defaults.set(true, forKey: Self.installKey)
        await track(.install, at: now)
    }

    /// At most once per local calendar day.
    public func appOpened(now: Date = .now, calendar: Calendar = .current) async {
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        guard defaults.double(forKey: Self.lastOpenDayKey) != day else { return }
        defaults.set(day, forKey: Self.lastOpenDayKey)
        await track(.appOpen, at: now)
    }

    public func track(_ event: Event, at date: Date = .now) async {
        await queue.enqueue(TelemetryEnvelope(path: Self.path, payload: Self.payload(event, at: date), createdAt: date))
    }

    static func payload(_ event: Event, at date: Date) -> [String: TelemetryValue] {
        var body: [String: TelemetryValue] = [
            "event": .string(event.rawValue),
            "platform": .string("ios"),
            "occurred_at": .string(ISO8601DateFormatter().string(from: date))
        ]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            body["app_version"] = .string(String(version.prefix(32)))
        }
        return body
    }
}
