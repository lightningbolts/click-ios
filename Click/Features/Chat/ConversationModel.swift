import Foundation
import Observation

public enum LoadPhase: Sendable, Equatable {
    case initial
    case loading
    case loaded
    case failed(String)
}

/// Single authoritative presentation model for every conversation kind (spec §31.1).
@Observable
@MainActor
public final class ConversationModel {
    public private(set) var identity: ConversationIdentity
    public private(set) var phase: LoadPhase = .initial
    public private(set) var items: [ChatMessageItem] = []
    public private(set) var isSending = false
    /// Older history paging (`cursor` = oldest `time_created`).
    public private(set) var isLoadingOlder = false
    public private(set) var hasMoreHistory = true
    private static let pageSize = 50
    public var composerText = ""
    public var replyTarget: ChatMessageItem?
    public var editTarget: ChatMessageItem?
    public var isPeerTyping = false
    public var operationError: String?

    private let chatRepository: ChatRepositoryProtocol
    private let timelineCache: ConversationTimelineCache?
    private let realtimeManager: ChatRealtimeManager
    private let currentUserID: String
    private let currentUserName: String
    /// Decrypted media locations by message ID (this conversation only).
    private var mediaURLs: [String: URL] = [:]
    /// Drafts of media sends that failed, kept in memory for retry.
    private var failedMediaDrafts: [String: MediaDraft] = [:]
    private var pendingSendCount = 0
    private var typingActive = false
    private var typingStopTask: Task<Void, Never>?

    public init(
        identity: ConversationIdentity,
        chatRepository: ChatRepositoryProtocol,
        realtimeManager: ChatRealtimeManager = ChatRealtimeManager(),
        currentUserID: String,
        currentUserName: String = "You",
        initialItems: [ChatMessageItem]? = nil,
        timelineCache: ConversationTimelineCache? = nil
    ) {
        self.timelineCache = timelineCache
        self.identity = identity
        self.chatRepository = chatRepository
        self.realtimeManager = realtimeManager
        self.currentUserID = currentUserID
        self.currentUserName = currentUserName

        if let initialItems {
            self.items = initialItems
            self.phase = .loaded
        } else if let cached = timelineCache.flatMap({ cache in
            [identity.chatID, identity.connectionID ?? ""].lazy.compactMap { cache.items(for: $0) }.first
        }) {
            // Paint the last-seen timeline immediately; loadMessages refreshes it in place.
            self.items = cached
            self.phase = .loaded
        }
    }

    public var realtimeHealth: SubscriptionHealth {
        realtimeManager.health
    }

    // MARK: - Lifecycle

    public func onAppear(supabaseURL: URL?, anonKey: String?, authToken: String?) async {
        setupRealtimeCallbacks()

        if identity.hubID == nil {
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
        }

        if let supabaseURL, let anonKey {
            realtimeManager.subscribe(
                to: identity.chatID,
                stream: identity.hubID == nil ? .chat : .hub,
                supabaseURL: supabaseURL,
                anonKey: anonKey,
                authToken: authToken
            )
        }

        // Always refresh: a cached timeline painted first is updated in place.
        await loadMessages()
    }

    /// Keeps optimistic rows that are still sending when a refresh lands.
    private func mergeFetched(_ fetched: [ChatMessageItem]) -> [ChatMessageItem] {
        let fetchedIDs = Set(fetched.map(\.id))
        let pending = items.filter { ($0.deliveryStatus == .sending || $0.deliveryStatus == .failed) && !fetchedIDs.contains($0.id) }
        // Older pages already loaded stay put when the latest page refreshes.
        let oldestFetched = fetched.map(\.createdAt).min() ?? .distantFuture
        let older = items.filter { $0.createdAt < oldestFetched && !fetchedIDs.contains($0.id) && $0.deliveryStatus != .sending && $0.deliveryStatus != .failed }
        return (older + fetched + pending).sorted { $0.createdAt < $1.createdAt }
    }

    private func saveToCache() {
        timelineCache?.store(
            items.filter { $0.deliveryStatus != .sending && $0.deliveryStatus != .failed },
            for: [identity.chatID, identity.connectionID ?? ""]
        )
    }

    public func onDisappear() {
        saveToCache()
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
                conversation: identity,
                currentUserID: currentUserID,
                cursor: nil,
                limit: Self.pageSize
            )
            hasMoreHistory = fetched.count >= Self.pageSize
            items = mergeFetched(fetched)
            resolveReplyQuotes()
            phase = .loaded
            saveToCache()
            operationError = nil

            let unreadIDs = items
                .filter { !$0.isOutgoing && $0.deliveryStatus != .read }
                .map(\.id)
            if identity.supportsReceipts, !unreadIDs.isEmpty {
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
                conversation: identity,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                content: text,
                replyToID: capturedReply?.id,
                replyToSnippet: capturedReply?.content,
                replyToSenderName: capturedReply?.senderName,
                clientMessageID: clientID
            )

            replaceOptimistic(clientID, with: serverItem)
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
        if let draft = failedMediaDrafts.removeValue(forKey: item.id) {
            items.removeAll { $0.id == item.id }
            await sendMedia(draft, replyToID: item.replyToID, replyToSnippet: item.replyToSnippet, replyToSenderName: item.replyToSenderName)
            return
        }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].deliveryStatus = .sending
        beginSend()

        do {
            let serverItem = try await chatRepository.sendMessage(
                conversation: identity,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                content: item.content,
                replyToID: item.replyToID,
                replyToSnippet: item.replyToSnippet,
                replyToSenderName: item.replyToSenderName,
                clientMessageID: item.id
            )
            replaceOptimistic(item.id, with: serverItem)
            operationError = nil
        } catch {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].deliveryStatus = .failed
            }
            operationError = error.localizedDescription
        }

        endSend()
    }

    /// Swaps an optimistic row for the server's, unless the realtime echo already added it.
    private func replaceOptimistic(_ clientID: String, with serverItem: ChatMessageItem) {
        if serverItem.id != clientID, items.contains(where: { $0.id == serverItem.id }) {
            items.removeAll { $0.id == clientID }
        } else if let index = items.firstIndex(where: { $0.id == clientID }) {
            items[index] = serverItem
        }
    }

    // MARK: - Media (spec §37)

    public var supportsMedia: Bool { identity.hubID == nil }

    /// Loads the page before the oldest loaded message; keeps the visual anchor (the view
    /// prepends without jumping because rows keep stable IDs).
    public func loadOlder() async {
        guard hasMoreHistory, !isLoadingOlder, identity.hubID == nil, let oldest = items.first(where: { $0.deliveryStatus != .sending && $0.deliveryStatus != .failed }) else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let older = try await chatRepository.fetchMessages(
                conversation: identity,
                currentUserID: currentUserID,
                cursor: Int64(oldest.createdAt.timeIntervalSince1970 * 1000),
                limit: Self.pageSize
            )
            let known = Set(items.map(\.id))
            let fresh = older.filter { !known.contains($0.id) }
            hasMoreHistory = older.count >= Self.pageSize
            guard !fresh.isEmpty else { return }
            items = (fresh + items).sorted { $0.createdAt < $1.createdAt }
            resolveReplyQuotes()
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Shares an event/beacon card into this conversation.
    public func sendBeacon(_ beacon: MapBeacon) async {
        beginSend()
        defer { endSend() }
        do {
            let sent = try await chatRepository.sendBeacon(
                conversation: identity, currentUserID: currentUserID, currentUserName: currentUserName,
                beacon: beacon, clientMessageID: UUID().uuidString.lowercased()
            )
            if !items.contains(where: { $0.id == sent.id }) { items.append(sent) }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Sends an image, voice note, or file with an optimistic local bubble.
    public func sendMedia(_ draft: MediaDraft) async {
        let reply = replyTarget
        replyTarget = nil
        await sendMedia(draft, replyToID: reply?.id, replyToSnippet: reply.map(Self.quoteText), replyToSenderName: reply?.senderName)
    }

    private func sendMedia(_ draft: MediaDraft, replyToID: String?, replyToSnippet: String?, replyToSenderName: String?) async {
        let clientID = UUID().uuidString.lowercased()
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(clientID).\(MessageMedia.fileExtension(forMIME: draft.mimeType))")
        try? draft.data.write(to: local, options: .completeFileProtection)
        let media = MessageMedia(
            kind: draft.kind, mimeType: draft.mimeType, fileName: draft.fileName, sizeBytes: draft.data.count,
            durationSeconds: draft.durationSeconds, remoteURL: nil, storagePath: nil, v2: nil,
            fileKey: nil, plaintextSha256: nil, isDisposable: false
        )
        items.append(ChatMessageItem(
            id: clientID,
            chatID: identity.chatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: draft.fileName ?? "",
            messageType: MessageType(rawValue: draft.kind.rawValue) ?? .file,
            createdAt: Date(),
            deliveryStatus: .sending,
            isOutgoing: true,
            replyToID: replyToID,
            replyToSnippet: replyToSnippet,
            replyToSenderName: replyToSenderName,
            media: media,
            localMediaURL: local
        ))
        mediaURLs[clientID] = local
        beginSend()
        do {
            var sent = try await chatRepository.sendMedia(
                conversation: identity,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                draft: draft,
                replyToID: replyToID,
                clientMessageID: clientID
            )
            sent.replyToSnippet = replyToSnippet
            sent.replyToSenderName = replyToSenderName
            mediaURLs[sent.id] = sent.localMediaURL ?? local
            replaceOptimistic(clientID, with: sent)
            operationError = nil
        } catch {
            if let index = items.firstIndex(where: { $0.id == clientID }) {
                items[index].deliveryStatus = .failed
            }
            failedMediaDrafts[clientID] = draft
            operationError = error.localizedDescription
        }
        endSend()
    }

    /// Decrypted local file for a media message; fetched at most once per conversation visit.
    public func mediaURL(for item: ChatMessageItem) async throws -> URL {
        if let url = mediaURLs[item.id] { return url }
        let url = try await chatRepository.loadMedia(for: item, conversation: identity, currentUserID: currentUserID)
        mediaURLs[item.id] = url
        return url
    }

    /// Text for a reply quote, never exposing attachment envelopes.
    static func quoteText(_ item: ChatMessageItem) -> String {
        if let media = item.media { return media.kind == .file ? "📎 \(media.displayName)" : media.displayName }
        return item.content
    }

    /// Fills reply quotes from the local, decrypted timeline (no excerpt is stored server-side).
    private func resolveReplyQuotes() {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in items.indices {
            guard let target = items[index].replyToID.flatMap({ byID[$0] }) else { continue }
            if items[index].replyToSnippet == nil { items[index].replyToSnippet = Self.quoteText(target) }
            if items[index].replyToSenderName == nil { items[index].replyToSenderName = target.senderName }
        }
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
                conversation: identity,
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
            try await chatRepository.deleteMessage(messageID: item.id, conversation: identity)
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
                adding: adding,
                conversation: identity
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

        guard hasText, identity.hubID == nil else {
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
                self.isPeerTyping = self.identity.isDirect
                    ? userIDs.contains(self.identity.peerUserID)
                    : !userIDs.subtracting([self.currentUserID]).isEmpty
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
                conversation: identity,
                currentUserID: currentUserID
            )

            // Our own send can echo back before the POST returns; it replaces the optimistic row.
            let clientID = payload.metadata?["client_message_id"] as? String
            if decoded.isOutgoing, let clientID, !items.contains(where: { $0.id == decoded.id }),
               let index = items.firstIndex(where: { $0.id == clientID }) {
                var replacement = decoded
                replacement.localMediaURL = items[index].localMediaURL
                if replacement.replyToSnippet == nil { replacement.replyToSnippet = items[index].replyToSnippet }
                if let local = items[index].localMediaURL { mediaURLs[decoded.id] = local }
                items[index] = replacement
            } else if let index = items.firstIndex(where: { $0.id == decoded.id }) {
                var replacement = decoded
                if replacement.reactions.isEmpty {
                    replacement.reactions = items[index].reactions
                }
                items[index] = replacement
            } else if !replacingExisting {
                items.append(decoded)
                items.sort { $0.createdAt < $1.createdAt }
            }
            resolveReplyQuotes()

            if !decoded.isOutgoing, identity.supportsReceipts {
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

    func fetchMessages(conversation: ConversationIdentity, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] {
        initial
    }

    func sendMessage(
        conversation: ConversationIdentity,
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
            chatID: conversation.chatID,
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

    func editMessage(message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String, newContent: String) async throws {}
    func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {}
    func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {}
    func markRead(chatID: String, messageIDs: [String]) async throws {}
    func markDelivered(chatID: String, messageIDs: [String]) async throws {}
    func registerDevice() async throws {}

    func decodeRealtimeMessage(_ payload: RealtimeMessagePayload, conversation: ConversationIdentity, currentUserID: String) async throws -> ChatMessageItem {
        ChatMessageItem(
            id: payload.id,
            chatID: payload.chatID,
            senderID: payload.senderID,
            senderName: conversation.peerDisplayName,
            content: payload.content,
            createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
            deliveryStatus: .delivered,
            isOutgoing: payload.senderID == currentUserID
        )
    }
}
