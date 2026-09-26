import Testing
import Foundation
@testable import Click

@Suite("Delta tombstones and paging")
@MainActor
struct DeltaTombstoneTests {
    private let identity = ConversationIdentity(chatID: "chat-p", peerUserID: "peer", peerDisplayName: "P")

    @Test("A delta tombstone older than the timeline neither joins it nor stops paging")
    func outlyingTombstone() async {
        let all = PaginationTests.history(count: 370)
        let repo = HistoryRepo(all)
        let model = ConversationModel(identity: identity, chatRepository: repo, currentUserID: "me")
        await model.loadMessages()
        repo.deltaTombstones = [all[5].tombstoned()]
        await model.syncNewer()
        #expect(model.items.count == 40)
        #expect(model.items.first?.id == "m330")
        var guardCount = 0
        while model.hasMoreHistory, guardCount < 50 { await model.loadOlder(); guardCount += 1 }
        #expect(model.items.count == 370)
        #expect(model.items.first?.id == "m0")
    }

    @Test("A delta tombstone inside the timeline replaces its row and keeps the rows after it")
    func tombstoneInWindow() async {
        let all = PaginationTests.history(count: 370)
        let repo = HistoryRepo(all)
        let model = ConversationModel(identity: identity, chatRepository: repo, currentUserID: "me")
        await model.loadMessages()
        repo.deltaTombstones = [all[350].tombstoned()]
        await model.syncNewer()
        #expect(model.items.count == 40)
        #expect(model.items.first { $0.id == "m350" }?.isDeleted == true)
        #expect(model.items.last?.id == "m369")
    }
}

@Suite("Local-first painting", .serialized)
@MainActor
struct LocalFirstTests {
    @Test("A chat painted from disk shows reply quotes on its first frame")
    func replyQuotesFromDisk() async throws {
        let user = "test-\(UUID().uuidString)"
        defer { LocalStore.shared.wipe(userID: user) }
        let original = ChatMessageItem(id: "a", chatID: "c1", senderID: "peer", senderName: "Maya", content: "Dinner at 7?",
                                       createdAt: Date().addingTimeInterval(-60), deliveryStatus: .read, isOutgoing: false)
        let reply = ChatMessageItem(id: "b", chatID: "c1", senderID: "me", senderName: "You", content: "Yes!",
                                    deliveryStatus: .read, isOutgoing: true, replyToID: "a")
        LocalStore.shared.upsertMessages([original, reply], conversation: "c1", userID: user)
        let model = ConversationModel(identity: ConversationIdentity(chatID: "c1", peerUserID: "peer", peerDisplayName: "Maya"),
                                      chatRepository: HistoryRepo([]), currentUserID: user, store: .shared)
        #expect(model.items.first { $0.id == "b" }?.replyToSnippet == "Dinner at 7?")
        #expect(model.items.first { $0.id == "b" }?.replyToSenderName == "Maya")
    }

    @Test("Inbox previews come from this device's decrypted copy of the same ciphertext")
    func previewFromStore() async {
        let user = "test-\(UUID().uuidString)"
        defer { LocalStore.shared.wipe(userID: user) }
        let item = ChatMessageItem(id: "m1", chatID: "c1", senderID: "peer", senderName: "Maya", content: "See you there",
                                   rawContent: "e2ee-v2:wire-1", deliveryStatus: .read, isOutgoing: false)
        LocalStore.shared.upsertMessages([item], conversation: "c1", userID: user)
        let texts = await LocalStore.shared.plaintext(ofLatest: ["conn-1": ("c1", "e2ee-v2:wire-1"), "conn-2": ("c1", "e2ee-v2:other")], userID: user)
        #expect(texts == ["conn-1": "See you there"])
    }
}

@Suite("Pins")
@MainActor
struct PinTests {
    @Test("Pinning shows at once, newest first, and resolves the pinned message")
    func togglePin() async {
        let all = PaginationTests.history(count: 10)
        let model = ConversationModel(identity: ConversationIdentity(chatID: "chat-p", peerUserID: "peer", peerDisplayName: "P"),
                                      chatRepository: HistoryRepo(all), currentUserID: "me")
        await model.loadMessages()
        await model.togglePin(model.items[2])
        await model.togglePin(model.items[5])
        #expect(model.pins.map(\.messageID) == ["m5", "m2"])
        #expect(await model.pinnedMessages().map(\.id) == ["m5", "m2"])
        await model.togglePin(model.items[5])
        #expect(model.pins.map(\.messageID) == ["m2"])
    }
}

@Suite("Chat backdrops")
struct ChatBackdropTests {
    private func encounter(_ venue: String?, hour: Int = 14, tags: [String] = []) -> Encounter {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
        return Encounter(id: "e", date: date, place: nil, eventTitle: nil, eventBeaconID: nil, contextTags: tags,
                         noiseLevel: nil, elevation: nil, venue: venue)
    }

    @Test("The style follows where you met")
    func automatic() {
        #expect(ChatBackdropStyle.automatic(encounters: nil, place: nil) == nil)
        #expect(ChatBackdropStyle.automatic(encounters: [encounter("Café Allegro")], place: nil) == .coffee)
        #expect(ChatBackdropStyle.automatic(encounters: [encounter("Gas Works Park")], place: nil) == .nature)
        #expect(ChatBackdropStyle.automatic(encounters: nil, place: "Chelsea Market") == .city)
        #expect(ChatBackdropStyle.automatic(encounters: [encounter(nil, hour: 23)], place: nil) == .night)
        #expect(ChatBackdropStyle.automatic(encounters: [encounter(nil)], place: nil) == .classic)
    }
}
