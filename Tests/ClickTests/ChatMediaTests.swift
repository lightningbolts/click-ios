import CryptoKit
import Testing
import Foundation
@testable import Click

@Suite("Chat media crypto and wire formats")
struct ChatMediaTests {
    private let key = Data((1...32).map { UInt8($0) })
    private let meta = ClickCryptoV2.MediaMetadata(
        chatId: "chat-vector-1", epoch: 3, senderDeviceId: "device-web-1",
        clientMessageId: "c0ffee00-0000-4000-8000-000000000001",
        mediaCiphertextSha256: "zKMi1zaoNEuxIXz5K1AUMhmC1aGmUaNSrqiPK+vDNic="
    )

    @Test("Decrypts a v2 media payload produced by click-web encryptMediaPayload")
    func webVector() throws {
        let payload = try #require(Data(base64Encoded: "/z6PceDAvh7zXjuXPhB+KXzh62wwNhXgCR8a/ofFQZRgF41yNrmYf5cVmBgWzg=="))
        let plain = try ClickCryptoV2.decryptMedia(metadata: meta, epochKey: key, uploadedBytes: payload)
        #expect(String(decoding: plain, as: UTF8.self) == "click media vector")
    }

    @Test("Media authorization AAD matches click-web authorizeMedia")
    func webAuthorizationVector() throws {
        let wire = "e2e2:eyJjaGF0SWQiOiJjaGF0LXZlY3Rvci0xIiwiZXBvY2giOjMsInNlbmRlckRldmljZUlkIjoiZGV2aWNlLXdlYi0xIiwiY2xpZW50TWVzc2FnZUlkIjoiYzBmZmVlMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAxIiwibWVkaWFDaXBoZXJ0ZXh0U2hhMjU2IjoiektNaTF6YW9ORXV4SVh6NUsxQVVNaG1DMWFHbVVhTlNycWlQSyt2RE5pYz0iLCJ2IjoyLCJ0eXBlIjoibWVkaWEiLCJjcnlwdG9WZXJzaW9uIjoyLCJub25jZSI6ImlmVHpjT3BQb3VuMDk0clUiLCJjaXBoZXJ0ZXh0IjoiSUM5b3Vmb2NveVY0SmtGeUgvaUN6aW1aU3Jhb3dScWZrQWFJZjRTQVFvRzVXVmZoVjRKZFFKUUJWV1YwM3Q3ZGd3PT0ifQ=="
        let json = try #require(Data(base64Encoded: String(wire.dropFirst(5))))
        let root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let nonce = try #require(Data(base64Encoded: root["nonce"] as? String ?? ""))
        let combined = try #require(Data(base64Encoded: root["ciphertext"] as? String ?? ""))
        let box = try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: combined.dropLast(16), tag: combined.suffix(16))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: ClickCryptoV2.canonicalMediaAuthorizationMetadata(meta))
        #expect(String(decoding: plain, as: UTF8.self) == "click-e2ee-v2-media-authorization")
    }

    @Test("v2 media round-trips, binds the digest, and rejects tampering or the wrong chat")
    func roundTrip() throws {
        let input = ClickCryptoV2.MediaMetadata(chatId: "chat-1", epoch: 1, senderDeviceId: "dev-1", clientMessageId: "cm-1", mediaCiphertextSha256: "")
        let encrypted = try ClickCryptoV2.encryptMedia(metadata: input, epochKey: key, plaintext: Data("photo".utf8))
        #expect(Data(SHA256.hash(data: encrypted.uploadedBytes)).base64EncodedString() == encrypted.mediaCiphertextSha256)
        let bound = ClickCryptoV2.MediaMetadata(chatId: "chat-1", epoch: 1, senderDeviceId: "dev-1", clientMessageId: "cm-1",
                                                mediaCiphertextSha256: encrypted.mediaCiphertextSha256)
        #expect(try ClickCryptoV2.decryptMedia(metadata: bound, epochKey: key, uploadedBytes: encrypted.uploadedBytes) == Data("photo".utf8))

        var tampered = encrypted.uploadedBytes
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: ClickCryptoV2.V2Error.self) {
            _ = try ClickCryptoV2.decryptMedia(metadata: bound, epochKey: key, uploadedBytes: tampered)
        }
        let wrongChat = ClickCryptoV2.MediaMetadata(chatId: "chat-2", epoch: 1, senderDeviceId: "dev-1", clientMessageId: "cm-1",
                                                    mediaCiphertextSha256: encrypted.mediaCiphertextSha256)
        #expect(throws: ClickCryptoV2.V2Error.self) {
            _ = try ClickCryptoV2.decryptMedia(metadata: wrongChat, epochKey: key, uploadedBytes: encrypted.uploadedBytes)
        }
        let envelope = try #require(Data(base64Encoded: String(encrypted.authorizationEnvelope.dropFirst(5))))
        let root = try #require(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        #expect(root["type"] as? String == "media")
        #expect(root["mediaCiphertextSha256"] as? String == encrypted.mediaCiphertextSha256)
        #expect(root["clientMessageId"] as? String == "cm-1")
    }

    @Test("Legacy media bytes round-trip and fail closed on a bad MAC")
    func legacyBytes() throws {
        let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: "conn", userIDs: ["a", "b"])
        let blob = try ClickCryptoV1.encryptMediaBytes(Data("voice".utf8), keys: keys)
        #expect(try ClickCryptoV1.decryptMediaBytes(blob, keys: keys) == Data("voice".utf8))
        var bad = blob
        bad[20] ^= 0xFF
        #expect(throws: ClickCryptoV1.CryptoError.self) { _ = try ClickCryptoV1.decryptMediaBytes(bad, keys: keys) }
        // Some legacy uploads stored base64 text of the ciphertext.
        #expect(ChatRepository.normalizedMediaPayload(Data(blob.base64EncodedString().utf8)) == blob)
    }

    @Test("Attachment descriptors encode/decode and reject unsafe paths")
    func envelopes() throws {
        let v1 = AttachmentEnvelope(version: 1, name: "notes.pdf", mime: "application/pdf", size: 12, path: "chat/u/1-notes.pdf", key: "a2V5", sha256: "c2hh")
        #expect(AttachmentEnvelope.decode(try v1.encoded()) == v1)
        let v2 = AttachmentEnvelope(version: 2, name: "a.txt", mime: "text/plain", size: 1, path: "chat/u/a.txt", key: nil, sha256: "ZGln")
        let wire = try v2.encoded()
        #expect(wire.hasPrefix("ccx:v2:"))
        #expect(!wire.contains("\"key\""))
        #expect(AttachmentEnvelope.decode(wire) == v2)
        #expect(AttachmentEnvelope.decode("ccx:v1:{\"name\":\"x\",\"mime\":\"y\",\"path\":\"../etc\",\"key\":\"k\",\"sha256\":\"s\"}") == nil)
    }

    @Test("Media parsing reads legacy URLs, v2 metadata, and file descriptors")
    func parsing() throws {
        let legacy = MessageMedia.parse(
            messageType: "image",
            metadata: ["media_url": "https://x.supabase.co/storage/v1/object/sign/chat-attachments/chat-1/u-1/1-media.jpg?token=t",
                       "original_mime_type": "image/jpeg", "is_encrypted_media": true],
            decryptedContent: " ",
            chatID: "chat-1"
        )
        #expect(legacy?.kind == .image)
        #expect(legacy?.storagePath == "chat-1/u-1/1-media.jpg")
        #expect(legacy?.v2 == nil)

        let v2Meta: [String: Any] = [
            "media_ciphertext_sha256": "zKMi1zaoNEuxIXz5K1AUMhmC1aGmUaNSrqiPK+vDNic=", "media_epoch": 2,
            "media_sender_device_id": "dev", "media_client_message_id": "cm", "media_path": "chat-1/u-1/f.bin",
            "attachment_name": "report.pdf", "attachment_mime": "application/pdf", "attachment_size": 4096
        ]
        let file = MessageMedia.parse(messageType: "file", metadata: v2Meta, decryptedContent: "ccx:v2:{}", chatID: "chat-1")
        #expect(file?.kind == .file)
        #expect(file?.v2?.epoch == 2)
        #expect(file?.fileName == "report.pdf")
        #expect(file?.fileExtension == "pdf")
        #expect(MessageMedia.parse(messageType: "text", metadata: [:], decryptedContent: "hi", chatID: "c") == nil)
    }
}
