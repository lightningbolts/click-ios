import Foundation
import CryptoKit
import CommonCrypto

/// Native Swift port of Click E2EE Protocol v1 (legacy direct and group chats).
/// Matches `compose.project.click.click.crypto.MessageCrypto` and `click-web/lib/chat/crypto.ts`.
public enum ClickCryptoV1 {

    public static let directPrefix = "e2e:"
    public static let groupPrefix = "e2e_grp:"
    public static let ivLength = 16
    public static let hmacLength = 32
    public static let salt = "click-platforms-e2ee-v1-2024"
    public static let groupMasterKeyBytes = 32

    public struct DerivedKeys: Sendable, Equatable {
        public let encKey: Data
        public let macKey: Data

        public init(encKey: Data, macKey: Data) {
            self.encKey = encKey
            self.macKey = macKey
        }
    }

    /// Derives pairwise AES and HMAC keys for a 1:1 direct connection.
    public static func deriveKeysForConnection(connectionID: String, userIDs: [String]) -> DerivedKeys {
        let sorted = userIDs.sorted()
        let input = "\(salt):\(sorted.joined(separator: ":")):\(connectionID)"
        let master = sha256(Data(input.utf8))
        let encKey = sha256(master + Data([0x01]))
        let macKey = sha256(master + Data([0x02]))
        return DerivedKeys(encKey: encKey, macKey: macKey)
    }

    /// Derives pairwise AES and HMAC keys from a 32-byte group master key.
    public static func deriveKeysFromGroupMaster(groupMasterKey32: Data) throws -> DerivedKeys {
        guard groupMasterKey32.count == groupMasterKeyBytes else {
            throw CryptoError.invalidKeyLength(expected: groupMasterKeyBytes, actual: groupMasterKey32.count)
        }
        let encKey = sha256(groupMasterKey32 + Data([0x01]))
        let macKey = sha256(groupMasterKey32 + Data([0x02]))
        return DerivedKeys(encKey: encKey, macKey: macKey)
    }

    /// Encrypts plaintext message content with `e2e:` prefix.
    public static func encryptContent(_ plaintext: String, keys: DerivedKeys) throws -> String {
        try encryptWithPrefix(plaintext, keys: keys, prefix: directPrefix)
    }

    /// Encrypts group message content with `e2e_grp:` prefix.
    public static func encryptGroupContent(_ plaintext: String, groupMasterKey32: Data) throws -> String {
        let keys = try deriveKeysFromGroupMaster(groupMasterKey32: groupMasterKey32)
        return try encryptWithPrefix(plaintext, keys: keys, prefix: groupPrefix)
    }

    /// Decrypts 1:1 direct message content with `e2e:` prefix.
    /// If content is plaintext or corrupted, returns the original content safely without throwing.
    public static func decryptContent(_ content: String, keys: DerivedKeys) -> String {
        decryptWithPrefix(content, keys: keys, prefix: directPrefix)
    }

    /// Decrypts group message content with `e2e_grp:` prefix.
    public static func decryptGroupContent(_ content: String, groupMasterKey32: Data) -> String {
        guard let keys = try? deriveKeysFromGroupMaster(groupMasterKey32: groupMasterKey32) else {
            return content
        }
        return decryptWithPrefix(content, keys: keys, prefix: groupPrefix)
    }

    /// Checks if content uses the v1 direct chat wire prefix.
    public static func isEncrypted(_ content: String) -> Bool {
        content.hasPrefix(directPrefix)
    }

    /// Checks if content uses the v1 group chat wire prefix.
    public static func isGroupEncrypted(_ content: String) -> Bool {
        content.hasPrefix(groupPrefix)
    }

    /// Checks if content uses any v1 wire prefix.
    public static func isAnyV1WireContent(_ content: String) -> Bool {
        isEncrypted(content) || isGroupEncrypted(content)
    }

    // MARK: - Internal Primitives

    private static func encryptWithPrefix(_ plaintext: String, keys: DerivedKeys, prefix: String) throws -> String {
        var iv = Data(count: ivLength)
        let ivResult = iv.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, ivLength, ptr.baseAddress!)
        }
        guard ivResult == errSecSuccess else {
            throw CryptoError.randomGenerationFailed
        }

        let plaintextData = Data(plaintext.utf8)
        let ciphertext = try aesCbcEncrypt(data: plaintextData, key: keys.encKey, iv: iv)

        let macKey = SymmetricKey(data: keys.macKey)
        let hmac = HMAC<SHA256>.authenticationCode(for: iv + ciphertext, using: macKey)

        let payload = iv + Data(hmac) + ciphertext
        return prefix + payload.base64EncodedString()
    }

    private static func decryptWithPrefix(_ content: String, keys: DerivedKeys, prefix: String) -> String {
        guard content.hasPrefix(prefix) else { return content }

        let base64Body = String(content.dropFirst(prefix.count))
        guard let payload = Data(base64Encoded: base64Body, options: [.ignoreUnknownCharacters]),
              payload.count >= ivLength + hmacLength + 1 else {
            return content
        }

        let iv = payload.subdata(in: 0..<ivLength)
        let storedHmac = payload.subdata(in: ivLength..<(ivLength + hmacLength))
        let ciphertext = payload.subdata(in: (ivLength + hmacLength)..<payload.count)

        let macKey = SymmetricKey(data: keys.macKey)
        let computed = HMAC<SHA256>.authenticationCode(for: iv + ciphertext, using: macKey)
        guard Data(computed) == storedHmac else {
            return content
        }

        guard let decrypted = try? aesCbcDecrypt(data: ciphertext, key: keys.encKey, iv: iv),
              let text = String(data: decrypted, encoding: .utf8) else {
            return content
        }

        return text
    }

    private static func aesCbcEncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            kCCKeySizeAES256,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress,
                            data.count,
                            bufferPtr.baseAddress,
                            bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.encryptionFailed(status: status)
        }

        buffer.count = numBytesEncrypted
        return buffer
    }

    private static func aesCbcDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            kCCKeySizeAES256,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress,
                            data.count,
                            bufferPtr.baseAddress,
                            bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.decryptionFailed(status: status)
        }

        buffer.count = numBytesDecrypted
        return buffer
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public enum CryptoError: Error, LocalizedError {
        case invalidKeyLength(expected: Int, actual: Int)
        case randomGenerationFailed
        case encryptionFailed(status: Int32)
        case decryptionFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidKeyLength(let expected, let actual):
                return "Invalid key length: expected \(expected) bytes, got \(actual)"
            case .randomGenerationFailed:
                return "Failed to generate cryptographically secure random bytes"
            case .encryptionFailed(let status):
                return "AES-CBC encryption failed with status \(status)"
            case .decryptionFailed(let status):
                return "AES-CBC decryption failed with status \(status)"
            }
        }
    }
}
