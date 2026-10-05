import Foundation
import Testing
import UIKit
@testable import Click

/// Isolated mock transport for the develop endpoints.
final class DropsMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Click Drop develop", .serialized)
@MainActor
struct ClickDropDevelopTests {
    private struct NoopRepo: ChatRepositoryProtocol {
        func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String { chatID }
        func fetchMessages(conversation: ConversationIdentity, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] { [] }
        func sendMessage(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, content: String,
                         replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String) async throws -> ChatMessageItem {
            throw ChatRepositoryError.unresolvedChat
        }
        func editMessage(message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String, newContent: String) async throws {}
        func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {}
        func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {}
        func markRead(chatID: String, messageIDs: [String]) async throws {}
        func markDelivered(chatID: String, messageIDs: [String]) async throws {}
        func registerDevice() async throws {}
        func decodeRealtimeMessage(_ payload: RealtimeMessagePayload, conversation: ConversationIdentity, currentUserID: String) async throws -> ChatMessageItem {
            throw ChatRepositoryError.unresolvedChat
        }
    }

    private func service() -> ClickDropService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DropsMockURLProtocol.self]
        return ClickDropService(api: ClickAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: URLSession(configuration: config),
            tokenProvider: { "token" }
        ))
    }

    private func drop(_ id: String, revealAt: Date, gated: Bool) -> ChatMessageItem {
        var metadata: [String: Any] = [
            "media_url": "https://signed.example/\(id)",
            "disposable_roll": true,
            "reveal_at": ISO8601DateFormatter().string(from: revealAt)
        ]
        if gated { metadata["drop_gated"] = true }
        let media = MessageMedia.parse(messageType: "image", metadata: metadata, decryptedContent: " ", chatID: "chat-1")
        return ChatMessageItem(id: id, chatID: "chat-1", senderID: "peer", senderName: "Peer", content: "",
                               messageType: .image, isOutgoing: false, media: media)
    }

    private func model(_ items: [ChatMessageItem], flagOn: Bool) -> ConversationModel {
        let flags = FeatureFlags(api: nil)
        flags.override(.dropsDevelop, flagOn)
        let identity = ConversationIdentity(chatID: "chat-1", connectionID: "conn-1", peerUserID: "peer", peerDisplayName: "Peer")
        return ConversationModel(identity: identity, chatRepository: NoopRepo(), currentUserID: "me",
                                 initialItems: items, drops: service(), features: flags)
    }

    @Test("pending before reveal, ready after, developed once the viewer has developed it")
    func stateMachine() {
        let reveal = Date(timeIntervalSince1970: 1_000)
        #expect(ClickDropDevelopState.resolve(revealAt: reveal, developedAt: nil, now: reveal.addingTimeInterval(-1)) == .pending(revealAt: reveal))
        #expect(ClickDropDevelopState.resolve(revealAt: reveal, developedAt: reveal, now: reveal.addingTimeInterval(-1)) == .pending(revealAt: reveal))
        #expect(ClickDropDevelopState.resolve(revealAt: reveal, developedAt: nil, now: reveal) == .ready)
        #expect(ClickDropDevelopState.resolve(revealAt: reveal, developedAt: reveal, now: reveal.addingTimeInterval(5)) == .developed)
        #expect(ClickDropDevelopState.resolve(revealAt: nil, developedAt: nil).isPending)
    }

    @Test("Gated drops parse their preview-only marker and the original's v2 fields")
    func parsesGatedDrop() {
        let media = MessageMedia.parse(messageType: "image", metadata: [
            "media_url": "https://signed.example/p",
            "disposable_roll": true,
            "drop_gated": true,
            "reveal_at": "2026-10-01T10:00:00Z",
            "drop_original": ["epoch": 3, "sender_device_id": "dev-1", "client_message_id": "cm-1.original",
                              "media_ciphertext_sha256": "abc="]
        ], decryptedContent: " ", chatID: "chat-1")
        #expect(media?.isGatedDrop == true)
        #expect(media?.dropOriginalV2 == ClickCryptoV2.MediaMetadata(chatId: "chat-1", epoch: 3, senderDeviceId: "dev-1",
                                                                   clientMessageId: "cm-1.original", mediaCiphertextSha256: "abc="))
        #expect(media?.revealAt == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
    }

    @Test("Develop responses map to typed results")
    func parsesDevelopResponse() {
        let body = """
        {"drops":[
          {"kind":"chat","id":"a","status":"developed","developed_at":"2026-10-01T10:05:00Z","url":"https://signed.example/o"},
          {"kind":"chat","id":"b","status":"pending","reveal_at":"2026-10-02T10:00:00Z"},
          {"kind":"chat","id":"c","status":"not_found"}
        ]}
        """
        let results = ClickDropService.parseDevelop(Data(body.utf8))
        #expect(results.map(\.status) == [.developed, .pending, .notFound])
        #expect(results[0].originalURL == URL(string: "https://signed.example/o"))
        #expect(results[1].originalURL == nil)
    }

    @Test("Legacy drops keep developing on their own when drops_develop is off")
    func legacyDropsOutsideFlag() {
        let item = drop("m1", revealAt: .now.addingTimeInterval(-60), gated: false)
        #expect(model([item], flagOn: false).dropState(for: item) == nil)
        #expect(model([item], flagOn: true).dropState(for: item) == .ready)
    }

    @Test("Gated drops always use tap-to-develop, even outside the cohort")
    func gatedDropsAlwaysDevelop() {
        let item = drop("m1", revealAt: .now.addingTimeInterval(-60), gated: true)
        #expect(model([item], flagOn: false).dropState(for: item) == .ready)
    }

    @Test("Develop all develops only ready drops and marks them developed")
    func developAll() async {
        let ready = drop("m1", revealAt: .now.addingTimeInterval(-60), gated: true)
        let alsoReady = drop("m2", revealAt: .now.addingTimeInterval(-30), gated: true)
        let pending = drop("m3", revealAt: .now.addingTimeInterval(3_600), gated: true)
        let conversation = model([ready, alsoReady, pending], flagOn: true)
        DropsMockURLProtocol.requests = []
        DropsMockURLProtocol.handler = { _ in (200, """
        {"drops":[
          {"kind":"chat","id":"m1","status":"developed","developed_at":"2026-10-01T10:05:00Z","url":"https://signed.example/o1"},
          {"kind":"chat","id":"m2","status":"developed","developed_at":"2026-10-01T10:05:00Z","url":"https://signed.example/o2"}
        ]}
        """) }

        #expect(conversation.readyDrops.map(\.id) == ["m1", "m2"])
        await conversation.develop(conversation.items)

        let body = try? JSONSerialization.jsonObject(with: DropsMockURLProtocol.requests.first?.httpBodyStreamData ?? Data()) as? [String: Any]
        let sent = (body?["drops"] as? [[String: String]])?.compactMap { $0["id"] }
        #expect(sent == ["m1", "m2"])
        #expect(conversation.dropState(for: ready) == .developed)
        #expect(conversation.dropState(for: alsoReady) == .developed)
        #expect(conversation.dropState(for: pending)?.isPending == true)
        #expect(conversation.readyDrops.isEmpty)
        #expect(conversation.freshlyDevelopedDropIDs == ["m1", "m2"])
    }

    @Test("A failed develop leaves drops ready and says so calmly")
    func developFailure() async {
        let item = drop("m1", revealAt: .now.addingTimeInterval(-60), gated: true)
        let conversation = model([item], flagOn: true)
        DropsMockURLProtocol.handler = { _ in (500, "{}") }
        await conversation.develop([item])
        #expect(conversation.dropState(for: item) == .ready)
        #expect(conversation.operationError != nil)
        #expect(conversation.developingDropIDs.isEmpty)
    }

    @Test("The gated preview is small and pixelated")
    func previewIsCoarse() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        }.jpegData(compressionQuality: 0.9)!
        let preview = try #require(ClickDropPixelation.previewJPEG(from: photo))
        let image = try #require(UIImage(data: preview))
        #expect(max(image.size.width, image.size.height) <= 480)
        #expect(preview.count < photo.count)
    }

    @Test("Pixelation fills the frame to its edges, with no pale strip")
    func pixelationReachesEdges() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Sides that don't divide into the blocks, as most photos' don't.
        let size = CGSize(width: 333, height: 480)
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let pixelated = try #require(ClickDropPixelation.pixelated(photo))
        let cg = try #require(pixelated.cgImage)
        #expect(cg.width == 333 && cg.height == 480)
        // Drawn over white, as a JPEG's missing pixels come out: any gap at an edge shows pale.
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        let bytes = try #require(rendered.cgImage?.dataProvider?.data as Data?)
        let row = try #require(rendered.cgImage?.bytesPerRow)
        // Every edge pixel stays dark: corners and the middle of each side.
        for (x, y) in [(0, 0), (332, 0), (0, 479), (332, 479), (166, 0), (166, 479), (0, 240), (332, 240)] {
            let i = y * row + x * 4
            #expect(bytes[i] < 40 && bytes[i + 1] < 40 && bytes[i + 2] < 40, "pixel \(x),\(y)")
        }
    }
}

private extension URLRequest {
    /// URLProtocol sees uploads as a body stream, not `httpBody`.
    var httpBodyStreamData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
