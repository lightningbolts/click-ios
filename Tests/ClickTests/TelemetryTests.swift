import Foundation
import Testing
@testable import Click

@Suite("Telemetry (§71)")
struct TelemetryTests {
    private func freshQueue() -> (TelemetryQueue, String, String) {
        let suite = "telemetry-tests-\(UUID().uuidString)"
        return (TelemetryQueue(suiteName: suite, storageKey: "q"), suite, suite)
    }

    @Test("Failures are always sent; successes follow the 10% sample")
    func sampling() {
        let (queue, _, _) = freshQueue()
        let never = ConnectionFlowTelemetry(queue: queue, sample: { 0.99 })
        let always = ConnectionFlowTelemetry(queue: queue, sample: { 0.01 })
        #expect(never.payload(.failed) != nil)
        #expect(never.payload(.hostSelectionAbandoned) != nil)
        #expect(never.payload(.matched) == nil)
        #expect(always.payload(.matched) != nil)
    }

    @Test("Payloads never carry user IDs or coordinates")
    func noPII() throws {
        let (queue, _, _) = freshQueue()
        let telemetry = ConnectionFlowTelemetry(queue: queue, sample: { 0 })
        let payload = try #require(telemetry.payload(
            .failed, peerCount: 2, isGroup: false, isReconnect: true,
            reason: "peer 3f2a9c1e-1111-4222-8333-444455556666 at 47.606210,-122.332110"
        ))
        let text = String(describing: payload)
        #expect(!text.contains("3f2a9c1e"))
        #expect(!text.contains("47.6062"))
        #expect(Set(payload.keys).isSubset(of: ["event", "peer_count", "is_group", "is_reconnect", "selected_count", "candidate_count", "reason"]))

        let friction = try #require(FrictionTelemetry.payload(durationSeconds: 45, panCount: 3, hexbinID: AnonymizedHexbin.cell(latitude: 47.6062, longitude: -122.3321)))
        #expect(!String(describing: friction).contains("47.6"))
        #expect(FrictionTelemetry.payload(durationSeconds: 20, panCount: 3, hexbinID: "hx_x") == nil)
        #expect(FrictionTelemetry.payload(durationSeconds: 60, panCount: 0, hexbinID: "hx_x") == nil)
    }

    @Test("Hexbin matches the KMP algorithm byte for byte")
    func hexbinParity() {
        // Reference computed independently with Kotlin semantics (signed Long hex).
        #expect(AnonymizedHexbin.cell(latitude: 47.6062, longitude: -122.3321) == "hx_1090872a5456")
        #expect(AnonymizedHexbin.cell(latitude: 0, longitude: 0) == AnonymizedHexbin.unknownCell)
    }

    @Test("The queue persists across launches and drains in order")
    func queuePersists() async {
        let suite = "telemetry-tests-\(UUID().uuidString)"
        let first = TelemetryQueue(suiteName: suite, storageKey: "q")
        await first.enqueue(TelemetryEnvelope(path: "/a", payload: ["event": .string("one")], createdAt: .now))
        await first.enqueue(TelemetryEnvelope(path: "/a", payload: ["event": .string("two")], createdAt: .now))

        let relaunched = TelemetryQueue(suiteName: suite, storageKey: "q")
        #expect(await relaunched.count == 2)
        let sent = SentLog()
        await relaunched.setSender { envelope in await sent.append(envelope) }
        await relaunched.flush()
        #expect(await sent.events == ["one", "two"])
        #expect(await relaunched.count == 0)
    }

    @Test("A transient failure keeps the event queued")
    func transientFailureKeeps() async {
        let (queue, _, _) = freshQueue()
        await queue.enqueue(TelemetryEnvelope(path: "/a", payload: ["event": .string("x")], createdAt: .now))
        await queue.setSender { _ in throw APIError.timeout }
        await queue.flush()
        #expect(await queue.count == 1)
    }
}

private actor SentLog {
    var events: [String] = []
    func append(_ envelope: TelemetryEnvelope) {
        if case .string(let name)? = envelope.payload["event"] { events.append(name) }
    }
}

@Suite("Encounter context merge (KMP mergePatchLatestEncounter)")
struct EncounterContextTests {
    @Test("Only rows from the last 30 minutes are patched, with a tag union")
    func windowAndUnion() {
        let now = Date()
        let rows = [
            EncounterContextRepository.EncounterRow(id: "recent", encounteredAt: now.addingTimeInterval(-60), contextTags: ["cafe"], reportingUserID: "me"),
            EncounterContextRepository.EncounterRow(id: "old", encounteredAt: now.addingTimeInterval(-3_600), contextTags: [], reportingUserID: "me")
        ]
        let patches = EncounterContextRepository.patches(rows: rows, tags: ["study"], sensor: EncounterSensorContext(), reportingUserID: "me", now: now)
        #expect(patches.map(\.id) == ["recent"])
        #expect(patches.first?.body["context_tags"] as? [String] == ["cafe", "study"])
    }

    @Test("Sensor columns go only to rows this user reported")
    func sensorOwnership() {
        let now = Date()
        let rows = [
            EncounterContextRepository.EncounterRow(id: "mine", encounteredAt: now, contextTags: [], reportingUserID: "me"),
            EncounterContextRepository.EncounterRow(id: "theirs", encounteredAt: now, contextTags: [], reportingUserID: "peer")
        ]
        let sensor = EncounterSensorContext(barometricElevationMeters: 12)
        let patches = EncounterContextRepository.patches(rows: rows, tags: [], sensor: sensor, reportingUserID: "me", now: now)
        #expect(patches.map(\.id) == ["mine"])
    }

    @Test("Suggestions follow the KMP hour rules")
    func suggestions() {
        #expect(ContextTagTaxonomy.suggest(locationName: nil, hour: 23).map(\.id).prefix(2) == ["party", "bar"])
        #expect(ContextTagTaxonomy.suggest(locationName: "Blue Bottle Coffee", hour: 9).first?.id == "cafe")
        #expect(ContextTagTaxonomy.suggest(locationName: nil, hour: 4).count == 4)
    }

    @Test("Reconnect ordinal copy")
    @MainActor
    func ordinal() {
        #expect(PostConnectModel.ordinal(3) == "3rd")
    }
}
