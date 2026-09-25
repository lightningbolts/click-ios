import Foundation
import Testing
@testable import Click

/// Records sends per target and serves an "around" window.
private final class OpsRepo: ChatRepositoryProtocol, @unchecked Sendable {
    var latest: [ChatMessageItem] = []
    var window: [ChatMessageItem] = []
    var sends: [(chatID: String, content: String, clientID: String)] = []
    var readMarked: [String] = []

    func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String { chatID }
    func fetchMessages(conversation: ConversationIdentity, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] { latest }
    func fetchMessages(around messageID: String, conversation: ConversationIdentity, currentUserID: String, limit: Int) async throws -> [ChatMessageItem] { window }
    func sendMessage(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, content: String,
                     replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String) async throws -> ChatMessageItem {
        sends.append((conversation.chatID, content, clientMessageID))
        return ChatMessageItem(id: "s-\(clientMessageID)", chatID: conversation.chatID, senderID: currentUserID,
                               senderName: currentUserName, content: content, isOutgoing: true)
    }
    func editMessage(message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String, newContent: String) async throws {}
    func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {}
    func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {}
    func markRead(chatID: String, messageIDs: [String]) async throws { readMarked += messageIDs }
    func markDelivered(chatID: String, messageIDs: [String]) async throws {}
    func registerDevice() async throws {}
    func decodeRealtimeMessage(_ payload: RealtimeMessagePayload, conversation: ConversationIdentity, currentUserID: String) async throws -> ChatMessageItem {
        throw APIError.decoding
    }
}

private func message(_ id: String, _ text: String = "hello", minute: Double, incoming: Bool = true,
                     status: MessageDeliveryStatus = .delivered) -> ChatMessageItem {
    ChatMessageItem(id: id, chatID: "chat-1", senderID: incoming ? "peer" : "me", senderName: incoming ? "Lena Park" : "You",
                    content: text, createdAt: Date(timeIntervalSince1970: minute * 60), deliveryStatus: status, isOutgoing: !incoming)
}

@Suite("Message operations")
@MainActor
struct MessageOperationsTests {
    private let identity = ConversationIdentity(chatID: "chat-1", peerUserID: "peer", peerDisplayName: "Lena")

    @Test("The unread divider is captured before the timeline is marked read, once per visit")
    func unreadDividerCapturedOnce() async {
        let repo = OpsRepo()
        repo.latest = [message("a", minute: 1, status: .read), message("b", minute: 2), message("c", minute: 3)]
        let model = ConversationModel(identity: identity, chatRepository: repo, currentUserID: "me")
        await model.loadMessages()
        #expect(model.firstUnreadID == "b")
        #expect(repo.readMarked == ["b", "c"])
        repo.latest = repo.latest.map { var m = $0; m.deliveryStatus = .read; return m }
        await model.loadMessages()
        #expect(model.firstUnreadID == "b")
    }

    @Test("Search matches loaded plaintext, skips tombstones, oldest first")
    func searchMatches() {
        let items = [message("a", "Coffee at 3?", minute: 1), message("b", "sure", minute: 2),
                     message("c", "coffee again", minute: 3).tombstoned(), message("d", "More COFFEE", minute: 4)]
        #expect(ConversationModel.searchMatches(in: items, query: "coffee") == ["a", "d"])
        #expect(ConversationModel.searchMatches(in: items, query: "c").isEmpty)
    }

    @Test("A window joins the timeline only when it overlaps; otherwise the chat detaches")
    func revealWindow() async {
        let repo = OpsRepo()
        let loaded = [message("m10", minute: 10), message("m11", minute: 11)]
        let model = ConversationModel(identity: identity, chatRepository: repo, currentUserID: "me", initialItems: loaded)

        repo.window = [message("m8", minute: 8), message("m9", "target", minute: 9), message("m10", minute: 10)]
        #expect(await model.reveal(messageID: "m9") == "m9")
        #expect(model.items.map(\.id) == ["m8", "m9", "m10", "m11"])
        #expect(!model.isDetachedFromLatest)

        repo.window = [message("m1", minute: 1), message("m2", "old", minute: 2)]
        #expect(await model.reveal(messageID: "m2") == "m2")
        #expect(model.items.map(\.id) == ["m1", "m2"])
        #expect(model.isDetachedFromLatest)

        repo.latest = loaded
        await model.returnToLatest()
        #expect(model.items.map(\.id) == ["m10", "m11"])
        #expect(!model.isDetachedFromLatest)
    }

    @Test("A message the server doesn't return can't be revealed")
    func revealMissing() async {
        let model = ConversationModel(identity: identity, chatRepository: OpsRepo(), currentUserID: "me", initialItems: [])
        #expect(await model.reveal(messageID: "gone") == nil)
    }

    @Test("Forwarding text sends plaintext to the target with a fresh client ID")
    func forwardText() async throws {
        let repo = OpsRepo()
        let source = message("x", "see you there", minute: 1)
        let model = ConversationModel(identity: identity, chatRepository: repo, currentUserID: "me", initialItems: [source])
        let target = ConversationIdentity(chatID: "chat-2", peerUserID: "sam", peerDisplayName: "Sam")
        try await model.forward(source, to: target)
        try await model.forward(source, to: target)
        #expect(repo.sends.map(\.chatID) == ["chat-2", "chat-2"])
        #expect(repo.sends.allSatisfy { $0.content == "see you there" })
        #expect(Set(repo.sends.map(\.clientID)).count == 2)
    }

    @Test("Click Drops, beacons, tombstones and in-flight rows can't be forwarded")
    func forwardEligibility() {
        let model = ConversationModel(identity: identity, chatRepository: OpsRepo(), currentUserID: "me", initialItems: [])
        var drop = message("d", minute: 1)
        drop.media = MessageMedia(kind: .image, mimeType: "image/jpeg", fileName: nil, sizeBytes: 1, durationSeconds: nil,
                                  remoteURL: nil, storagePath: nil, v2: nil, fileKey: nil, plaintextSha256: nil, isDisposable: true)
        #expect(!model.canForward(drop))
        #expect(!model.canForward(message("t", minute: 1).tombstoned()))
        #expect(!model.canForward(message("s", minute: 1, incoming: false, status: .sending)))
        #expect(model.canForward(message("ok", minute: 1)))
    }

    @Test("Reacting records who reacted")
    func reactorsTracked() async {
        let model = ConversationModel(identity: identity, chatRepository: OpsRepo(), currentUserID: "me",
                                      initialItems: [message("a", minute: 1)])
        await model.toggleReaction(item: model.items[0], reactionType: "👍")
        #expect(model.items[0].reactions.first?.userIDs == ["me"])
        await model.toggleReaction(item: model.items[0], reactionType: "👍")
        #expect(model.items[0].reactions.isEmpty)
    }

    @Test("Typing label names people in groups")
    func typingLabel() {
        #expect(ConversationModel.typingLabel(names: ["Lena Park"], count: 1) == "Lena is typing…")
        #expect(ConversationModel.typingLabel(names: ["Lena", "Sam"], count: 2) == "Lena and Sam are typing…")
        #expect(ConversationModel.typingLabel(names: ["Lena", "Sam", "Ada"], count: 3) == "Lena and 2 others are typing…")
        #expect(ConversationModel.typingLabel(names: [], count: 2) == "Someone is typing…")
    }

    @Test("Icebreakers: context prompts first, stable per seed, always the requested count")
    func icebreakers() {
        let gym = Icebreakers.prompts(context: "Met at the IMA gym", seed: "conn-1")
        #expect(gym.count == 3)
        #expect(gym.contains("Do you work out regularly? What's your gym routine like?"))
        #expect(gym == Icebreakers.prompts(context: "Met at the IMA gym", seed: "conn-1"))
        #expect(Icebreakers.prompts(context: nil, seed: "x").count == 3)
        #expect(Set(Icebreakers.prompts(context: nil, seed: "x")).count == 3)
    }

    @Test("A search focus matches the conversation by any of its IDs")
    func focusMatching() {
        let focus = MessageFocus(conversationIDs: ["chat-9", "conn-9", nil], messageID: "m")
        #expect(focus.matches(ConversationIdentity(chatID: "conn-9", connectionID: "conn-9", peerUserID: "p", peerDisplayName: "P")))
        #expect(!focus.matches(ConversationIdentity(chatID: "other", peerUserID: "p", peerDisplayName: "P")))
    }

    @Test("AppEnvironment returns the same ConversationModel instance for the same identity")
    func conversationModelInstanceReuse() {
        let env = AppEnvironment(network: NetworkMonitor(start: false))
        let model1 = env.conversationModel(for: identity)
        let model2 = env.conversationModel(for: identity)
        #expect(model1 === model2)
    }

    @Test("isEmoji recognizes all keyboard emojis and rejects non-emojis")
    func isEmojiRecognition() {
        #expect(EmojiKeyboardPicker.isEmoji("👍"))
        #expect(EmojiKeyboardPicker.isEmoji("🇺🇸"))
        #expect(EmojiKeyboardPicker.isEmoji("1️⃣"))
        #expect(EmojiKeyboardPicker.isEmoji("👩🏽‍💻"))
        #expect(!EmojiKeyboardPicker.isEmoji("a"))
        #expect(!EmojiKeyboardPicker.isEmoji("1"))
    }

    @Test("EmojiKeyboardPicker fallback list contains > 1000 emojis and includes standard reactions")
    func emojiKeyboardPickerFallbackList() {
        let emojis = EmojiKeyboardPicker.allEmoji()
        #expect(emojis.count > 1000)
        let symbols = Set(emojis.map(\.emoji))
        #expect(symbols.contains("👍"))
        #expect(symbols.contains("🫶"))
        #expect(symbols.contains("🙏"))
    }
}
