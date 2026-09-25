import Foundation

/// Small per-user JSON cache for read models that should paint immediately on the next launch.
///
/// Values are keyed by domain *and* signed-in user so one account's cache is never shown to
/// another. Cached values are presentation seeds only — never server truth — so a decode
/// failure (schema drift between builds) simply discards the entry and the caller refetches.
public actor CacheStore {
    public static let shared = CacheStore()

    /// nil: the on-disk `LocalStore` (the app). Injected defaults: tests.
    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    public func load<Value: Decodable>(_ type: Value.Type, key: String, userID: String) -> Value? {
        loadWithDate(type, key: key, userID: userID)?.value
    }

    /// The cached value and when it was saved (for stale-while-revalidate decisions).
    public func loadWithDate<Value: Decodable>(_ type: Value.Type, key: String, userID: String) -> (value: Value, savedAt: Date)? {
        guard let defaults else {
            if let stored = LocalStore.shared.load(Value.self, key: Self.storeKey(key), userID: userID) { return stored }
            // One-time move out of UserDefaults (which loads its whole plist at launch).
            let legacyKey = Self.storageKey(key, userID: userID)
            guard let data = UserDefaults.standard.data(forKey: legacyKey),
                  let value = try? decoder.decode(Value.self, from: data) else { return nil }
            LocalStore.shared.saveRaw(data, key: Self.storeKey(key), userID: userID)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return (value, .distantPast)
        }
        guard let data = defaults.data(forKey: Self.storageKey(key, userID: userID)),
              let value = try? decoder.decode(Value.self, from: data) else { return nil }
        return (value, .distantPast)
    }

    public func save<Value: Encodable>(_ value: Value, key: String, userID: String) {
        guard let defaults else {
            LocalStore.shared.save(value, key: Self.storeKey(key), userID: userID)
            return
        }
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey(key, userID: userID))
    }

    public func remove(key: String, userID: String) {
        guard let defaults else {
            LocalStore.shared.remove(key: Self.storeKey(key), userID: userID)
            UserDefaults.standard.removeObject(forKey: Self.storageKey(key, userID: userID))
            return
        }
        defaults.removeObject(forKey: Self.storageKey(key, userID: userID))
    }

    private static func storageKey(_ key: String, userID: String) -> String {
        "cache.v1.\(key).\(userID)"
    }

    private static func storeKey(_ key: String) -> String {
        "cache.\(key)"
    }
}
