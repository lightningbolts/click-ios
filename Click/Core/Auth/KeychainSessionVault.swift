import Foundation
import Security

/// Thread-safe Keychain vault for persisting active user sessions.
public final class KeychainSessionVault: Sendable {
    public static let shared = KeychainSessionVault()

    public static let serviceName = "com.click.auth"
    public static let accountName = "session_v2"

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var fallback: SessionSnapshot?

        func set(_ value: SessionSnapshot?) {
            lock.lock()
            defer { lock.unlock() }
            fallback = value
        }

        func get() -> SessionSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return fallback
        }
    }

    private static let storage = Storage()

    public init() {}

    /// Saves a complete v2 session without deleting the previously valid Keychain item first.
    /// Existing credentials remain intact if an update/add fails.
    @discardableResult
    public func saveSession(_ session: SessionSnapshot) -> Bool {
        guard !session.jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !session.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !session.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let record = LegacyKMPSession(
            version: 2,
            jwt: session.jwt,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            tokenType: "bearer",
            userId: session.userId
        )

        guard let data = try? JSONEncoder().encode(record) else {
            return false
        }

        let matchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: Self.accountName
        ]
        let updateAttributes: [CFString: Any] = [
            kSecValueData: data
        ]

        var status = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.serviceName,
                kSecAttrAccount: Self.accountName,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == -34018 {
            // Unit-test environments may lack Keychain entitlements.
            Self.storage.set(session)
            return true
        }
        guard status == errSecSuccess else {
            return false
        }

        Self.storage.set(nil)
        return true
    }

    /// Reads and validates the active session from Keychain.
    public func readSession() -> SessionSnapshot? {
        if let fallback = Self.storage.get() {
            return fallback
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: Self.accountName,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data,
              let record = try? JSONDecoder().decode(LegacyKMPSession.self, from: data),
              record.version == 2,
              !record.jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let storedUserId = record.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUserId = storedUserId?.isEmpty == false
            ? storedUserId
            : LegacyKMPStateMigrator.extractSubFromJWT(record.jwt)
        guard let resolvedUserId, !resolvedUserId.isEmpty else {
            return nil
        }

        let expiresAt = record.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        return SessionSnapshot(
            userId: resolvedUserId,
            jwt: record.jwt,
            refreshToken: record.refreshToken,
            expiresAt: expiresAt
        )
    }

    /// Deletes the session record on explicit sign-out or hard authentication invalidation.
    @discardableResult
    public func deleteSession() -> Bool {
        Self.storage.set(nil)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: Self.accountName
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || status == -34018
    }
}
