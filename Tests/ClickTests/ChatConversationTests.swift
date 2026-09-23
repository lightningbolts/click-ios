import Testing
import Foundation
@testable import Click

@Suite("Chat Conversation Model Tests")
struct ChatConversationTests {

    private final class MockChatRepo: ChatRepositoryProtocol, @unchecked Sendable {
        var messagesToReturn: [ChatMessageItem] = []
        var sentMessages: [ChatMessageItem] = []
        var markedReadIDs: [String] = []
        var markedDeliveredIDs: [String] = []
        var editedIDs: [String: String] = [:]
        var deletedIDs: [String] = []

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

        func editMessage(messageID: String, newContent: String) async throws {
            editedIDs[messageID] = newContent
        }

        func deleteMessage(messageID: String) async throws {
            deletedIDs.append(messageID)
        }

        func markRead(chatID: String, messageIDs: [String]) async throws {
            markedReadIDs.append(contentsOf: messageIDs)
        }

        func markDelivered(chatID: String, messageIDs: [String]) async throws {
            markedDeliveredIDs.append(contentsOf: messageIDs)
        }

        func registerDevice() async throws {}
    }

    @Test("ConversationModel loads messages and marks unread messages as read")
    @MainActor
    func testLoadMessages() async {
        let repo = MockChatRepo()
        let unreadPeerMessage = ChatMessageItem(
            id: "msg-unread-1",
            chatID: "chat-1",
            senderID: "user-peer",
            senderName: "Peer",
            content: "Hey!",
            createdAt: Date(),
            deliveryStatus: .delivered,
            isOutgoing: false
        )
        repo.messagesToReturn = [unreadPeerMessage]

        let identity = ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
        let model = ConversationModel(
            identity: identity,
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
        let identity = ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
        let model = ConversationModel(
            identity: identity,
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
        let identity = ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
        let initialMsg = ChatMessageItem(
            id: "msg-orig",
            chatID: "chat-1",
            senderID: "user-peer",
            senderName: "Peer",
            content: "What coffee do you like?",
            deliveryStatus: .read,
            isOutgoing: false
        )
        let model = ConversationModel(
            identity: identity,
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [initialMsg]
        )

        model.replyTarget = initialMsg
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
        let identity = ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
        let initialMsg = ChatMessageItem(
            id: "msg-edit-1",
            chatID: "chat-1",
            senderID: "user-self",
            senderName: "Self",
            content: "Original typo text",
            deliveryStatus: .sent,
            isOutgoing: true
        )
        let model = ConversationModel(
            identity: identity,
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [initialMsg]
        )

        model.editTarget = initialMsg
        model.composerText = "Fixed corrected text"
        await model.sendOrUpdateMessage()

        #expect(model.items.count == 1)
        #expect(model.items.first?.content == "Fixed corrected text")
        #expect(model.items.first?.isEdited == true)
        #expect(repo.editedIDs["msg-edit-1"] == "Fixed corrected text")
        #expect(model.editTarget == nil)
    }

    @Test("ConversationModel deletes message from list")
    @MainActor
    func testDeleteMessage() async {
        let repo = MockChatRepo()
        let identity = ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
        let msg = ChatMessageItem(
            id: "msg-delete-1",
            chatID: "chat-1",
            senderID: "user-self",
            senderName: "Self",
            content: "To be deleted",
            deliveryStatus: .sent,
            isOutgoing: true
        )
        let model = ConversationModel(
            identity: identity,
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [msg]
        )

        await model.deleteMessage(item: msg)

        #expect(model.items.isEmpty)
        #expect(repo.deletedIDs.contains("msg-delete-1"))
    }

    @Test("ConversationModel toggles emoji reaction and updates count")
    @MainActor
    func testToggleReaction() {
        let repo = MockChatRepo()
        let identity = ConversationIdentity(
            chatID: "chat-1",
            connectionID: "conn-1",
            peerUserID: "user-peer",
            peerDisplayName: "Peer User"
        )
        let msg = ChatMessageItem(
            id: "msg-react-1",
            chatID: "chat-1",
            senderID: "user-peer",
            senderName: "Peer",
            content: "Nice work!",
            deliveryStatus: .read,
            isOutgoing: false
        )
        let model = ConversationModel(
            identity: identity,
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Self",
            initialItems: [msg]
        )

        // Add reaction
        model.toggleReaction(item: msg, reactionType: "🔥")
        #expect(model.items.first?.reactions.first?.reactionType == "🔥")
        #expect(model.items.first?.reactions.first?.count == 1)
        #expect(model.items.first?.reactions.first?.userReacted == true)

        // Toggle off
        model.toggleReaction(item: model.items.first!, reactionType: "🔥")
        #expect(model.items.first?.reactions.isEmpty == true)
    }
}
