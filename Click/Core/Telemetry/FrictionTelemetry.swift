import Foundation
import Observation

/// Map friction sessions (spec §71.1, `POST /api/telemetry/friction`), mirroring KMP
/// `TelemetryBatcher`: a session is only reported when it lasted ≥30 s with at least one pan,
/// located by an opaque ~500 m hexbin (never coordinates). The "go touch grass" nudge appears
/// after 4 minutes when the user panned in the last 45 s without a meaningful action.
@Observable
@MainActor
public final class FrictionTelemetry {
    public nonisolated static let path = "/api/telemetry/friction"
    public nonisolated static let minimumDuration: TimeInterval = 30
    public nonisolated static let grassNudgeAfter: TimeInterval = 240
    public nonisolated static let activePanWindow: TimeInterval = 45

    private let queue: TelemetryQueue
    private var startedAt: Date?
    private var panCount = 0
    private var lastPanAt: Date?
    private var hexbinID = AnonymizedHexbin.unknownCell
    private(set) public var grassNudgeDismissed = false

    public init(queue: TelemetryQueue) {
        self.queue = queue
    }

    public func beginSession(now: Date = .now) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    public func updateLocation(latitude: Double, longitude: Double) {
        hexbinID = AnonymizedHexbin.cell(latitude: latitude, longitude: longitude)
    }

    public func recordPan(now: Date = .now) {
        beginSession(now: now)
        panCount += 1
        lastPanAt = now
    }

    /// Opening a beacon, a profile, creating something: a pan-free outcome resets the nudge.
    public func recordMeaningfulAction() {
        lastPanAt = nil
    }

    public func dismissGrassNudge() {
        grassNudgeDismissed = true
    }

    public func showsGrassNudge(now: Date = .now) -> Bool {
        guard !grassNudgeDismissed, let startedAt, let lastPanAt else { return false }
        return now.timeIntervalSince(startedAt) >= Self.grassNudgeAfter
            && now.timeIntervalSince(lastPanAt) <= Self.activePanWindow
    }

    /// Ends the session (Map disappears or app backgrounds) and queues it when it qualifies.
    public func endSession(now: Date = .now) async {
        guard let startedAt else { return }
        let duration = Int(now.timeIntervalSince(startedAt))
        let pans = panCount
        let cell = hexbinID
        self.startedAt = nil
        panCount = 0
        lastPanAt = nil
        grassNudgeDismissed = false
        guard let payload = Self.payload(durationSeconds: duration, panCount: pans, hexbinID: cell) else { return }
        await queue.enqueue(TelemetryEnvelope(path: Self.path, payload: payload, createdAt: now))
    }

    nonisolated static func payload(durationSeconds: Int, panCount: Int, hexbinID: String) -> [String: TelemetryValue]? {
        guard durationSeconds >= Int(minimumDuration), panCount > 0 else { return nil }
        return [
            "event": .string("map_friction_anomaly"),
            "duration_sec": .int(durationSeconds),
            "pan_count": .int(panCount),
            "action_taken": .null,
            "hexbin_id": .string(hexbinID)
        ]
    }
}

/// Opaque ~500 m neighbourhood key, byte-for-byte the same as KMP `AnonymizedHexbin`
/// (`floor(coord × 200)` buckets → FNV-1a 64 → signed hex, padded, first 12 chars).
public enum AnonymizedHexbin {
    public static let unknownCell = "hx_unknown"

    public nonisolated static func cell(latitude: Double, longitude: Double) -> String {
        guard latitude.isFinite, longitude.isFinite, !(latitude == 0 && longitude == 0) else { return unknownCell }
        let latBucket = Int((latitude * 200).rounded(.down))
        let lonBucket = Int((longitude * 200).rounded(.down))
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(latBucket):\(lonBucket)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Kotlin `Long.toString(16)` is signed ("-1a2b…"); keep the same text so cells match.
        let signed = String(Int64(bitPattern: hash), radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - signed.count)) + signed
        return "hx_" + padded.prefix(12)
    }
}
