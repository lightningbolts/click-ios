import Foundation
import Synchronization

/// A thread-safe in-memory dictionary. An actor keeps its session cache here so screens can read
/// it synchronously and paint what's already known on their first frame, not after an `await`.
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let storage = Mutex<[Key: Value]>([:])

    public init() {}

    public subscript(key: Key) -> Value? {
        get { storage.withLock { $0[key] } }
        set { storage.withLock { $0[key] = newValue } }
    }

    public func removeAll() {
        storage.withLock { $0.removeAll() }
    }

    /// Every entry, for persisting the cache.
    public var all: [Key: Value] { storage.withLock { $0 } }

    /// Adds entries without replacing ones already known (fresher, from this session).
    public func fill(_ entries: [Key: Value]) {
        storage.withLock { $0.merge(entries) { current, _ in current } }
    }

    /// Keeps the newest `limit` entries by `date`.
    public func trim(to limit: Int, by date: (Value) -> Date) {
        storage.withLock { entries in
            guard entries.count > limit else { return }
            for key in entries.sorted(by: { date($0.value) < date($1.value) }).prefix(entries.count - limit).map(\.key) {
                entries[key] = nil
            }
        }
    }
}
