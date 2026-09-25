import Foundation
import Security

/// Thread-safe Keychain vault for persisting active user sessions.
public final class KeychainSessionVault: Sendable {
    public static let shared = KeychainSessionVault()

    public static let serviceName = "com.click.auth"
    public static let accountName = "session_v2"

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var fallback: [String: SessionSnapshot] = [:]

        func set(_ value: SessionSnapshot?, account: String) {
            lock.lock()
            defer { lock.unlock() }
            fallback[account] = value
        }

        func get(account: String) -> SessionSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return fallback[account]
        }
    }

    private static let storage = Storage()
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
    private static let migration = Once()

    /// What a Keychain read found. `unavailable` (device locked, protected data not yet
    /// available) is *not* "signed out" — callers wait and read again.
    public enum ReadResult: Equatable, Sendable {
        case found(SessionSnapshot)
        case notFound
        case unavailable
    }
    private let account: String

    /// `account` is overridable only so tests never touch the real session item.
    public init(account: String = KeychainSessionVault.accountName) {
        self.account = account
    }

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
            kSecAttrAccount: account
        ]
        // Readable after the first unlock since boot: background launches (prewarm, push) and
        // token refreshes while the phone is locked must see — and persist — the session.
        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: Self.accessibility
        ]

        var status = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.serviceName,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: Self.accessibility
            ]
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == -34018 {
            // Unit-test environments may lack Keychain entitlements.
            Self.storage.set(session, account: account)
            return true
        }
        guard status == errSecSuccess else {
            return false
        }

        Self.storage.set(nil, account: account)
        return true
    }

    /// Reads and validates the active session from Keychain.
    public func readSession() -> SessionSnapshot? {
        if case .found(let snapshot) = read() { return snapshot }
        return nil
    }

    public func read() -> ReadResult {
        if let fallback = Self.storage.get(account: account) {
            return .found(fallback)
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecInteractionNotAllowed { return .unavailable }

        guard status == errSecSuccess, let data = item as? Data,
              let record = try? JSONDecoder().decode(LegacyKMPSession.self, from: data),
              record.version == 2,
              !record.jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notFound
        }

        let storedUserId = record.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUserId = storedUserId?.isEmpty == false
            ? storedUserId
            : LegacyKMPStateMigrator.extractSubFromJWT(record.jwt)
        guard let resolvedUserId, !resolvedUserId.isEmpty else {
            return .notFound
        }

        let expiresAt = record.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        let snapshot = SessionSnapshot(
            userId: resolvedUserId,
            jwt: record.jwt,
            refreshToken: record.refreshToken,
            expiresAt: expiresAt
        )
        // Items written by older builds were unlocked-only; re-save once per launch (the
        // update also sets the wider accessibility) so the next locked launch can read it.
        if Self.migration.claim() { saveSession(snapshot) }
        return .found(snapshot)
    }

    /// Deletes the session record on explicit sign-out or hard authentication invalidation.
    @discardableResult
    public func deleteSession() -> Bool {
        Self.storage.set(nil, account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || status == -34018
    }
}
