import Testing
import Foundation
@testable import Click

@Suite("Chat Conversation Model Tests")
struct ChatConversationTests {
    private enum MockError: Error {
        case forced
    }

    private final class MockChatRepo: ChatRepositoryProtocol, @unchecked Sendable {
        var messagesToReturn: [ChatMessageItem] = []
        var sentMessages: [ChatMessageItem] = []
        var markedReadIDs: [String] = []
        var markedDeliveredIDs: [String] = []
        var editedIDs: [String: String] = [:]
        var deletedIDs: [String] = []
        var reactionWrites: [(messageID: String, reactionType: String, adding: Bool)] = []
        var failDelete = false
        var failReaction = false
        var failEdit = false

        func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String {
            chatID
        }

        func fetchMessages(
            chatID: String,
            connectionID: String?,
            peerUserID: String,
            currentUserID: String,
            cursor: Int64?,
            limit: Int
        ) async throws -> [ChatMessageItem] {
            messagesToReturn
        }

        func sendMessage(
            chatID: String,
            connectionID: String?,
            peerUserID: String,
            currentUserID: String,
            currentUserName: String,
            content: String,
            replyToID: String?,
            replyToSnippet: String?,
            replyToSenderName: String?,
            clientMessageID: String
        ) async throws -> ChatMessageItem {
            let item = ChatMessageItem(
                id: clientMessageID,
                chatID: chatID,
                senderID: currentUserID,
                senderName: currentUserName,
                content: content,
                deliveryStatus: .sent,
                isOutgoing: true,
                replyToID: replyToID,
                replyToSnippet: replyToSnippet,
                replyToSenderName: replyToSenderName
            )
            sentMessages.append(item)
            return item
        }

        func editMessage(
            message: ChatMessageItem,
            connectionID: String?,
            peerUserID: String,
            currentUserID: String,
            newContent: String
        ) async throws {
            if failEdit { throw MockError.forced }
            editedIDs[message.id] = newContent
        }

        func deleteMessage(messageID: String) async throws {
            if failDelete { throw MockError.forced }
            deletedIDs.append(messageID)
        }

        func setReaction(messageID: String, reactionType: String, adding: Bool) async throws {
            if failReaction { throw MockError.forced }
            reactionWrites.append((messageID, reactionType, adding))
        }

        func markRead(chatID: String, messageIDs: [String]) async throws {
            markedReadIDs.append(contentsOf: messageIDs)
        }

        func markDelivered(chatID: String, messageIDs: [String]) async throws {
            markedDeliveredIDs.append(contentsOf: messageIDs)
        }

        func registerDevice() async throws {}

        func decodeRealtimeMessage(
            _ payload: RealtimeMessagePayload,
            connectionID: String?,
            peerUserID: String,
            peerDisplayName: String,
            currentUserID: String
        ) async throws -> ChatMessageItem {
            ChatMessageItem(
                id: payload.id,
                chatID: payload.chatID,
                senderID: payload.senderID,
                senderName: payload.senderID == currentUserID ? "You" : peerDisplayName,
                content: payload.content,
                createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
                deliveryStatus: .delivered,
                isOutgoing: payload.senderID == currentUserID
            )
        }
    }

    private func makeIdentity() -> ConversationIdentity {
        ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
    }

    @Test("ConversationModel loads messages and marks unread messages as read")
    @MainActor
    func testLoadMessages() async {
        let repo = MockChatRepo()
        repo.messagesToReturn = [
            ChatMessageItem(
                id: "msg-unread-1",
                chatID: "chat-1",
                senderID: "user-peer",
                senderName: "Peer",
                content: "Hey!",
                createdAt: Date(),
                deliveryStatus: .delivered,
                isOutgoing: false
            )
        ]

        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self"
        )

        await model.loadMessages()

        #expect(model.items.count == 1)
        #expect(model.items.first?.id == "msg-unread-1")
        #expect(repo.markedReadIDs.contains("msg-unread-1"))
    }

    @Test("ConversationModel sends message optimistically and updates status")
    @MainActor
    func testSendMessageOptimistic() async {
        let repo = MockChatRepo()
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self"
        )

        model.composerText = "Hello from Native iOS!"
        await model.sendOrUpdateMessage()

        #expect(model.items.count == 1)
        #expect(model.items.first?.content == "Hello from Native iOS!")
        #expect(model.items.first?.deliveryStatus == .sent)
        #expect(model.items.first?.isOutgoing == true)
        #expect(model.composerText.isEmpty)
    }

    @Test("ConversationModel includes reply quote when replyTarget is set")
    @MainActor
    func testReplyMessage() async {
        let repo = MockChatRepo()
        let initial = ChatMessageItem(
            id: "msg-orig",
            chatID: "chat-1",
            senderID: "user-peer",
            senderName: "Peer",
            content: "What coffee do you like?",
            deliveryStatus: .read,
            isOutgoing: false
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [initial]
        )

        model.replyTarget = initial
        model.composerText = "Flat white, please!"
        await model.sendOrUpdateMessage()

        #expect(model.items.count == 2)
        let sent = model.items.last!
        #expect(sent.content == "Flat white, please!")
        #expect(sent.replyToID == "msg-orig")
        #expect(sent.replyToSnippet == "What coffee do you like?")
        #expect(model.replyTarget == nil)
    }

    @Test("ConversationModel edits existing message in place")
    @MainActor
    func testEditMessage() async {
        let repo = MockChatRepo()
        let initial = ChatMessageItem(
            id: "msg-edit-1",
            chatID: "chat-1",
            senderID: "user-self",
            senderName: "Self",
            content: "Original typo text",
            deliveryStatus: .sent,
            isOutgoing: true
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [initial]
        )

        model.editTarget = initial
        model.composerText = "Fixed corrected text"
        await model.sendOrUpdateMessage()

        #expect(model.items.count == 1)
        #expect(model.items.first?.content == "Fixed corrected text")
        #expect(model.items.first?.isEdited == true)
        #expect(repo.editedIDs["msg-edit-1"] == "Fixed corrected text")
        #expect(model.editTarget == nil)
    }

    @Test("Failed edit restores both content and edited state")
    @MainActor
    func testFailedEditRollsBack() async {
        let repo = MockChatRepo()
        repo.failEdit = true
        let initial = ChatMessageItem(
            id: "msg-edit-fail",
            chatID: "chat-1",
            senderID: "user-self",
            senderName: "Self",
            content: "Original",
            deliveryStatus: .sent,
            isOutgoing: true,
            isEdited: false
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            initialItems: [initial]
        )

        model.editTarget = initial
        model.composerText = "Changed"
        await model.sendOrUpdateMessage()

        #expect(model.items.first?.content == "Original")
        #expect(model.items.first?.isEdited == false)
        #expect(model.operationError != nil)
    }

    @Test("ConversationModel deletes message from list")
    @MainActor
    func testDeleteMessage() async {
        let repo = MockChatRepo()
        let message = ChatMessageItem(
            id: "msg-delete-1",
            chatID: "chat-1",
            senderID: "user-self",
            senderName: "Self",
            content: "To be deleted",
            deliveryStatus: .sent,
            isOutgoing: true
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [message]
        )

        await model.deleteMessage(item: message)

        #expect(model.items.isEmpty)
        #expect(repo.deletedIDs.contains("msg-delete-1"))
    }

    @Test("Failed delete restores the message")
    @MainActor
    func testFailedDeleteRollsBack() async {
        let repo = MockChatRepo()
        repo.failDelete = true
        let message = ChatMessageItem(
            id: "msg-delete-fail",
            chatID: "chat-1",
            senderID: "user-self",
            senderName: "Self",
            content: "Keep me",
            deliveryStatus: .sent,
            isOutgoing: true
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            initialItems: [message]
        )

        await model.deleteMessage(item: message)

        #expect(model.items.map(\.id) == ["msg-delete-fail"])
        #expect(model.operationError != nil)
    }

    @Test("Reaction writes persist through repository")
    @MainActor
    func testToggleReactionPersists() async {
        let repo = MockChatRepo()
        let message = ChatMessageItem(
            id: "msg-react-1",
            chatID: "chat-1",
            senderID: "user-peer",
            senderName: "Peer",
            content: "Nice work!",
            deliveryStatus: .read,
            isOutgoing: false
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [message]
        )

        await model.toggleReaction(item: message, reactionType: "🔥")
        #expect(model.items.first?.reactions.first?.reactionType == "🔥")
        #expect(model.items.first?.reactions.first?.count == 1)
        #expect(model.items.first?.reactions.first?.userReacted == true)
        #expect(repo.reactionWrites.count == 1)
        #expect(repo.reactionWrites.first?.adding == true)

        await model.toggleReaction(item: model.items.first!, reactionType: "🔥")
        #expect(model.items.first?.reactions.isEmpty == true)
        #expect(repo.reactionWrites.count == 2)
        #expect(repo.reactionWrites.last?.adding == false)
    }

    @Test("Failed reaction restores prior state")
    @MainActor
    func testFailedReactionRollsBack() async {
        let repo = MockChatRepo()
        repo.failReaction = true
        let message = ChatMessageItem(
            id: "msg-react-fail",
            chatID: "chat-1",
            senderID: "user-peer",
            senderName: "Peer",
            content: "Hello",
            deliveryStatus: .read,
            isOutgoing: false
        )
        let model = ConversationModel(
            identity: makeIdentity(),
            chatRepository: repo,
            currentUserID: "user-self",
            initialItems: [message]
        )

        await model.toggleReaction(item: message, reactionType: "❤️")

        #expect(model.items.first?.reactions.isEmpty == true)
        #expect(model.operationError != nil)
    }
}
