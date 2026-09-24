import Foundation

/// Connection-flow funnel (spec §71.2, `POST /api/telemetry/connection-flow`), with the same
/// event names and sampling as KMP `ConnectionFlowTelemetry`: failures and drop-offs are always
/// sent; successes are sampled at 10%. Payloads carry counts and flags only — no user IDs,
/// tokens or coordinates.
public struct ConnectionFlowTelemetry: Sendable {
    public enum Event: String, CaseIterable, Sendable {
        // Always sent.
        case started = "proximity_handshake_started"
        case awaitingSelection = "proximity_handshake_awaiting_selection"
        case failed = "proximity_handshake_failed"
        case hostSelectionAbandoned = "proximity_host_selection_abandoned"
        case reconnectRateLimited = "proximity_reconnect_rate_limited"
        case recoveryTimeout = "proximity_recovery_poll_timeout"
        case recoveryIncomplete = "proximity_recovery_incomplete"
        case cliqueBlocked = "verified_clique_from_proximity_blocked"
        case atEventSkipped = "proximity_at_event_skipped"
        // Sampled.
        case matched = "proximity_handshake_matched"
        case pending = "proximity_handshake_pending"
        case offlineQueued = "proximity_handshake_offline_queued"
        case hostSelectionConfirmed = "proximity_host_selection_confirmed"
        case reconnectSaved = "proximity_reconnect_encounter_saved"
        case recoverySuccess = "proximity_recovery_poll_success"
        case cliqueCreated = "verified_clique_from_proximity_created"
        case atEventAttached = "proximity_at_event_attached"

        public var isAlwaysSent: Bool {
            switch self {
            case .started, .awaitingSelection, .failed, .hostSelectionAbandoned, .reconnectRateLimited,
                 .recoveryTimeout, .recoveryIncomplete, .cliqueBlocked, .atEventSkipped:
                true
            default:
                false
            }
        }
    }

    public static let successSampleRate = 0.10
    public static let path = "/api/telemetry/connection-flow"

    private let queue: TelemetryQueue
    private let sample: @Sendable () -> Double

    public init(queue: TelemetryQueue, sample: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.queue = queue
        self.sample = sample
    }

    /// Builds the wire payload, or nil when a sampled event is not selected.
    public func payload(
        _ event: Event,
        peerCount: Int? = nil,
        isGroup: Bool? = nil,
        isReconnect: Bool? = nil,
        selectedCount: Int? = nil,
        candidateCount: Int? = nil,
        reason: String? = nil
    ) -> [String: TelemetryValue]? {
        guard event.isAlwaysSent || sample() < Self.successSampleRate else { return nil }
        var body: [String: TelemetryValue] = ["event": .string(event.rawValue)]
        if let peerCount { body["peer_count"] = .int(max(0, peerCount)) }
        if let isGroup { body["is_group"] = .bool(isGroup) }
        if let isReconnect { body["is_reconnect"] = .bool(isReconnect) }
        if let selectedCount { body["selected_count"] = .int(max(0, selectedCount)) }
        if let candidateCount { body["candidate_count"] = .int(max(0, candidateCount)) }
        if let reason, !reason.isEmpty { body["reason"] = .string(Self.sanitizedReason(reason)) }
        return body
    }

    public func track(
        _ event: Event,
        peerCount: Int? = nil,
        isGroup: Bool? = nil,
        isReconnect: Bool? = nil,
        selectedCount: Int? = nil,
        candidateCount: Int? = nil,
        reason: String? = nil
    ) async {
        guard let body = payload(event, peerCount: peerCount, isGroup: isGroup, isReconnect: isReconnect,
                                 selectedCount: selectedCount, candidateCount: candidateCount, reason: reason) else { return }
        await queue.enqueue(TelemetryEnvelope(path: Self.path, payload: body, createdAt: .now))
    }

    /// Reasons are short machine codes; anything that could carry an ID or a coordinate is cut.
    nonisolated static func sanitizedReason(_ reason: String) -> String {
        let scrubbed = reason
            .replacingOccurrences(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, with: "<id>", options: .regularExpression)
            .replacingOccurrences(of: #"-?\d{1,3}\.\d{3,}"#, with: "<n>", options: .regularExpression)
        return String(scrubbed.prefix(128))
    }
}
