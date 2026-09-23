import Foundation
import Observation

public enum LoadPhase: Sendable, Equatable {
    case initial
    case loading
    case loaded
    case failed(String)
}

/// Single authoritative presentation model for a direct conversation.
@Observable
@MainActor
public final class ConversationModel {
    public private(set) var identity: ConversationIdentity
    public private(set) var phase: LoadPhase = .initial
    public private(set) var items: [ChatMessageItem] = []
    public private(set) var isSending = false
    public var composerText = ""
    public var replyTarget: ChatMessageItem?
    public var editTarget: ChatMessageItem?
    public var isPeerTyping = false
    public var operationError: String?

    private let chatRepository: ChatRepositoryProtocol
    private let realtimeManager: ChatRealtimeManager
    private let currentUserID: String
    private let currentUserName: String
    private var pendingSendCount = 0
    private var typingActive = false
    private var typingStopTask: Task<Void, Never>?

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

        if let initialItems {
            self.items = initialItems
            self.phase = .loaded
        }
    }

    public var realtimeHealth: SubscriptionHealth {
        realtimeManager.health
    }

    // MARK: - Lifecycle

    public func onAppear(supabaseURL: URL?, anonKey: String?, authToken: String?) async {
        setupRealtimeCallbacks()

        do {
            identity.chatID = try await chatRepository.resolveCanonicalChatID(
                chatID: identity.chatID,
                connectionID: identity.connectionID
            )
        } catch {
            if items.isEmpty {
                phase = .failed(error.localizedDescription)
            }
            return
        }

        if let supabaseURL, let anonKey {
            realtimeManager.subscribe(
                to: identity.chatID,
                supabaseURL: supabaseURL,
                anonKey: anonKey,
                authToken: authToken
            )
        }

        if items.isEmpty {
            await loadMessages()
        }
    }

    public func onDisappear() {
        typingStopTask?.cancel()
        typingStopTask = nil
        if typingActive {
            realtimeManager.sendTyping(isTyping: false, userID: currentUserID)
        }
        typingActive = false
        realtimeManager.teardown()
    }

    // MARK: - Data loading

    public func loadMessages() async {
        let hadItems = !items.isEmpty
        if !hadItems {
            phase = .loading
        }

        do {
            let fetched = try await chatRepository.fetchMessages(
                chatID: identity.chatID,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                currentUserID: currentUserID,
                cursor: nil,
                limit: 50
            )
            items = fetched.sorted { $0.createdAt < $1.createdAt }
            phase = .loaded
            operationError = nil

            let unreadIDs = items
                .filter { !$0.isOutgoing && $0.deliveryStatus != .read }
                .map(\.id)
            if !unreadIDs.isEmpty {
                try? await chatRepository.markRead(chatID: identity.chatID, messageIDs: unreadIDs)
            }
        } catch {
            if items.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                operationError = error.localizedDescription
            }
        }
    }

    // MARK: - Sending / editing

    public func sendOrUpdateMessage() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let editTarget {
            await applyEdit(target: editTarget, newContent: text)
            return
        }

        let clientID = UUID().uuidString.lowercased()
        let capturedReply = replyTarget
        let optimistic = ChatMessageItem(
            id: clientID,
            chatID: identity.chatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: text,
            messageType: .text,
            createdAt: Date(),
            deliveryStatus: .sending,
            isOutgoing: true,
            replyToID: capturedReply?.id,
            replyToSnippet: capturedReply?.content,
            replyToSenderName: capturedReply?.senderName
        )

        items.append(optimistic)
        composerText = ""
        replyTarget = nil
        stopTyping()
        beginSend()

        do {
            let serverItem = try await chatRepository.sendMessage(
                chatID: identity.chatID,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                content: text,
                replyToID: capturedReply?.id,
                replyToSnippet: capturedReply?.content,
                replyToSenderName: capturedReply?.senderName,
                clientMessageID: clientID
            )

            if let index = items.firstIndex(where: { $0.id == clientID }) {
                items[index] = serverItem
            }
            operationError = nil
        } catch {
            if let index = items.firstIndex(where: { $0.id == clientID }) {
                items[index].deliveryStatus = .failed
            }
            operationError = error.localizedDescription
        }

        endSend()
    }

    public func retrySend(item: ChatMessageItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].deliveryStatus = .sending
        beginSend()

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
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = serverItem
            }
            operationError = nil
        } catch {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].deliveryStatus = .failed
            }
            operationError = error.localizedDescription
        }

        endSend()
    }

    private func applyEdit(target: ChatMessageItem, newContent: String) async {
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return }
        let original = items[index]

        items[index].content = newContent
        items[index].isEdited = true
        editTarget = nil
        composerText = ""
        stopTyping()

        do {
            try await chatRepository.editMessage(
                message: original,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                currentUserID: currentUserID,
                newContent: newContent
            )
            operationError = nil
        } catch {
            if let currentIndex = items.firstIndex(where: { $0.id == target.id }) {
                items[currentIndex] = original
            }
            operationError = error.localizedDescription
        }
    }

    public func deleteMessage(item: ChatMessageItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)

        do {
            try await chatRepository.deleteMessage(messageID: item.id)
            operationError = nil
        } catch {
            let safeIndex = min(index, items.count)
            items.insert(removed, at: safeIndex)
            operationError = error.localizedDescription
        }
    }

    public func toggleReaction(item: ChatMessageItem, reactionType: String) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let original = items[index].reactions
        let adding = !original.contains {
            $0.reactionType == reactionType && $0.userReacted
        }

        items[index].reactions = Self.mutatedReactions(
            original,
            reactionType: reactionType,
            adding: adding
        )

        do {
            try await chatRepository.setReaction(
                messageID: item.id,
                reactionType: reactionType,
                adding: adding
            )
            operationError = nil
        } catch {
            if let currentIndex = items.firstIndex(where: { $0.id == item.id }) {
                items[currentIndex].reactions = original
            }
            operationError = error.localizedDescription
        }
    }

    private static func mutatedReactions(
        _ source: [ReactionSummary],
        reactionType: String,
        adding: Bool
    ) -> [ReactionSummary] {
        var reactions = source
        if let index = reactions.firstIndex(where: { $0.reactionType == reactionType }) {
            if adding {
                guard !reactions[index].userReacted else { return reactions }
                reactions[index].count += 1
                reactions[index].userReacted = true
            } else {
                guard reactions[index].userReacted else { return reactions }
                reactions[index].count -= 1
                reactions[index].userReacted = false
                if reactions[index].count <= 0 {
                    reactions.remove(at: index)
                }
            }
        } else if adding {
            reactions.append(
                ReactionSummary(
                    reactionType: reactionType,
                    count: 1,
                    userReacted: true
                )
            )
        }
        return reactions
    }

    // MARK: - Typing

    public func noteTypingActivity(hasText: Bool) {
        typingStopTask?.cancel()

        guard hasText else {
            stopTyping()
            return
        }

        if !typingActive {
            typingActive = true
            realtimeManager.sendTyping(isTyping: true, userID: currentUserID)
        }

        typingStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.stopTyping()
            }
        }
    }

    private func stopTyping() {
        typingStopTask?.cancel()
        typingStopTask = nil
        guard typingActive else { return }
        typingActive = false
        realtimeManager.sendTyping(isTyping: false, userID: currentUserID)
    }

    private func beginSend() {
        pendingSendCount += 1
        isSending = pendingSendCount > 0
    }

    private func endSend() {
        pendingSendCount = max(0, pendingSendCount - 1)
        isSending = pendingSendCount > 0
    }

    // MARK: - Realtime

    private func setupRealtimeCallbacks() {
        realtimeManager.onMessageInserted = { [weak self] payload in
            Task { @MainActor in
                await self?.ingestRealtime(payload, replacingExisting: false)
            }
        }

        realtimeManager.onMessageUpdated = { [weak self] payload in
            Task { @MainActor in
                await self?.ingestRealtime(payload, replacingExisting: true)
            }
        }

        realtimeManager.onMessageDeleted = { [weak self] messageID in
            Task { @MainActor in
                self?.items.removeAll { $0.id == messageID }
            }
        }

        realtimeManager.onTypingChanged = { [weak self] userIDs in
            Task { @MainActor in
                guard let self else { return }
                self.isPeerTyping = userIDs.contains(self.identity.peerUserID)
            }
        }
    }

    private func ingestRealtime(
        _ payload: RealtimeMessagePayload,
        replacingExisting: Bool
    ) async {
        guard payload.chatID == identity.chatID else { return }

        do {
            let decoded = try await chatRepository.decodeRealtimeMessage(
                payload,
                connectionID: identity.connectionID,
                peerUserID: identity.peerUserID,
                peerDisplayName: identity.peerDisplayName,
                currentUserID: currentUserID
            )

            if let index = items.firstIndex(where: { $0.id == decoded.id }) {
                var replacement = decoded
                if replacement.reactions.isEmpty {
                    replacement.reactions = items[index].reactions
                }
                items[index] = replacement
            } else if !replacingExisting {
                items.append(decoded)
                items.sort { $0.createdAt < $1.createdAt }
            }

            if !decoded.isOutgoing {
                try? await chatRepository.markDelivered(
                    chatID: identity.chatID,
                    messageIDs: [decoded.id]
                )
                try? await chatRepository.markRead(
                    chatID: identity.chatID,
                    messageIDs: [decoded.id]
                )
            }
        } catch {
            operationError = error.localizedDescription
        }
    }
}

// MARK: - Preview fixtures

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
                content: "Sounds perfect! Let’s meet at Ritual Coffee at 3:30 PM.",
                createdAt: Calendar.current.date(byAdding: .minute, value: -2, to: Date())!,
                deliveryStatus: .delivered,
                isOutgoing: true,
                replyToID: "msg-3",
                replyToSnippet: "Are you free for a coffee catch-up later this afternoon around Hayes Valley?",
                replyToSenderName: "Maya Lin",
                reactions: [ReactionSummary(reactionType: "☕️", count: 1, userReacted: true)]
            )
        ]

        return ConversationModel(
            identity: identity,
            chatRepository: PreviewChatRepo(initial: initial),
            currentUserID: "user-self",
            currentUserName: "Alex",
            initialItems: initial
        )
    }
}

private struct PreviewChatRepo: ChatRepositoryProtocol {
    let initial: [ChatMessageItem]

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
        initial
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
        ChatMessageItem(
            id: clientMessageID,
            chatID: chatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: content,
            deliveryStatus: .delivered,
            isOutgoing: true,
            replyToID: replyToID,
            replyToSnippet: replyToSnippet,
            replyToSenderName: replyToSenderName
        )
    }

    func editMessage(
        message: ChatMessageItem,
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        newContent: String
    ) async throws {}

    func deleteMessage(messageID: String) async throws {}
    func setReaction(messageID: String, reactionType: String, adding: Bool) async throws {}
    func markRead(chatID: String, messageIDs: [String]) async throws {}
    func markDelivered(chatID: String, messageIDs: [String]) async throws {}
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
            senderName: peerDisplayName,
            content: payload.content,
            createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
            deliveryStatus: .delivered,
            isOutgoing: payload.senderID == currentUserID
        )
    }
}
