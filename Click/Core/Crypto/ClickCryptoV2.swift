import Foundation
import CryptoKit

/// Native Swift port of Click E2EE Protocol v2 (upgraded direct chats, cliques, and hubs).
/// Matches `compose.project.click.click.crypto.MessageCryptoV2` and `click-web/lib/chat/e2eeV2.ts`.
public enum ClickCryptoV2 {

    public static let cryptoVersion = 2
    public static let prefix = "e2e2:"
    public static let nonceBytes = 12
    public static let epochKeyBytes = 32
    public static let gcmTagBytes = 16
    public static let hkdfSalt = "click-platforms-e2ee-v2-hkdf-sha256"

    public static let spkiPrefix = Data([
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00
    ])

    // MARK: - Models

    public struct DeviceIdentityInfo: Sendable, Equatable {
        public let deviceID: String
        public let publicKeySpkiBase64: String
        public let cryptoVersion: Int

        public init(deviceID: String, publicKeySpkiBase64: String, cryptoVersion: Int = 2) {
            self.deviceID = deviceID
            self.publicKeySpkiBase64 = publicKeySpkiBase64
            self.cryptoVersion = cryptoVersion
        }
    }

    public struct MessageMetadata: Sendable, Equatable {
        public let chatId: String
        public let epoch: Int
        public let senderDeviceId: String
        public let clientMessageId: String

        public init(chatId: String, epoch: Int, senderDeviceId: String, clientMessageId: String) {
            self.chatId = chatId
            self.epoch = epoch
            self.senderDeviceId = senderDeviceId
            self.clientMessageId = clientMessageId
        }
    }

    public struct EpochKeyWrapMetadata: Sendable, Equatable {
        public let chatId: String
        public let epoch: Int
        public let senderDeviceId: String
        public let recipientDeviceId: String

        public init(chatId: String, epoch: Int, senderDeviceId: String, recipientDeviceId: String) {
            self.chatId = chatId
            self.epoch = epoch
            self.senderDeviceId = senderDeviceId
            self.recipientDeviceId = recipientDeviceId
        }
    }

    public struct MessageEnvelope: Sendable, Equatable {
        public let chatId: String
        public let epoch: Int
        public let senderDeviceId: String
        public let clientMessageId: String
        public let nonce: String
        public let ciphertext: String
    }

    public struct EpochKeyWrapEnvelope: Sendable, Equatable {
        public let chatId: String
        public let epoch: Int
        public let senderDeviceId: String
        public let recipientDeviceId: String
        public let ephemeralPublicKey: String
        public let nonce: String
        public let ciphertext: String
    }

    // MARK: - Replay Guard

    public final class ReplayGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var nonces = Set<String>()
        private var envelopeIdentities = Set<String>()

        public init() {}

        public var size: Int {
            lock.lock()
            defer { lock.unlock() }
            return envelopeIdentities.count
        }

        public func reserve(nonce: String, envelopeIdentity: String) throws {
            lock.lock()
            defer { lock.unlock() }

            if envelopeIdentities.contains(envelopeIdentity) {
                guard nonces.contains(nonce) else {
                    throw V2Error.replayIdentityMismatch
                }
                return
            }

            guard nonces.insert(nonce).inserted else {
                throw V2Error.replayOrNonceReuseDetected
            }
            envelopeIdentities.insert(envelopeIdentity)
        }

        public func hasSeenNonce(_ nonce: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return nonces.contains(nonce)
        }
    }

    // MARK: - Core Operations

    /// Generates a random 32-byte epoch key.
    public static func generateEpochKey() throws -> Data {
        var key = Data(count: epochKeyBytes)
        let status = key.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, epochKeyBytes, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw V2Error.randomGenerationFailed
        }
        return key
    }

    /// Generates a random client message ID UUID.
    public static func generateClientMessageId() -> String {
        UUID().uuidString.lowercased()
    }

    /// Encrypts message plaintext under a symmetric epoch key and authenticated metadata.
    public static func encryptMessage(
        metadata: MessageMetadata,
        epochKey: Data,
        plaintext: String,
        replayGuard: ReplayGuard? = nil
    ) throws -> String {
        try validateMessageMetadata(metadata)
        guard epochKey.count == epochKeyBytes else {
            throw V2Error.invalidEpochKeyLength
        }

        var nonce = Data(count: nonceBytes)
        let nonceStatus = nonce.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, nonceBytes, ptr.baseAddress!)
        }
        guard nonceStatus == errSecSuccess else {
            throw V2Error.randomGenerationFailed
        }
        let nonceB64 = nonce.base64EncodedString()

        let identity = messageIdentity(metadata: metadata, nonce: nonceB64)
        try replayGuard?.reserve(nonce: nonceB64, envelopeIdentity: identity)

        let aad = canonicalMessageMetadata(metadata)
        let symmetricKey = SymmetricKey(data: epochKey)
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(Data(plaintext.utf8), using: symmetricKey, nonce: gcmNonce, authenticating: aad)

        // WebCrypto and KMP format: ciphertext + 16-byte authentication tag
        let combinedCiphertext = sealedBox.ciphertext + sealedBox.tag

        let envelopeDict: [String: Any] = [
            "v": cryptoVersion,
            "type": "message",
            "chatId": metadata.chatId,
            "epoch": metadata.epoch,
            "senderDeviceId": metadata.senderDeviceId,
            "cryptoVersion": cryptoVersion,
            "clientMessageId": metadata.clientMessageId,
            "nonce": nonceB64,
            "ciphertext": combinedCiphertext.base64EncodedString()
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: envelopeDict, options: [])
        return prefix + jsonData.base64EncodedString()
    }

    /// Decrypts a v2 envelope message under an epoch key and authenticated metadata.
    public static func decryptMessage(
        metadata: MessageMetadata,
        epochKey: Data,
        envelope wire: String,
        replayGuard: ReplayGuard? = nil
    ) throws -> String {
        try validateMessageMetadata(metadata)
        guard epochKey.count == epochKeyBytes else {
            throw V2Error.invalidEpochKeyLength
        }

        let parsed = try parseMessageEnvelope(wire: wire)
        guard parsed.chatId == metadata.chatId,
              parsed.epoch == metadata.epoch,
              parsed.senderDeviceId == metadata.senderDeviceId,
              parsed.clientMessageId == metadata.clientMessageId else {
            throw V2Error.metadataMismatch
        }

        let identity = messageIdentity(metadata: metadata, nonce: parsed.nonce)
        try replayGuard?.reserve(nonce: parsed.nonce, envelopeIdentity: identity)

        guard let nonceData = Data(base64Encoded: parsed.nonce), nonceData.count == nonceBytes,
              let combined = Data(base64Encoded: parsed.ciphertext), combined.count >= gcmTagBytes else {
            throw V2Error.malformedEnvelope
        }

        let ciphertext = combined.dropLast(gcmTagBytes)
        let tag = combined.suffix(gcmTagBytes)

        let aad = canonicalMessageMetadata(metadata)
        let symmetricKey = SymmetricKey(data: epochKey)
        let gcmNonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)

        let decryptedData: Data
        do {
            decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
        } catch {
            throw V2Error.authenticationFailed
        }

        guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
            throw V2Error.invalidUtf8
        }
        return plaintext
    }

    /// Wraps an epoch key to a recipient device using ephemeral X25519 key agreement.
    public static func wrapEpochKey(
        metadata: EpochKeyWrapMetadata,
        epochKey: Data,
        recipientPublicKeySpkiBase64: String,
        replayGuard: ReplayGuard? = nil
    ) throws -> String {
        try validateWrapMetadata(metadata)
        guard epochKey.count == epochKeyBytes else {
            throw V2Error.invalidEpochKeyLength
        }

        let recipientPublicKey = try importPublicKeySpkiBase64(recipientPublicKeySpkiBase64)
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralSpki = spkiPrefix + ephemeralPrivateKey.publicKey.rawRepresentation
        let ephemeralSpkiB64 = ephemeralSpki.base64EncodedString()

        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        let aad = canonicalWrapMetadata(metadata)
        let wrappingKey = hkdfSha256(sharedSecret: sharedSecretData, info: aad)

        var nonce = Data(count: nonceBytes)
        let nonceStatus = nonce.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, nonceBytes, ptr.baseAddress!)
        }
        guard nonceStatus == errSecSuccess else {
            throw V2Error.randomGenerationFailed
        }
        let nonceB64 = nonce.base64EncodedString()

        let identity = wrapIdentity(metadata: metadata, nonce: nonceB64)
        try replayGuard?.reserve(nonce: nonceB64, envelopeIdentity: identity)

        let symmetricKey = SymmetricKey(data: wrappingKey)
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(epochKey, using: symmetricKey, nonce: gcmNonce, authenticating: aad)
        let combined = sealedBox.ciphertext + sealedBox.tag

        let envelopeDict: [String: Any] = [
            "v": cryptoVersion,
            "type": "epoch-key-wrap",
            "chatId": metadata.chatId,
            "epoch": metadata.epoch,
            "senderDeviceId": metadata.senderDeviceId,
            "recipientDeviceId": metadata.recipientDeviceId,
            "cryptoVersion": cryptoVersion,
            "ephemeralPublicKey": ephemeralSpkiB64,
            "nonce": nonceB64,
            "ciphertext": combined.base64EncodedString()
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: envelopeDict, options: [])
        return prefix + jsonData.base64EncodedString()
    }

    /// Unwraps an epoch key using the recipient's device private key.
    public static func unwrapEpochKey(
        metadata: EpochKeyWrapMetadata,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        envelope wire: String,
        replayGuard: ReplayGuard? = nil
    ) throws -> Data {
        try validateWrapMetadata(metadata)
        let parsed = try parseWrapEnvelope(wire: wire)

        guard parsed.chatId == metadata.chatId,
              parsed.epoch == metadata.epoch,
              parsed.senderDeviceId == metadata.senderDeviceId,
              parsed.recipientDeviceId == metadata.recipientDeviceId else {
            throw V2Error.metadataMismatch
        }

        let identity = wrapIdentity(metadata: metadata, nonce: parsed.nonce)
        try replayGuard?.reserve(nonce: parsed.nonce, envelopeIdentity: identity)

        let ephemeralPublicKey = try importPublicKeySpkiBase64(parsed.ephemeralPublicKey)
        let sharedSecret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        let aad = canonicalWrapMetadata(metadata)
        let wrappingKey = hkdfSha256(sharedSecret: sharedSecretData, info: aad)

        guard let nonceData = Data(base64Encoded: parsed.nonce), nonceData.count == nonceBytes,
              let combined = Data(base64Encoded: parsed.ciphertext), combined.count >= gcmTagBytes else {
            throw V2Error.malformedEnvelope
        }

        let ciphertext = combined.dropLast(gcmTagBytes)
        let tag = combined.suffix(gcmTagBytes)

        let symmetricKey = SymmetricKey(data: wrappingKey)
        let gcmNonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)

        let epochKey: Data
        do {
            epochKey = try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
        } catch {
            throw V2Error.authenticationFailed
        }

        guard epochKey.count == epochKeyBytes else {
            throw V2Error.invalidEpochKeyLength
        }
        return epochKey
    }

    /// Checks if a string has the v2 message wire prefix.
    public static func isEncrypted(_ content: String) -> Bool {
        content.hasPrefix(prefix)
    }

    // MARK: - Key & SPKI Helpers

    public static func importPublicKeySpkiBase64(_ base64Spki: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let spki = Data(base64Encoded: base64Spki.trimmingCharacters(in: .whitespacesAndNewlines)),
              spki.count == 44,
              spki.prefix(spkiPrefix.count) == spkiPrefix else {
            throw V2Error.invalidPublicKeySpki
        }
        let rawKey = spki.suffix(32)
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey)
    }

    public static func exportPublicKeySpkiBase64(_ publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
        let spki = spkiPrefix + publicKey.rawRepresentation
        return spki.base64EncodedString()
    }

    public static func deviceIDForSpki(_ base64Spki: String) throws -> String {
        guard let spki = Data(base64Encoded: base64Spki.trimmingCharacters(in: .whitespacesAndNewlines)),
              spki.count == 44 else {
            throw V2Error.invalidPublicKeySpki
        }
        let digest = SHA256.hash(data: spki)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internal Canonical Serialization

    public static func canonicalMessageMetadata(_ value: MessageMetadata) -> Data {
        let json = "{\"chatId\":\"\(value.chatId)\",\"epoch\":\(value.epoch),\"senderDeviceId\":\"\(value.senderDeviceId)\",\"cryptoVersion\":2,\"clientMessageId\":\"\(value.clientMessageId)\"}"
        return Data(json.utf8)
    }

    public static func canonicalWrapMetadata(_ value: EpochKeyWrapMetadata) -> Data {
        let json = "{\"chatId\":\"\(value.chatId)\",\"epoch\":\(value.epoch),\"senderDeviceId\":\"\(value.senderDeviceId)\",\"recipientDeviceId\":\"\(value.recipientDeviceId)\",\"cryptoVersion\":2,\"purpose\":\"epoch-key-wrap\"}"
        return Data(json.utf8)
    }

    private static func messageIdentity(metadata: MessageMetadata, nonce: String) -> String {
        "\(metadata.chatId)|\(metadata.epoch)|\(metadata.senderDeviceId)|\(metadata.clientMessageId)|\(nonce)"
    }

    private static func wrapIdentity(metadata: EpochKeyWrapMetadata, nonce: String) -> String {
        "\(metadata.chatId)|\(metadata.epoch)|\(metadata.senderDeviceId)|\(metadata.recipientDeviceId)|\(nonce)"
    }

    private static func hkdfSha256(sharedSecret: Data, info: Data) -> Data {
        let saltKey = SymmetricKey(data: Data(hkdfSalt.utf8))
        let prk = HMAC<SHA256>.authenticationCode(for: sharedSecret, using: saltKey)
        let prkKey = SymmetricKey(data: Data(prk))
        let okm = HMAC<SHA256>.authenticationCode(for: info + Data([0x01]), using: prkKey)
        return Data(okm).prefix(epochKeyBytes)
    }

    public static func parseMessageEnvelope(wire: String) throws -> MessageEnvelope {
        guard wire.hasPrefix(prefix) else { throw V2Error.notAnEnvelope }
        let base64 = String(wire.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw V2Error.malformedEnvelope
        }

        guard let v = json["v"] as? Int, v == cryptoVersion,
              let type = json["type"] as? String, type == "message",
              let chatId = json["chatId"] as? String,
              let epoch = json["epoch"] as? Int, epoch > 0,
              let senderDeviceId = json["senderDeviceId"] as? String,
              let clientMessageId = json["clientMessageId"] as? String,
              let nonce = json["nonce"] as? String,
              let ciphertext = json["ciphertext"] as? String else {
            throw V2Error.malformedEnvelope
        }

        return MessageEnvelope(
            chatId: chatId,
            epoch: epoch,
            senderDeviceId: senderDeviceId,
            clientMessageId: clientMessageId,
            nonce: nonce,
            ciphertext: ciphertext
        )
    }

    public static func parseWrapEnvelope(wire: String) throws -> EpochKeyWrapEnvelope {
        guard wire.hasPrefix(prefix) else { throw V2Error.notAnEnvelope }
        let base64 = String(wire.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw V2Error.malformedEnvelope
        }

        guard let v = json["v"] as? Int, v == cryptoVersion,
              let type = json["type"] as? String, type == "epoch-key-wrap",
              let chatId = json["chatId"] as? String,
              let epoch = json["epoch"] as? Int, epoch > 0,
              let senderDeviceId = json["senderDeviceId"] as? String,
              let recipientDeviceId = json["recipientDeviceId"] as? String,
              let ephemeralPublicKey = json["ephemeralPublicKey"] as? String,
              let nonce = json["nonce"] as? String,
              let ciphertext = json["ciphertext"] as? String else {
            throw V2Error.malformedEnvelope
        }

        return EpochKeyWrapEnvelope(
            chatId: chatId,
            epoch: epoch,
            senderDeviceId: senderDeviceId,
            recipientDeviceId: recipientDeviceId,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            ciphertext: ciphertext
        )
    }

    private static let identifierPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")

    private static func validateIdentifier(_ value: String, name: String) throws {
        let range = NSRange(location: 0, length: value.utf16.count)
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              identifierPattern.firstMatch(in: value, options: [], range: range) != nil else {
            throw V2Error.invalidIdentifier(name: name, value: value)
        }
    }

    private static func validateMessageMetadata(_ metadata: MessageMetadata) throws {
        try validateIdentifier(metadata.chatId, name: "chatId")
        try validateIdentifier(metadata.senderDeviceId, name: "senderDeviceId")
        try validateIdentifier(metadata.clientMessageId, name: "clientMessageId")
        guard metadata.epoch > 0 else { throw V2Error.invalidEpoch }
    }

    private static func validateWrapMetadata(_ metadata: EpochKeyWrapMetadata) throws {
        try validateIdentifier(metadata.chatId, name: "chatId")
        try validateIdentifier(metadata.senderDeviceId, name: "senderDeviceId")
        try validateIdentifier(metadata.recipientDeviceId, name: "recipientDeviceId")
        guard metadata.epoch > 0 else { throw V2Error.invalidEpoch }
    }

    public enum V2Error: Error, LocalizedError, Equatable {
        case notAnEnvelope
        case malformedEnvelope
        case metadataMismatch
        case authenticationFailed
        case invalidUtf8
        case invalidEpochKeyLength
        case invalidPublicKeySpki
        case invalidIdentifier(name: String, value: String)
        case invalidEpoch
        case replayIdentityMismatch
        case replayOrNonceReuseDetected
        case randomGenerationFailed

        public var errorDescription: String? {
            switch self {
            case .notAnEnvelope:
                return "The wire string is not an e2e2: envelope"
            case .malformedEnvelope:
                return "The e2e2: envelope structure is malformed"
            case .metadataMismatch:
                return "Authenticated E2EE v2 metadata does not match envelope"
            case .authenticationFailed:
                return "E2EE v2 AES-GCM authentication failed (tampered ciphertext or wrong key)"
            case .invalidUtf8:
                return "Decrypted plaintext is not valid UTF-8"
            case .invalidEpochKeyLength:
                return "Epoch key must be exactly 32 bytes"
            case .invalidPublicKeySpki:
                return "Invalid X25519 SPKI public key"
            case .invalidIdentifier(let name, let value):
                return "Field '\(name)' has invalid identifier value '\(value)'"
            case .invalidEpoch:
                return "Epoch must be a positive integer"
            case .replayIdentityMismatch:
                return "E2EE v2 replay identity mismatch"
            case .replayOrNonceReuseDetected:
                return "E2EE v2 replay or nonce reuse detected"
            case .randomGenerationFailed:
                return "Failed to generate cryptographically secure random bytes"
            }
        }
    }
}
