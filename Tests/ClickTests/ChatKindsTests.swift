import Testing
import Foundation
@testable import Click

@Suite("Conversation kinds")
struct ChatKindsTests {
    private final class RecordingRepo: ChatRepositoryProtocol, @unchecked Sendable {
        var markedRead: [String] = []
        var markedDelivered: [String] = []
        var fetchedKinds: [ConversationKind] = []
        var messages: [ChatMessageItem] = []

        func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String { chatID }
        func fetchMessages(conversation: ConversationIdentity, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] {
            fetchedKinds.append(conversation.kind)
            return messages
        }
        func sendMessage(
            conversation: ConversationIdentity, currentUserID: String, currentUserName: String, content: String,
            replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String
        ) async throws -> ChatMessageItem {
            ChatMessageItem(id: clientMessageID, chatID: conversation.chatID, senderID: currentUserID, senderName: currentUserName,
                            content: content, deliveryStatus: .sent, isOutgoing: true)
        }
        func editMessage(message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String, newContent: String) async throws {}
        func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {}
        func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {}
        func markRead(chatID: String, messageIDs: [String]) async throws { markedRead += messageIDs }
        func markDelivered(chatID: String, messageIDs: [String]) async throws { markedDelivered += messageIDs }
        func registerDevice() async throws {}
        func decodeRealtimeMessage(_ payload: RealtimeMessagePayload, conversation: ConversationIdentity, currentUserID: String) async throws -> ChatMessageItem {
            ChatMessageItem(id: payload.id, chatID: payload.chatID, senderID: payload.senderID, senderName: "Maya",
                            content: payload.content, deliveryStatus: .delivered, isOutgoing: false)
        }
    }

    private func incoming(_ id: String) -> ChatMessageItem {
        ChatMessageItem(id: id, chatID: "hub-1", senderID: "u2", senderName: "Maya", content: "hi",
                        deliveryStatus: .delivered, isOutgoing: false)
    }

    @Test("Hubs never send read receipts; direct chats do")
    @MainActor
    func hubHasNoReceipts() async {
        let repo = RecordingRepo()
        repo.messages = [incoming("m1")]
        let hub = ConversationModel(
            identity: ConversationIdentity(chatID: "hub-1", peerUserID: "", peerDisplayName: "Cafe", kind: .hub(hubID: "hub-1")),
            chatRepository: repo,
            currentUserID: "me"
        )
        await hub.loadMessages()
        #expect(repo.fetchedKinds == [.hub(hubID: "hub-1")])
        #expect(repo.markedRead.isEmpty)

        let direct = ConversationModel(
            identity: ConversationIdentity(chatID: "c-1", connectionID: "c-1", peerUserID: "u2", peerDisplayName: "Maya"),
            chatRepository: repo,
            currentUserID: "me"
        )
        await direct.loadMessages()
        #expect(repo.markedRead == ["m1"])
    }

    @Test("Identity helpers expose the kind")
    func identityHelpers() {
        let group = GroupChatRoute(chatID: "chat-9", groupID: "g-9", name: "Climbing", memberUserIDs: ["a", "b"]).conversationIdentity
        #expect(group.groupID == "g-9")
        #expect(group.hubID == nil)
        #expect(!group.isDirect)
        #expect(group.supportsReceipts)
        #expect(group.participantUserIDs == ["a", "b"])
        let hub = ConversationIdentity(chatID: "h", peerUserID: "", peerDisplayName: "H", kind: .hub(hubID: "h"))
        #expect(!hub.supportsReceipts)
    }

    @Test("Hub access failures keep their real reason")
    func hubErrors() {
        #expect(HubChatError.map(APIError.validation(code: "400", message: "{\"error\":\"OUT_OF_BOUNDS\"}")) as? HubChatError == .outOfRange)
        #expect(HubChatError.map(APIError.validation(code: "400", message: "{\"error\":\"user_lat and user_long are required\"}")) as? HubChatError == .locationRequired)
        #expect(HubChatError.map(APIError.forbidden) as? HubChatError == .accessDenied)
        #expect(HubChatError.map(APIError.server(status: 410, code: nil, message: nil)) as? HubChatError == .ended)
        #expect(HubChatError.map(APIError.offline) as? HubChatError == nil)
    }

    @Test("Event chat resolver maps every status to a bounded state")
    func eventChatResolution() {
        #expect(HubRepository.resolution(for: APIError.forbidden) == .requiresRSVP)
        #expect(HubRepository.resolution(for: APIError.notFound) == .unavailable)
        #expect(HubRepository.resolution(for: APIError.conflict(code: nil)) == .notReady)
        #expect(HubRepository.resolution(for: APIError.server(status: 410, code: nil, message: nil)) == .ended)
        if case .failed = HubRepository.resolution(for: APIError.server(status: 500, code: nil, message: nil)) {} else {
            Issue.record("500 should be a retryable failure")
        }
    }

    @Test("Legacy hub keys match the KMP derivation")
    func legacyHubKeys() {
        let keys = ClickCryptoV1.deriveKeysForHub(hubID: " hub-123 ")
        #expect(keys.encKey.map { String(format: "%02x", $0) }.joined() == "7015290a0aa7361639c2ee18d25a25c9b5083393ecb45235061bd270630d8d8b")
        #expect(keys.macKey.map { String(format: "%02x", $0) }.joined() == "d3fff90313836a8031dfd852898fe9ef1f1f37fc5915e483481fe071271783da")
        let wire = try? ClickCryptoV1.encryptContent("hello hub", keys: keys)
        #expect(wire.map { ClickCryptoV1.decryptContent($0, keys: keys) } == "hello hub")
    }
}

@Suite("Inbox realtime")
struct InboxRealtimeTests {
    private func connection(_ id: String, chatID: String) -> ConnectionItem {
        ConnectionItem(id: id, userID: "peer-\(id)", connectionID: id, displayName: id, handle: "", initials: "X",
                       isOnline: false, lastActiveRelative: "", encounterLocation: "", chatID: chatID)
    }

    @Test("An incoming message updates its row in place, bumps unread, and moves it to the top")
    @MainActor
    func incomingMovesToTop() {
        let group = CliqueItem(id: "g1", chatID: "chat-g", name: "Crew", memberCount: 3)
        let model = ConversationListModel(initialSnapshot: ClicksSnapshot(
            connections: [connection("a", chatID: "chat-a"), connection("b", chatID: "chat-b")],
            archivedConnections: [],
            groups: [group],
            mapPins: []
        ))
        model.applyInserted(RealtimeMessagePayload(id: "m1", chatID: "chat-b", senderID: "peer-b", content: "e2e:abc"), currentUserID: "me")
        #expect(model.active.first?.id == "b")
        #expect(model.active.first?.unreadCount == 1)
        #expect(model.active.first?.lastMessage?.content == "e2e:abc")

        model.applyInserted(RealtimeMessagePayload(id: "m2", chatID: "chat-g", senderID: "me", content: "hi"), currentUserID: "me")
        #expect(model.groups.first?.unreadCount == 0)
        #expect(model.groups.first?.lastMessage?.isOutgoing == true)
        #expect(model.unreadTotal == 1)
    }
}

@Suite("Verified group creation")
struct GroupCreationTests {
    @Test("Each member's master key row opens with the KMP unwrap rule")
    func wrappedKeysUnwrap() throws {
        let master = Data((0..<32).map { UInt8($0) })
        let payload = try GroupRepository.createPayload(
            creatorID: "u-creator",
            connectionIDs: ["u-b": "conn-b", "u-a": "conn-a"],
            name: "  ",
            masterKey: master
        )
        #expect(payload["target_user_ids"] as? [String] == ["u-a", "u-b", "u-creator"])
        #expect(payload["initial_group_name"] as? String == "Clique")
        let keys = try #require(payload["encrypted_keys"] as? [String: String])
        // Unwrap rule: members use the edge to the creator; the creator uses the edge to the anchor (u-a).
        let edges = ["u-a": ("conn-a", "u-creator"), "u-b": ("conn-b", "u-creator"), "u-creator": ("conn-a", "u-a")]
        for (member, edge) in edges {
            let derived = ClickCryptoV1.deriveKeysForConnection(connectionID: edge.0, userIDs: [member, edge.1])
            let plain = ClickCryptoV1.decryptContent(try #require(keys[member]), keys: derived)
            #expect(Data(base64Encoded: plain) == master, "row for \(member)")
        }
    }

    @Test("Creation needs a verified connection for every member")
    func missingEdge() {
        #expect(throws: APIError.self) {
            _ = try GroupRepository.createPayload(creatorID: "c", connectionIDs: [:], name: "x", masterKey: Data(count: 32))
        }
    }
}
