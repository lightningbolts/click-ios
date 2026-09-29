import Foundation
import Testing
@testable import Click

@Suite("Product telemetry")
struct ProductTelemetryTests {
    private func make() -> (ProductTelemetry, TelemetryQueue) {
        let suite = "ProductTelemetryTests.\(UUID().uuidString)"
        let queue = TelemetryQueue(suiteName: suite, storageKey: "q")
        return (ProductTelemetry(queue: queue, suiteName: suite), queue)
    }

    @Test("Install is sent once per install; app open once per day")
    func dedupes() async {
        let (telemetry, queue) = make()
        let morning = Date(timeIntervalSince1970: 1_790_000_000)
        await telemetry.installedIfNeeded(now: morning)
        await telemetry.installedIfNeeded(now: morning)
        await telemetry.appOpened(now: morning)
        await telemetry.appOpened(now: morning.addingTimeInterval(3_600))
        await telemetry.appOpened(now: morning.addingTimeInterval(86_400))
        let events = await queue.snapshot.compactMap { envelope -> String? in
            if case .string(let name)? = envelope.payload["event"] { return name }
            return nil
        }
        #expect(events == ["install", "app_open", "app_open"])
    }

    @Test("Payloads carry no IDs, content or coordinates")
    func payloadShape() {
        let payload = ProductTelemetry.payload(.recapOpened, at: Date(timeIntervalSince1970: 0))
        #expect(Set(payload.keys).isSubset(of: ["event", "platform", "occurred_at", "app_version"]))
        #expect(payload["platform"] == .string("ios"))
    }
}
