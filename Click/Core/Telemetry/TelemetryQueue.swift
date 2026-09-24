import Foundation

/// One telemetry POST waiting to be sent. Payloads are built only by the typed emitters below,
/// which never include user IDs, message content or raw coordinates.
public struct TelemetryEnvelope: Codable, Equatable, Sendable {
    public let path: String
    public let payload: [String: TelemetryValue]
    public let createdAt: Date
}

public enum TelemetryValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }
}

/// Persisted, batched telemetry delivery (spec §71): events survive relaunches, flush serially
/// on foreground/background (at most `maxPerFlush`, under the server's 60/min limit), are
/// dropped after 7 days, and never block the UI. Delivery failures keep the event queued.
public actor TelemetryQueue {
    private let defaults: UserDefaults
    private let storageKey: String
    private var pending: [TelemetryEnvelope]
    private var isFlushing = false
    private var sender: (@Sendable (TelemetryEnvelope) async throws -> Void)?

    public static let maxQueued = 200
    public static let maxPerFlush = 30
    public static let maxAge: TimeInterval = 7 * 86_400

    /// `suiteName` nil uses standard defaults; tests pass their own suite.
    public init(suiteName: String? = nil, storageKey: String = "telemetry.queue.v1") {
        let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TelemetryEnvelope].self, from: data) {
            pending = decoded
        } else {
            pending = []
        }
    }

    public func setSender(_ sender: @escaping @Sendable (TelemetryEnvelope) async throws -> Void) {
        self.sender = sender
    }

    public func enqueue(_ envelope: TelemetryEnvelope) {
        pending.append(envelope)
        if pending.count > Self.maxQueued { pending.removeFirst(pending.count - Self.maxQueued) }
        persist()
    }

    public var count: Int { pending.count }
    public var snapshot: [TelemetryEnvelope] { pending }

    public func flush(now: Date = .now) async {
        guard !isFlushing, let sender else { return }
        isFlushing = true
        defer { isFlushing = false }
        pending.removeAll { now.timeIntervalSince($0.createdAt) > Self.maxAge }
        var sent = 0
        while sent < Self.maxPerFlush, let next = pending.first {
            do {
                try await sender(next)
                pending.removeFirst()
                sent += 1
            } catch let error as APIError {
                // 4xx other than rate limiting will never succeed: drop it. Transient: stop.
                switch error {
                case .validation, .forbidden, .notFound, .decoding:
                    pending.removeFirst()
                default:
                    persist()
                    return
                }
            } catch {
                persist()
                return
            }
        }
        persist()
    }

    public func removeAll() {
        pending.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
