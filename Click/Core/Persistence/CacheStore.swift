import Foundation

/// Small per-user JSON cache for read models that should paint immediately on the next launch.
///
/// Values are keyed by domain *and* signed-in user so one account's cache is never shown to
/// another. Cached values are presentation seeds only — never server truth — so a decode
/// failure (schema drift between builds) simply discards the entry and the caller refetches.
public actor CacheStore {
    public static let shared = CacheStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load<Value: Decodable>(_ type: Value.Type, key: String, userID: String) -> Value? {
        guard let data = defaults.data(forKey: Self.storageKey(key, userID: userID)) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    public func save<Value: Encodable>(_ value: Value, key: String, userID: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey(key, userID: userID))
    }

    public func remove(key: String, userID: String) {
        defaults.removeObject(forKey: Self.storageKey(key, userID: userID))
    }

    private static func storageKey(_ key: String, userID: String) -> String {
        "cache.v1.\(key).\(userID)"
    }
}
