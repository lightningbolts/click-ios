import Foundation
import CryptoKit
import Security

/// Device-bound X25519 identity stored in iOS Keychain with `WhenUnlockedThisDeviceOnly`.
/// Satisfies §36 and `Docs/E2EE_COMPATIBILITY.md`.
public final class DeviceIdentityVault: @unchecked Sendable {

    public static let shared = DeviceIdentityVault()

    public static let keychainService = "com.click.e2ee.v2"
    public static let keychainAccount = "x25519_identity_private_key"

    public struct DeviceIdentity: Sendable {
        public let privateKey: Curve25519.KeyAgreement.PrivateKey
        public let info: ClickCryptoV2.DeviceIdentityInfo

        public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
            self.privateKey = privateKey
            let spki = ClickCryptoV2.spkiPrefix + privateKey.publicKey.rawRepresentation
            let spkiB64 = spki.base64EncodedString()
            let deviceID = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
            self.info = ClickCryptoV2.DeviceIdentityInfo(
                deviceID: deviceID,
                publicKeySpkiBase64: spkiB64,
                cryptoVersion: ClickCryptoV2.cryptoVersion
            )
        }
    }

    private let lock = NSLock()
    private var cachedIdentity: DeviceIdentity?

    public init() {}

    /// Loads the existing device identity from Keychain or generates and persists a new one.
    public func loadOrCreate() throws -> DeviceIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedIdentity {
            return cached
        }

        if let storedRaw = try readFromKeychain() {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: storedRaw)
            let identity = DeviceIdentity(privateKey: privateKey)
            cachedIdentity = identity
            return identity
        }

        let newPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        try saveToKeychain(rawPrivateKey: newPrivateKey.rawRepresentation)
        let identity = DeviceIdentity(privateKey: newPrivateKey)
        cachedIdentity = identity
        return identity
    }

    /// Clears cached in-memory identity (for tests).
    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedIdentity = nil
    }

    // MARK: - Keychain Access

    private func readFromKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw VaultError.invalidKeyData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw VaultError.keychainReadFailed(status: status)
        }
    }

    private func saveToKeychain(rawPrivateKey: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: rawPrivateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateQuery: [String: Any] = [
            kSecValueData as String: rawPrivateKey
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        let addQuery = baseQuery.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw VaultError.keychainWriteFailed(status: retryStatus)
            }
            return
        }

        guard addStatus == errSecSuccess else {
            throw VaultError.keychainWriteFailed(status: addStatus)
        }
    }

    public enum VaultError: Error, LocalizedError {
        case invalidKeyData
        case keychainReadFailed(status: OSStatus)
        case keychainWriteFailed(status: OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidKeyData:
                return "Stored E2EE device identity key has invalid length (expected 32 bytes)"
            case .keychainReadFailed(let status):
                return "Failed to read E2EE device identity from Keychain: status \(status)"
            case .keychainWriteFailed(let status):
                return "Failed to write E2EE device identity to Keychain: status \(status)"
            }
        }
    }
}
