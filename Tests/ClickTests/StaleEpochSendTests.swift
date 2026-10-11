import Foundation
import Security
import Testing
@testable import Click

/// A chat server whose current epoch was wrapped before the peer added a device: like the real
/// write gate, it refuses messages until a new epoch covers every active device.
final class StaleEpochMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, [String: Any]) -> (Int, Any))?
    nonisolated(unsafe) static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
        let (status, body) = Self.handler?(request, (try? JSONFields.object(data)) ?? [:]) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Unsigned CI test hosts have no Keychain entitlement (-34018); the vault has no fallback.
private let keychainAvailable: Bool = {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "tests.stale-epoch.probe",
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
}()

@Suite("Sending after the chat's devices changed", .serialized, .enabled(if: keychainAvailable, "needs the Keychain"))
struct StaleEpochSendTests {
    private let chatID = "6f0b6a8e-2f43-4c55-9a3e-0c2b1f6d9a10"
    private let me = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"

    @Test func aSendRightAfterOpeningTheChatRotatesFirst() async throws {
        let vault = DeviceIdentityVault(account: "tests.stale-epoch.\(UUID().uuidString)")
        let own = try vault.loadOrCreate()
        defer { try? vault.discard(own) }
        let peerDevice = DeviceIdentityVault.DeviceIdentity(privateKey: .init())

        // Epoch 1 was wrapped for this device alone; the peer's device registered since.
        let wrap = try ClickCryptoV2.wrapEpochKey(
            metadata: .init(chatId: chatID, epoch: 1, senderDeviceId: own.info.deviceID, recipientDeviceId: own.info.deviceID),
            epochKey: try ClickCryptoV2.generateEpochKey(),
            recipientPublicKeySpkiBase64: own.info.publicKeySpkiBase64
        )
        var epoch: (number: Int, fingerprint: String, wrap: String) = (1, "devices-before-the-peer-joined", wrap)
        let devices: [[String: Any]] = [(me, own), (peer, peerDevice)].map { user, identity in
            ["id": UUID().uuidString, "user_id": user, "device_id": identity.info.deviceID,
             "identity_public_key": identity.info.publicKeySpkiBase64, "key_algorithm": "X25519", "crypto_version": 2]
        }
        StaleEpochMockURLProtocol.requests = []
        StaleEpochMockURLProtocol.handler = { request, body in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("POST", "/api/chat/devices"):
                return (201, ["device": [:]])
            case ("GET", "/api/chat/devices"):
                return (200, ["devices": devices])
            case ("GET", "/api/chat/epochs"):
                return (200, ["current_epoch": epoch.number, "membership_fingerprint": epoch.fingerprint, "envelopes": [
                    ["epoch": epoch.number, "recipient_device_id": own.info.deviceID,
                     "sender_device_id": own.info.deviceID, "envelope": epoch.wrap],
                ]])
            case ("POST", "/api/chat/epochs"):
                let envelopes = body["envelopes"] as? [[String: Any]] ?? []
                guard envelopes.count == 2,
                      let mine = envelopes.first(where: { $0["recipient_device_id"] as? String == own.info.deviceID }),
                      let mineWrap = mine["envelope"] as? String else { return (400, [:]) }
                epoch = (body["epoch"] as? Int ?? 0, body["membership_fingerprint"] as? String ?? "", mineWrap)
                return (201, ["epoch": [:]])
            case ("GET", "/api/chat/messages"):
                return (200, ["messages": []])
            case ("POST", "/api/chat/messages"):
                guard epoch.number == 2 else {
                    return (409, ["error": "E2EE v2 is required for this chat", "code": "E2EE_V2_REQUIRED"])
                }
                return (201, ["message": ["id": UUID().uuidString, "chat_id": self.chatID, "user_id": self.me,
                                          "content": body["content"] ?? "", "time_created": 1_790_000_000_000]])
            default:
                return (404, [:])
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StaleEpochMockURLProtocol.self]
        let repository = ChatRepository(apiClient: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ), vault: vault)
        let conversation = ConversationIdentity(chatID: chatID, peerUserID: peer, peerDisplayName: "Peer")

        // Opening the thread reads the epoch for reading only: it must not vouch for a send.
        _ = try await repository.fetchMessages(conversation: conversation, currentUserID: me, cursor: nil)
        let sent = try await repository.sendMessage(
            conversation: conversation, currentUserID: me, currentUserName: "Me", content: "hi",
            replyToID: nil, replyToSnippet: nil, replyToSenderName: nil, clientMessageID: ClickCryptoV2.generateClientMessageId()
        )

        #expect(sent.content == "hi")
        let writes = StaleEpochMockURLProtocol.requests.filter { $0.hasPrefix("POST /api/chat/e") || $0.hasPrefix("POST /api/chat/m") }
        #expect(writes == ["POST /api/chat/epochs", "POST /api/chat/messages"])
    }
}
