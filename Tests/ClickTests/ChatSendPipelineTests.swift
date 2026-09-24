import Foundation
import Testing
@testable import Click

/// A repo whose sends return a *server* ID (unlike the client ID), can fail on demand, and can
/// return a server copy of an in-flight message from `fetchMessages`.
private final class ServerIDRepo: ChatRepositoryProtocol, @unchecked Sendable {
    var fetched: [ChatMessageItem] = []
    var failSends = false
    var sendCount = 0
    var sentClientIDs: [String] = []

    func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String { chatID }
    func fetchMessages(conversation: ConversationIdentity, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] { fetched }
    func sendMessage(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, content: String,
                     replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String) async throws -> ChatMessageItem {
        sendCount += 1
        sentClientIDs.append(clientMessageID)
        if failSends { throw APIError.server(status: 500, code: nil, message: nil) }
        return ChatMessageItem(id: "server-\(clientMessageID)", chatID: conversation.chatID, senderID: currentUserID,
                               senderName: currentUserName, content: content, deliveryStatus: .sent, isOutgoing: true)
    }
    func editMessage(message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String, newContent: String) async throws {}
    func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {}
    func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {}
    func markRead(chatID: String, messageIDs: [String]) async throws {}
    func markDelivered(chatID: String, messageIDs: [String]) async throws {}
    func registerDevice() async throws {}
    func decodeRealtimeMessage(_ payload: RealtimeMessagePayload, conversation: ConversationIdentity, currentUserID: String) async throws -> ChatMessageItem {
        throw APIError.decoding
    }
}

@Suite("Chat send pipeline")
@MainActor
struct ChatSendPipelineTests {
    private func identity(_ chatID: String = "chat-1") -> ConversationIdentity {
        ConversationIdentity(chatID: chatID, connectionID: nil, peerUserID: "peer", peerDisplayName: "Peer")
    }

    @Test("The server row keeps the optimistic row's stable identity")
    func stableIdentityAcrossReplace() async {
        let repo = ServerIDRepo()
        let model = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", initialItems: [])
        model.composerText = "hello"
        await model.sendOrUpdateMessage()
        #expect(model.items.count == 1)
        let row = model.items[0]
        #expect(row.id.hasPrefix("server-"))
        #expect(row.stableID == repo.sentClientIDs.first)
        #expect(row.deliveryStatus == .sent)
    }

    @Test("A refresh that already contains the in-flight message never shows it twice")
    func refreshDedupesByClientID() async {
        let repo = ServerIDRepo()
        repo.failSends = true
        let model = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", initialItems: [])
        model.composerText = "hi"
        await model.sendOrUpdateMessage()
        let clientID = try! #require(repo.sentClientIDs.first)
        repo.fetched = [ChatMessageItem(id: "server-x", chatID: "chat-1", senderID: "me", senderName: "You", content: "hi",
                                        deliveryStatus: .sent, isOutgoing: true, clientMessageID: clientID)]
        await model.loadMessages()
        #expect(model.items.count == 1)
        #expect(model.items[0].id == "server-x")
    }

    @Test("Retry reuses the client ID and never duplicates the row")
    func retryReusesClientID() async {
        let repo = ServerIDRepo()
        repo.failSends = true
        let model = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", initialItems: [])
        model.composerText = "retry me"
        await model.sendOrUpdateMessage()
        #expect(model.items.first?.deliveryStatus == .failed)
        repo.failSends = false
        await model.retrySend(item: model.items[0])
        #expect(model.items.count == 1)
        #expect(Set(repo.sentClientIDs).count == 1)
        #expect(model.items[0].deliveryStatus == .sent)
    }

    @Test("Failed rows survive closing the chat and are restored on reopen")
    func pendingRowsRestoreOnReopen() async {
        let repo = ServerIDRepo()
        repo.failSends = true
        let store = PendingSendStore()
        let first = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", initialItems: [], pendingSends: store)
        first.composerText = "offline note"
        await first.sendOrUpdateMessage()
        first.onDisappear()

        let reopened = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", pendingSends: store)
        await reopened.onAppear(supabaseURL: nil, anonKey: nil, authToken: nil)
        #expect(reopened.items.map(\.content) == ["offline note"])
        #expect(reopened.items.first?.deliveryStatus == .failed)
    }

    @Test("Removing a failed row discards it from the pending store")
    func discardFailed() async {
        let repo = ServerIDRepo()
        repo.failSends = true
        let store = PendingSendStore()
        let model = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", initialItems: [], pendingSends: store)
        model.composerText = "bye"
        await model.sendOrUpdateMessage()
        model.discardFailed(item: model.items[0])
        #expect(model.items.isEmpty)
        #expect(store.attach(model, chatID: "chat-1").isEmpty)
    }

    @Test("Oversized or disallowed attachments are rejected before any row appears")
    func validatorRejectsBeforeSend() async {
        let big = MediaDraft(kind: .file, data: Data(count: MediaDraft.maxFileBytes + 1), mimeType: "application/pdf")
        #expect(MediaValidator.validate(big) == .tooLarge(limitMB: 2))
        let exe = MediaDraft(kind: .file, data: Data([1]), mimeType: "application/x-msdownload")
        #expect(MediaValidator.validate(exe) == .typeNotAllowed)
        let photo = MediaDraft(kind: .image, data: Data([1]), mimeType: "image/jpeg")
        #expect(MediaValidator.validate(photo) == nil)

        let repo = ServerIDRepo()
        let model = ConversationModel(identity: identity(), chatRepository: repo, currentUserID: "me", initialItems: [])
        await model.sendMedia(big)
        #expect(model.items.isEmpty)
        #expect(model.operationError?.contains("2 MB") == true)
    }

    @Test("Swipe-to-reply rubber band, hint and intent")
    func swipePhysics() {
        #expect(SwipeReplyPhysics.rubberBand(0) == 0)
        #expect(SwipeReplyPhysics.rubberBand(1000) < 90)
        #expect(SwipeReplyPhysics.rubberBand(-1000) > -90)
        #expect(SwipeReplyPhysics.rubberBand(200) > SwipeReplyPhysics.rubberBand(100))
        #expect(SwipeReplyPhysics.hintProgress(offset: 10) == 0)
        #expect(SwipeReplyPhysics.hintProgress(offset: 58) == 1)
        #expect(SwipeReplyPhysics.intent(dx: 3, dy: 12) == .vertical)
        #expect(SwipeReplyPhysics.intent(dx: 12, dy: 2) == .horizontal)
        #expect(SwipeReplyPhysics.intent(dx: 3, dy: 1) == nil)
    }
}
