import Foundation
import Security

/// E2EE v2 chat epoch keys shared with the Notification Service extension through a keychain
/// group only this team's app and extension can read, so a push shows the decrypted message
/// (like Signal) instead of "Sent you a message". Keys never leave the device
/// (`ThisDeviceOnly`) and are readable after first unlock, when pushes to a locked phone arrive.
enum SharedEpochKeyStore {
    static let accessGroup = "W4C3V9Z2N4.compose.project.click.click.shared"
    private static let service = "com.click.e2ee.v2.epoch-keys"

    private static func account(chatID: String, epoch: Int) -> String {
        "\(chatID.lowercased()):\(epoch)"
    }

    private static func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func save(_ key: Data, chatID: String, epoch: Int) {
        let base = query(account: account(chatID: chatID, epoch: epoch))
        let attributes: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static func key(chatID: String, epoch: Int) -> Data? {
        var request = query(account: account(chatID: chatID, epoch: epoch))
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Signing out: no previews for a previous account.
    static func removeAll() {
        SecItemDelete(query() as CFDictionary)
    }
}
