import Foundation
import Observation

public enum LoadPhase: Sendable {
    case initial
    case loading
    case loaded
    case failed(String)
}

/// `@Observable` conversation view model implementing §31.2 specifications.
@Observable
@MainActor
public final class ConversationModel {

    public let identity: ConversationIdentity
    public private(set) var phase: LoadPhase = .initial
    public private(set) var items: [ChatMessageItem] = []
    public private(set) var isSending: Bool = false
    public var composerText: String = ""
    public var replyTarget: ChatMessageItem?
    public var editTarget: ChatMessageItem?
    public var isPeerTyping: Bool = false

    private let chatRepository: ChatRepositoryProtocol
    private let realtimeManager: ChatRealtimeManager
    private let currentUserID: String
    private let currentUserName: String

    public init(
        identity: ConversationIdentity,
        chatRepository: ChatRepositoryProtocol,
        realtimeManager: ChatRealtimeManager = ChatRealtimeManager(),
        currentUserID: String,
        currentUserName: String = "You",
        initialItems: [ChatMessageItem]? = nil
    ) {
        self.identity = identity
        self.chatRepository = chatRepository
        self.realtimeManager = realtimeManager
        self.currentUserID = currentUserID
        self.currentUserName = currentUserName

        if let initial = initialItems {
            self.items = initial
            self.phase = .loaded
        }
    }

    public var realtimeHealth: SubscriptionHealth {
        realtimeManager.health
    }

    // MARK: - Lifecycle

    public func onAppear(supabaseURL: URL?, anonKey: String?, authToken: String?) async {
        if let url = supabaseURL, let key = anonKey {
            realtimeManager.subscribe(to: identity.chatID, supabaseURL: url, anonKey: key, authToken: authToken)
            setupRealtimeCallbacks()
        }

        if items.isEmpty {
            await loadMessages()
        }
    }

    public func onDisappear() {
        realtimeManager.teardown()
    }

    // MARK: - Data Loading

    public func loadMessages() async {
        phase = .loading
        do {
            let fetched = try await chatRepository.fetchMessages(
                chatID: identity.chatID,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                currentUserID: currentUserID,
                cursor: nil,
                limit: 50
            )

            // Sort chronologically (oldest at top, newest at bottom)
            items = fetched.sorted { $0.createdAt < $1.createdAt }
            phase = .loaded

            // Mark unread messages as read
            let unreadIDs = items.filter { !$0.isOutgoing && $0.deliveryStatus != .read }.map(\.id)
            if !unreadIDs.isEmpty {
                try? await chatRepository.markRead(chatID: identity.chatID, messageIDs: unreadIDs)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Sending & Editing

    public func sendOrUpdateMessage() async {
        let textToSend = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSend.isEmpty else { return }

        // If editing an existing message
        if let editTarget = editTarget {
            await applyEdit(target: editTarget, newContent: textToSend)
            return
        }

        // New message send
        let clientID = UUID().uuidString.lowercased()
        let optimisticItem = ChatMessageItem(
            id: clientID,
            chatID: identity.chatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: textToSend,
            messageType: .text,
            createdAt: Date(),
            deliveryStatus: .sending,
            isOutgoing: true,
            replyToID: replyTarget?.id,
            replyToSnippet: replyTarget?.content,
            replyToSenderName: replyTarget?.senderName
        )

        items.append(optimisticItem)
        composerText = ""
        let capturedReply = replyTarget
        replyTarget = nil
        isSending = true

        do {
            let serverItem = try await chatRepository.sendMessage(
                chatID: identity.chatID,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                content: textToSend,
                replyToID: capturedReply?.id,
                replyToSnippet: capturedReply?.content,
                replyToSenderName: capturedReply?.senderName,
                clientMessageID: clientID
            )

            // Update item in place
            if let index = items.firstIndex(where: { $0.id == clientID }) {
                items[index] = serverItem
            }
            isSending = false
        } catch {
            if let index = items.firstIndex(where: { $0.id == clientID }) {
                items[index].deliveryStatus = .failed
            }
            isSending = false
        }
    }

    public func retrySend(item: ChatMessageItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].deliveryStatus = .sending

        do {
            let serverItem = try await chatRepository.sendMessage(
                chatID: identity.chatID,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                content: item.content,
                replyToID: item.replyToID,
                replyToSnippet: item.replyToSnippet,
                replyToSenderName: item.replyToSenderName,
                clientMessageID: item.id
            )
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = serverItem
            }
        } catch {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].deliveryStatus = .failed
            }
        }
    }

    private func applyEdit(target: ChatMessageItem, newContent: String) async {
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return }
        let originalContent = items[index].content
        items[index].content = newContent
        items[index].isEdited = true
        editTarget = nil
        composerText = ""

        do {
            try await chatRepository.editMessage(messageID: target.id, newContent: newContent)
        } catch {
            // Revert on failure
            items[index].content = originalContent
        }
    }

    public func deleteMessage(item: ChatMessageItem) async {
        items.removeAll { $0.id == item.id }
        try? await chatRepository.deleteMessage(messageID: item.id)
    }

    public func toggleReaction(item: ChatMessageItem, reactionType: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        var reactions = items[index].reactions
        if let rIdx = reactions.firstIndex(where: { $0.reactionType == reactionType }) {
            if reactions[rIdx].userReacted {
                reactions[rIdx].count -= 1
                reactions[rIdx].userReacted = false
                if reactions[rIdx].count <= 0 {
                    reactions.remove(at: rIdx)
                }
            } else {
                reactions[rIdx].count += 1
                reactions[rIdx].userReacted = true
            }
        } else {
            reactions.append(ReactionSummary(reactionType: reactionType, count: 1, userReacted: true))
        }

        items[index].reactions = reactions
    }

    public func setTyping(isTyping: Bool) {
        realtimeManager.sendTyping(isTyping: isTyping, userID: currentUserID)
    }

    // MARK: - Realtime Callbacks

    private func setupRealtimeCallbacks() {
        realtimeManager.onMessageInserted = { [weak self] payload in
            Task { @MainActor in
                guard let self = self, payload.chatID == self.identity.chatID else { return }
                guard !self.items.contains(where: { $0.id == payload.id }) else { return }

                let item = ChatMessageItem(
                    id: payload.id,
                    chatID: payload.chatID,
                    senderID: payload.senderID,
                    senderName: self.identity.peerDisplayName,
                    content: payload.content,
                    messageType: MessageType(rawValue: payload.messageType) ?? .text,
                    createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
                    deliveryStatus: .delivered,
                    isOutgoing: false
                )
                self.items.append(item)
            }
        }
    }
}

// MARK: - Preview Fixture Extension

extension ConversationModel {
    public static var preview: ConversationModel {
        let identity = ConversationIdentity(
            chatID: "preview-chat-1",
            connectionID: "conn-preview-1",
            peerUserID: "user-maya",
            peerDisplayName: "Maya Lin",
            peerHandle: "@mayalin",
            peerAvatarURL: nil,
            isOnline: true,
            lastActiveText: "Active now"
        )

        let initial: [ChatMessageItem] = [
            ChatMessageItem(
                id: "msg-1",
                chatID: "preview-chat-1",
                senderID: "user-maya",
                senderName: "Maya Lin",
                content: "Hey Alex! Great connecting at the tech summit yesterday.",
                createdAt: Calendar.current.date(byAdding: .minute, value: -12, to: Date())!,
                deliveryStatus: .read,
                isOutgoing: false,
                reactions: [ReactionSummary(reactionType: "👋", count: 1, userReacted: true)]
            ),
            ChatMessageItem(
                id: "msg-2",
                chatID: "preview-chat-1",
                senderID: "user-self",
                senderName: "You",
                content: "Absolutely! Really enjoyed discussing the native Swift architecture and zero-compromise E2EE.",
                createdAt: Calendar.current.date(byAdding: .minute, value: -10, to: Date())!,
                deliveryStatus: .read,
                isOutgoing: true
            ),
            ChatMessageItem(
                id: "msg-3",
                chatID: "preview-chat-1",
                senderID: "user-maya",
                senderName: "Maya Lin",
                content: "Are you free for a coffee catch-up later this afternoon around Hayes Valley?",
                createdAt: Calendar.current.date(byAdding: .minute, value: -5, to: Date())!,
                deliveryStatus: .read,
                isOutgoing: false
            ),
            ChatMessageItem(
                id: "msg-4",
                chatID: "preview-chat-1",
                senderID: "user-self",
                senderName: "You",
                content: "Sounds perfect! Let's meet at Ritual Coffee at 3:30 PM.",
                createdAt: Calendar.current.date(byAdding: .minute, value: -2, to: Date())!,
                deliveryStatus: .delivered,
                isOutgoing: true,
                replyToID: "msg-3",
                replyToSnippet: "Are you free for a coffee catch-up later this afternoon around Hayes Valley?",
                replyToSenderName: "Maya Lin",
                reactions: [ReactionSummary(reactionType: "☕️", count: 1, userReacted: true)]
            )
        ]

        let repo = PreviewChatRepo(initial: initial)

        return ConversationModel(
            identity: identity,
            chatRepository: repo,
            currentUserID: "user-self",
            currentUserName: "Alex",
            initialItems: initial
        )
    }
}

private struct PreviewChatRepo: ChatRepositoryProtocol {
    let initial: [ChatMessageItem]

    func fetchMessages(chatID: String, connectionID: String?, peerUserID: String, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] { initial }
    func sendMessage(chatID: String, connectionID: String?, peerUserID: String, currentUserID: String, currentUserName: String, content: String, replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String) async throws -> ChatMessageItem {
        ChatMessageItem(id: clientMessageID, chatID: chatID, senderID: currentUserID, senderName: currentUserName, content: content, deliveryStatus: .delivered, isOutgoing: true)
    }
    func editMessage(messageID: String, newContent: String) async throws {}
    func deleteMessage(messageID: String) async throws {}
    func markRead(chatID: String, messageIDs: [String]) async throws {}
    func markDelivered(chatID: String, messageIDs: [String]) async throws {}
    func registerDevice() async throws {}
}
