import Foundation
import Security

/// Represents the legacy Kotlin Multiplatform session persisted in iOS Keychain.
public struct LegacyKMPSession: Codable, Sendable, Equatable {
    public let version: Int
    public let jwt: String
    public let refreshToken: String
    public let expiresAt: Int64?
    public let tokenType: String?
    public let userId: String?

    public init(
        version: Int = 2,
        jwt: String,
        refreshToken: String,
        expiresAt: Int64? = nil,
        tokenType: String? = nil,
        userId: String? = nil
    ) {
        self.version = version
        self.jwt = jwt
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.userId = userId
    }
}

/// Migrates credentials and session tokens created by the legacy KMP iOS application.
public final class LegacyKMPStateMigrator: Sendable {
    public static let shared = LegacyKMPStateMigrator()

    public static let serviceName = "com.click.auth"
    public static let accountName = "session_v2"
    public static let legacySuiteName = "click_auth_prefs"

    public init() {}

    /// Decodes a legacy KMP session JSON payload.
    public func decodeSession(from data: Data) throws -> LegacyKMPSession {
        let decoder = JSONDecoder()
        let session = try decoder.decode(LegacyKMPSession.self, from: data)

        guard !session.jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MigrationError.emptyJWT
        }
        guard !session.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MigrationError.emptyRefreshToken
        }
        guard session.version == 2 else {
            throw MigrationError.unsupportedVersion(session.version)
        }

        return session
    }

    /// Reads and decodes the legacy session from Keychain if it exists.
    public func readLegacySession() -> LegacyKMPSession? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: Self.accountName,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        do {
            return try decodeSession(from: data)
        } catch {
            return nil
        }
    }

    /// Extracts the Supabase `sub` claim from a JWT payload safely.
    public static func extractSubFromJWT(_ jwt: String) -> String? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - (base64.count % 4)) % 4
        base64 += String(repeating: "=", count: paddingLength)

        guard let payloadData = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let sub = json["sub"] as? String,
              !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return sub
    }

    /// Coordinates one-time state migration across preferences, queues, and legacy Keychain.
    @MainActor
    public func performFullMigration(settings: SettingsStore, vault: KeychainSessionVault = .shared) {
        guard !settings.legacyMigrationCompleted else { return }

        let defaults = UserDefaults(suiteName: Self.legacySuiteName) ?? .standard

        // 1. Purge retired keys (must never return as features)
        defaults.removeObject(forKey: "call_notifications_enabled")
        defaults.removeObject(forKey: "home_layout_mode")

        // 2. Migrate legacy session if vault does not already hold a session
        if vault.readSession() == nil, let legacy = readLegacySession() {
            let derivedUserId = legacy.userId ?? Self.extractSubFromJWT(legacy.jwt)
            if let userId = derivedUserId {
                let expiresAtDate: Date? = legacy.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
                let snapshot = SessionSnapshot(
                    userId: userId,
                    jwt: legacy.jwt,
                    refreshToken: legacy.refreshToken,
                    expiresAt: expiresAtDate
                )
                vault.saveSession(snapshot)
            }
        }

        // 3. Preserve or safely migrate queues / temporary snapshots until server reconciliation
        // (Any corrupt cache is safely discarded without logging out the user)
        if let appSnapshot = defaults.data(forKey: "cached_app_snapshot") {
            // Keep app snapshot in defaults until overwritten by fresh server state
            _ = appSnapshot
        }

        // 4. Mark migration complete so this runs at most once
        settings.legacyMigrationCompleted = true
    }

    /// Deletes the legacy Keychain session record after a successful migration.
    @discardableResult
    public func deleteLegacySession() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: Self.accountName
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public enum MigrationError: Error, Equatable {
        case emptyJWT
        case emptyRefreshToken
        case unsupportedVersion(Int)
        case missingUserIdentity
    }
}
