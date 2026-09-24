import Foundation

/// Per-endpoint freshness windows (stale-while-revalidate). A value younger than its window is
/// served without a network call; older values stay on screen while one coalesced refresh runs.
public enum CachePolicy {
    public static let peerProfile: TimeInterval = 5 * 60
    public static let beaconDetail: TimeInterval = 2 * 60
    public static let engagement: TimeInterval = 60
    public static let hubInfo: TimeInterval = 10 * 60
    public static let displayNames: TimeInterval = 60 * 60
    public static let inbox: TimeInterval = 60
}

/// In-memory, session-scoped freshness cache with in-flight coalescing.
///
/// Keys must include the signed-in user where the value is user-specific. `removeAll()` runs on
/// sign-out so nothing outlives the session.
public actor FreshnessCache {
    public static let shared = FreshnessCache()

    private struct Entry {
        let value: any Sendable
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<any Sendable, Error>] = [:]

    public init() {}

    /// The cached value (fresh or stale) and whether it is still inside `maxAge`.
    public func cached<Value: Sendable>(_ key: String, as type: Value.Type, maxAge: TimeInterval, now: Date = .now) -> (value: Value, isFresh: Bool)? {
        guard let entry = entries[key], let value = entry.value as? Value else { return nil }
        return (value, now.timeIntervalSince(entry.storedAt) < maxAge)
    }

    /// Returns a fresh cached value without fetching, otherwise runs `fetch` once for all
    /// concurrent callers and stores the result. Failures are not cached.
    public func value<Value: Sendable>(
        _ key: String,
        maxAge: TimeInterval,
        now: Date = .now,
        force: Bool = false,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if !force, let hit = cached(key, as: Value.self, maxAge: maxAge, now: now), hit.isFresh {
            return hit.value
        }
        if let running = inFlight[key] {
            if let value = try await running.value as? Value { return value }
        }
        let task = Task<any Sendable, Error> { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let fetched = try await task.value
        guard let value = fetched as? Value else { throw APIError.decoding }
        entries[key] = Entry(value: value, storedAt: .now)
        return value
    }

    public func store<Value: Sendable>(_ value: Value, key: String) {
        entries[key] = Entry(value: value, storedAt: .now)
    }

    public func invalidate(_ key: String) {
        entries[key] = nil
    }

    public func invalidate(prefix: String) {
        for key in entries.keys where key.hasPrefix(prefix) {
            entries[key] = nil
        }
    }

    public func removeAll() {
        entries.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }
}
