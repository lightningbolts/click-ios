import CryptoKit
import Foundation
import Testing
@testable import Click

@Suite("Hub media")
struct HubMediaTests {
    private let hubID = "33333333-3333-4333-8333-333333333333"

    @Test("v2 hub media binds to the hub ID and its upload digest")
    func hubMediaVector() throws {
        let key = try ClickCryptoV2.generateEpochKey()
        let metadata = ClickCryptoV2.MediaMetadata(chatId: hubID, epoch: 2, senderDeviceId: "device-hub-01",
                                                   clientMessageId: "44444444-4444-4444-8444-444444444444", mediaCiphertextSha256: "")
        let photo = Data("jpeg bytes".utf8)
        let encrypted = try ClickCryptoV2.encryptMedia(metadata: metadata, epochKey: key, plaintext: photo)
        // The route recomputes this digest over the multipart file and must match.
        #expect(encrypted.mediaCiphertextSha256 == Data(SHA256.hash(data: encrypted.uploadedBytes)).base64EncodedString())
        #expect(encrypted.uploadedBytes.count == 12 + photo.count + 16)

        let checked = ClickCryptoV2.MediaMetadata(chatId: hubID, epoch: 2, senderDeviceId: "device-hub-01",
                                                  clientMessageId: metadata.clientMessageId, mediaCiphertextSha256: encrypted.mediaCiphertextSha256)
        #expect(try ClickCryptoV2.decryptMedia(metadata: checked, epochKey: key, uploadedBytes: encrypted.uploadedBytes) == photo)

        let otherHub = ClickCryptoV2.MediaMetadata(chatId: "55555555-5555-4555-8555-555555555555", epoch: 2, senderDeviceId: "device-hub-01",
                                                   clientMessageId: metadata.clientMessageId, mediaCiphertextSha256: encrypted.mediaCiphertextSha256)
        #expect(throws: (any Error).self) {
            try ClickCryptoV2.decryptMedia(metadata: otherHub, epochKey: key, uploadedBytes: encrypted.uploadedBytes)
        }
    }

    @Test("Object path follows {uid}/hub/{hubId}/<20>.bin")
    func objectPath() {
        let path = ChatRepository.hubMediaObjectPath(userID: "u1", hubID: hubID)
        let parts = path.split(separator: "/")
        #expect(parts.count == 4)
        #expect(parts[0] == "u1" && parts[1] == "hub" && parts[2] == Substring(hubID))
        #expect(parts[3].hasSuffix(".bin") && parts[3].count == 24)
    }

    @Test("Multipart body has each field, the file, and the closing boundary")
    func multipart() throws {
        var form = MultipartForm(boundary: "B")
        form.add("hub_id", "h1")
        form.addFile("file", fileName: "media.bin", mimeType: "application/octet-stream", data: Data([0xFF, 0x00]))
        let request = APIRequest.multipart(path: "/api/hub/media", form: form)
        #expect(request.headers["Content-Type"] == "multipart/form-data; boundary=B")
        #expect(request.method == .post)
        let expected = Data("--B\r\nContent-Disposition: form-data; name=\"hub_id\"\r\n\r\nh1\r\n--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"media.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            + Data([0xFF, 0x00]) + Data("\r\n--B--\r\n".utf8)
        #expect(request.body == expected)
    }

    @Test("Hub photos parse from a hub-media path (v2 and legacy)")
    func parseHubPhoto() throws {
        let legacy = try #require(MessageMedia.parse(messageType: "image",
                                                     metadata: ["media_path": "u/hub/\(hubID)/x.bin", "media_bucket": "hub-media", "is_encrypted_media": true],
                                                     decryptedContent: "", chatID: hubID))
        #expect(legacy.storagePath == "u/hub/\(hubID)/x.bin")
        #expect(legacy.v2 == nil)
        #expect(MessageMedia.parse(messageType: "image", metadata: ["media_path": "p"], decryptedContent: "", chatID: hubID) == nil)
    }

    @Test("Click Drop metadata: 24 h reveal, encounter when present, nothing for ordinary photos")
    func clickDropMetadata() {
        var draft = MediaDraft(kind: .image, data: Data([1]), mimeType: "image/jpeg")
        #expect(ChatRepository.clickDropMetadata(draft).isEmpty)
        draft.isClickDrop = true
        draft.encounterID = "enc-1"
        let now = Date(timeIntervalSince1970: 0)
        let meta = ChatRepository.clickDropMetadata(draft, now: now)
        #expect(meta["disposable_roll"] as? Bool == true)
        #expect(meta["collaboration_ttl"] as? String == "1970-01-02T00:00:00Z")
        #expect(meta["encounter_id"] as? String == "enc-1")
    }
}
