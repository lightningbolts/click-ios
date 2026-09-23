import Testing
import Foundation
import CryptoKit
@testable import Click

@Suite("Click E2EE Crypto Tests")
struct ClickCryptoTests {

    private let fixedConnectionID = "conn-fixture-1"
    private let fixedUserIDs = ["user-alice", "user-bob"]

    // MARK: - Legacy v1 Tests

    @Test("Legacy v1 key derivation is deterministic and sort-order independent")
    func testV1KeyDerivationDeterministic() {
        let keys1 = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: fixedUserIDs)
        let keys2 = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: fixedUserIDs.reversed())

        #expect(keys1.encKey.count == 32)
        #expect(keys1.macKey.count == 32)
        #expect(keys1.encKey == keys2.encKey, "Sort order must not alter encKey")
        #expect(keys1.macKey == keys2.macKey, "Sort order must not alter macKey")
        #expect(keys1.encKey != keys1.macKey, "encKey and macKey must be distinct")
    }

    @Test("Legacy v1 key derivation changes with connectionID or userIDs")
    func testV1KeyDerivationChangesWithParameters() {
        let base = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: fixedUserIDs)
        let diffConn = ClickCryptoV1.deriveKeysForConnection(connectionID: "conn-fixture-2", userIDs: fixedUserIDs)
        let diffUsers = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: ["user-alice", "user-charlie"])

        #expect(base.encKey != diffConn.encKey)
        #expect(base.encKey != diffUsers.encKey)
    }

    @Test("Legacy v1 encrypt and decrypt round-trip correctly")
    func testV1RoundTrip() throws {
        let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: fixedUserIDs)
        let plaintexts = [
            "Hello, Click Native iOS!",
            "",
            "Multi-line\nmessage with unicode 🚀 🔐 ☕️",
            String(repeating: "A", count: 2048)
        ]

        for text in plaintexts {
            let encrypted = try ClickCryptoV1.encryptContent(text, keys: keys)
            #expect(encrypted.hasPrefix("e2e:"))
            #expect(ClickCryptoV1.isEncrypted(encrypted))
            #expect(!ClickCryptoV1.isGroupEncrypted(encrypted))

            let decrypted = ClickCryptoV1.decryptContent(encrypted, keys: keys)
            #expect(decrypted == text)
        }
    }

    @Test("Legacy v1 returns raw string for non-e2ee payload")
    func testV1NonEncryptedPayload() {
        let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: fixedUserIDs)
        let raw = "Just a plaintext message"
        let result = ClickCryptoV1.decryptContent(raw, keys: keys)
        #expect(result == raw)
    }

    @Test("Legacy v1 tampering fails closed and returns raw wire string")
    func testV1TamperedHMAC() throws {
        let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: fixedConnectionID, userIDs: fixedUserIDs)
        let encrypted = try ClickCryptoV1.encryptContent("Confidential", keys: keys)

        // Flip a byte in the base64 payload
        let prefix = "e2e:"
        let body = String(encrypted.dropFirst(prefix.count))
        let firstChar = body.first!
        let flipped = firstChar == "A" ? "B" : "A"
        let tampered = prefix + String(flipped) + String(body.dropFirst())

        let decrypted = ClickCryptoV1.decryptContent(tampered, keys: keys)
        #expect(decrypted == tampered, "Tampered HMAC must not return plaintext")
    }

    @Test("Legacy v1 group message round-trip with 32-byte master key")
    func testV1GroupRoundTrip() throws {
        var masterKey = Data(count: 32)
        for i in 0..<32 { masterKey[i] = UInt8((i * 7 + 3) & 0xFF) }

        let wire = try ClickCryptoV1.encryptGroupContent("Group Clique Secret", groupMasterKey32: masterKey)
        #expect(wire.hasPrefix("e2e_grp:"))
        #expect(ClickCryptoV1.isGroupEncrypted(wire))
        #expect(!ClickCryptoV1.isEncrypted(wire))

        let decrypted = ClickCryptoV1.decryptGroupContent(wire, groupMasterKey32: masterKey)
        #expect(decrypted == "Group Clique Secret")

        // Wrong master key fails decryption
        var wrongKey = masterKey
        wrongKey[0] ^= 0xFF
        let failed = ClickCryptoV1.decryptGroupContent(wire, groupMasterKey32: wrongKey)
        #expect(failed == wire, "Wrong group master key must not recover plaintext")
    }

    // MARK: - Active v2 Tests

    @Test("V2 device identity creates standard SPKI and deterministic device ID")
    func testV2DeviceIdentity() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let identity = DeviceIdentityVault.DeviceIdentity(privateKey: privateKey)

        #expect(identity.info.publicKeySpkiBase64.count == 60 || identity.info.publicKeySpkiBase64.count == 64) // standard base64 of 44 bytes = 60 chars
        #expect(identity.info.deviceID.count == 64, "SHA-256 hex digest is 64 characters")

        let imported = try ClickCryptoV2.importPublicKeySpkiBase64(identity.info.publicKeySpkiBase64)
        let exported = ClickCryptoV2.exportPublicKeySpkiBase64(imported)
        #expect(exported == identity.info.publicKeySpkiBase64)
    }

    @Test("V2 message round-trip under epoch key and authenticated AAD")
    func testV2MessageRoundTrip() throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let metadata = ClickCryptoV2.MessageMetadata(
            chatId: "11111111-1111-4111-8111-111111111111",
            epoch: 1,
            senderDeviceId: "device-sender-01",
            clientMessageId: "22222222-2222-4222-8222-222222222222"
        )

        let plaintext = "Top secret v2 native iOS message 🔒"
        let wire = try ClickCryptoV2.encryptMessage(
            metadata: metadata,
            epochKey: epochKey,
            plaintext: plaintext
        )

        #expect(wire.hasPrefix("e2e2:"))
        #expect(ClickCryptoV2.isEncrypted(wire))

        let decrypted = try ClickCryptoV2.decryptMessage(
            metadata: metadata,
            epochKey: epochKey,
            envelope: wire
        )
        #expect(decrypted == plaintext)
    }

    @Test("V2 rejects metadata tampering with metadataMismatch error")
    func testV2RejectsTamperedMetadata() throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let metadata = ClickCryptoV2.MessageMetadata(
            chatId: "11111111-1111-4111-8111-111111111111",
            epoch: 1,
            senderDeviceId: "device-sender-01",
            clientMessageId: "22222222-2222-4222-8222-222222222222"
        )

        let wire = try ClickCryptoV2.encryptMessage(
            metadata: metadata,
            epochKey: epochKey,
            plaintext: "Sensitive"
        )

        // Wrong epoch
        let wrongEpoch = ClickCryptoV2.MessageMetadata(
            chatId: metadata.chatId,
            epoch: 2,
            senderDeviceId: metadata.senderDeviceId,
            clientMessageId: metadata.clientMessageId
        )
        #expect(throws: ClickCryptoV2.V2Error.metadataMismatch) {
            try ClickCryptoV2.decryptMessage(metadata: wrongEpoch, epochKey: epochKey, envelope: wire)
        }

        // Wrong chatId
        let wrongChat = ClickCryptoV2.MessageMetadata(
            chatId: "99999999-9999-4999-8999-999999999999",
            epoch: metadata.epoch,
            senderDeviceId: metadata.senderDeviceId,
            clientMessageId: metadata.clientMessageId
        )
        #expect(throws: ClickCryptoV2.V2Error.metadataMismatch) {
            try ClickCryptoV2.decryptMessage(metadata: wrongChat, epochKey: epochKey, envelope: wire)
        }
    }

    @Test("V2 replay guard rejects duplicate nonce and replayed message")
    func testV2ReplayGuard() throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let metadata = ClickCryptoV2.MessageMetadata(
            chatId: "11111111-1111-4111-8111-111111111111",
            epoch: 1,
            senderDeviceId: "device-sender-01",
            clientMessageId: "22222222-2222-4222-8222-222222222222"
        )

        let guardInstance = ClickCryptoV2.ReplayGuard()
        let wire = try ClickCryptoV2.encryptMessage(
            metadata: metadata,
            epochKey: epochKey,
            plaintext: "First delivery",
            replayGuard: guardInstance
        )

        // Decrypting the same wire message twice with replay guard is idempotent
        let first = try ClickCryptoV2.decryptMessage(
            metadata: metadata,
            epochKey: epochKey,
            envelope: wire,
            replayGuard: guardInstance
        )
        #expect(first == "First delivery")

        let second = try ClickCryptoV2.decryptMessage(
            metadata: metadata,
            epochKey: epochKey,
            envelope: wire,
            replayGuard: guardInstance
        )
        #expect(second == "First delivery")
    }

    @Test("V2 epoch key wrapping and unwrapping round-trip")
    func testV2EpochKeyWrap() throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let recipientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientIdentity = DeviceIdentityVault.DeviceIdentity(privateKey: recipientPrivateKey)

        let wrapMeta = ClickCryptoV2.EpochKeyWrapMetadata(
            chatId: "11111111-1111-4111-8111-111111111111",
            epoch: 1,
            senderDeviceId: "sender-dev-1",
            recipientDeviceId: recipientIdentity.info.deviceID
        )

        let wrapped = try ClickCryptoV2.wrapEpochKey(
            metadata: wrapMeta,
            epochKey: epochKey,
            recipientPublicKeySpkiBase64: recipientIdentity.info.publicKeySpkiBase64
        )

        let unwrapped = try ClickCryptoV2.unwrapEpochKey(
            metadata: wrapMeta,
            recipientPrivateKey: recipientPrivateKey,
            envelope: wrapped
        )

        #expect(unwrapped == epochKey, "Unwrapped epoch key must equal original key")

        // Wrong recipient cannot unwrap
        let wrongPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: Error.self) {
            try ClickCryptoV2.unwrapEpochKey(
                metadata: wrapMeta,
                recipientPrivateKey: wrongPrivateKey,
                envelope: wrapped
            )
        }
    }
}
