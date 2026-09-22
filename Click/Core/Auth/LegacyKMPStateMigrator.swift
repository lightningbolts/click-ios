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
    }
}
