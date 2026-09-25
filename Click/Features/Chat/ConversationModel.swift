import Foundation
import Observation

/// An attachment waiting in the composer tray.
public struct StagedAttachment: Identifiable, Sendable {
    public let id = UUID()
    public let draft: MediaDraft
}

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
    /// Display names of whoever is typing in a group or hub (empty for direct chats).
    public private(set) var typingNames: [String] = []
    public var operationError: String?
    /// The first incoming message that was unread when the chat opened ("New messages" divider).
    /// Captured once per visit, before the timeline is marked read.
    public private(set) var firstUnreadID: String?
    private var hasCapturedUnread = false
    /// True while showing a history window (search jump) that isn't contiguous with the latest page.
    public private(set) var isDetachedFromLatest = false

    private let chatRepository: ChatRepositoryProtocol
    private let timelineCache: ConversationTimelineCache?
    private let realtimeManager: ChatRealtimeManager
    private let currentUserID: String
    private let currentUserName: String
    private let identities: IdentityCache?
    /// Decrypted media locations by message ID (this conversation only).
    private var mediaURLs: [String: URL] = [:]
    /// Optimistic rows and their payloads; outlives this screen so sends finish in the background.
    private let pendingSends: PendingSendStore
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
        timelineCache: ConversationTimelineCache? = nil,
        pendingSends: PendingSendStore? = nil,
        identities: IdentityCache? = nil
    ) {
        self.identities = identities
        self.timelineCache = timelineCache
        self.pendingSends = pendingSends ?? PendingSendStore()
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
                if items.isEmpty, !error.isCancellation {
                    phase = .failed(error.userFacingMessage)
                }
                return
            }
        }

        // Restore sends that were still in flight (or failed) when this chat last closed.
        for pending in pendingSends.attach(self, chatID: identity.chatID) where !items.contains(where: { $0.id == pending.id }) {
            items.append(pending)
        }
        items.sort { $0.createdAt < $1.createdAt }

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
        let fetchedClientIDs = Set(fetched.compactMap(\.clientMessageID))
        // A refresh can land before the send POST returns: the server already has the row
        // (matched by client ID), so the optimistic copy must not show twice.
        let pending = items.filter {
            ($0.deliveryStatus == .sending || $0.deliveryStatus == .failed)
                && !fetchedIDs.contains($0.id) && !fetchedClientIDs.contains($0.id)
        }
        let knownClientIDs = Dictionary(items.compactMap { item in item.clientMessageID.map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let fetched = fetched.map { item -> ChatMessageItem in
            guard item.clientMessageID == nil, let clientID = knownClientIDs[item.id] else { return item }
            var kept = item
            kept.clientMessageID = clientID
            return kept
        }
        // Older pages already loaded stay put when the latest page refreshes.
        let oldestFetched = fetched.map(\.createdAt).min() ?? .distantFuture
        let older = items.filter { $0.createdAt < oldestFetched && !fetchedIDs.contains($0.id) && $0.deliveryStatus != .sending && $0.deliveryStatus != .failed }
        return (older + fetched + pending).sorted { $0.createdAt < $1.createdAt }
    }

    private func saveToCache() {
        guard !isDetachedFromLatest else { return }
        timelineCache?.store(
            items.filter { $0.deliveryStatus != .sending && $0.deliveryStatus != .failed },
            for: [identity.chatID, identity.connectionID ?? ""]
        )
    }

    public func onDisappear() {
        saveToCache()
        pendingSends.detach(self, chatID: identity.chatID)
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
            if !hasCapturedUnread, identity.supportsReceipts {
                hasCapturedUnread = true
                firstUnreadID = items.first { !$0.isOutgoing && !$0.isDeleted && $0.deliveryStatus != .read }?.id
            }

            let unreadIDs = items
                .filter { !$0.isOutgoing && $0.deliveryStatus != .read }
                .map(\.id)
            if identity.supportsReceipts, !unreadIDs.isEmpty {
                try? await chatRepository.markRead(chatID: identity.chatID, messageIDs: unreadIDs)
            }
        } catch {
            if error.isCancellation {
                if phase == .loading { phase = items.isEmpty ? .initial : .loaded }
            } else if items.isEmpty {
                phase = .failed(error.userFacingMessage)
            } else {
                operationError = error.userFacingMessage
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

        let reply = replyTarget
        composerText = ""
        replyTarget = nil
        await sendText(text, reply: reply)
    }

    /// Sends a text message through the ordinary optimistic, encrypted pipeline (icebreakers too).
    public func sendText(_ text: String, reply: ChatMessageItem? = nil) async {
        stopTyping()
        await performSend(makeOptimistic(content: text, type: .text, reply: reply), payload: nil)
    }

    /// Retries a failed row in place with its original client ID (never a duplicate).
    public func retrySend(item: ChatMessageItem) async {
        let chatID = identity.chatID
        if pendingSends.item(clientID: item.id, chatID: chatID) == nil {
            // A failed text row from before this store existed: re-register it as-is.
            pendingSends.add(item, chatID: chatID, payload: nil)
        }
        pendingSends.ensureAttached(self, chatID: chatID)
        await transmitPending(clientID: item.id, chatID: chatID)
    }

    /// Removes a failed row the user gave up on.
    public func discardFailed(item: ChatMessageItem) {
        guard item.deliveryStatus == .failed else { return }
        pendingSends.discard(clientID: item.id, chatID: identity.chatID)
        items.removeAll { $0.id == item.id }
    }

    private func makeOptimistic(
        content: String,
        type: MessageType,
        reply: ChatMessageItem?,
        media: MessageMedia? = nil,
        localMediaURL: URL? = nil,
        beacon: SharedBeacon? = nil,
        clientID: String = UUID().uuidString.lowercased()
    ) -> ChatMessageItem {
        ChatMessageItem(
            id: clientID,
            chatID: identity.chatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: content,
            messageType: type,
            createdAt: Date(),
            deliveryStatus: .sending,
            isOutgoing: true,
            replyToID: reply?.id,
            replyToSnippet: reply.map(Self.quoteText),
            replyToSenderName: reply?.senderName,
            media: media,
            localMediaURL: localMediaURL,
            beacon: beacon,
            clientMessageID: clientID
        )
    }

    /// One path for every outgoing kind (text, media, beacon) in DMs, groups and hubs: the row
    /// appears immediately, then is sent; the result replaces it in place.
    private func performSend(_ optimistic: ChatMessageItem, payload: PendingSendPayload?) async {
        let chatID = identity.chatID
        pendingSends.ensureAttached(self, chatID: chatID)
        pendingSends.add(optimistic, chatID: chatID, payload: payload)
        await transmitPending(clientID: optimistic.id, chatID: chatID)
    }

    private func transmitPending(clientID: String, chatID: String) async {
        guard let item = pendingSends.item(clientID: clientID, chatID: chatID) else { return }
        let payload = pendingSends.payload(for: clientID)
        let store = pendingSends
        store.update(clientID: clientID, chatID: chatID) {
            $0.deliveryStatus = .sending
            $0.uploadProgress = nil
        }
        beginSend()
        defer { endSend() }
        do {
            let server: ChatMessageItem
            switch payload {
            case .media(let draft)?:
                var sent = try await chatRepository.sendMedia(
                    conversation: identity,
                    currentUserID: currentUserID,
                    currentUserName: currentUserName,
                    draft: draft,
                    replyToID: item.replyToID,
                    clientMessageID: clientID,
                    progress: { stage in
                        Task { @MainActor in
                            store.update(clientID: clientID, chatID: chatID) { $0.uploadProgress = stage }
                        }
                    }
                )
                sent.replyToSnippet = item.replyToSnippet
                sent.replyToSenderName = item.replyToSenderName
                server = sent
            case .beacon(let beacon)?:
                server = try await chatRepository.sendBeacon(
                    conversation: identity, currentUserID: currentUserID, currentUserName: currentUserName,
                    beacon: beacon, clientMessageID: clientID
                )
            case nil:
                server = try await chatRepository.sendMessage(
                    conversation: identity,
                    currentUserID: currentUserID,
                    currentUserName: currentUserName,
                    content: item.content,
                    replyToID: item.replyToID,
                    replyToSnippet: item.replyToSnippet,
                    replyToSenderName: item.replyToSenderName,
                    clientMessageID: clientID
                )
            }
            store.finish(clientID: clientID, chatID: chatID, serverItem: server)
            operationError = nil
        } catch {
            store.update(clientID: clientID, chatID: chatID) {
                $0.deliveryStatus = .failed
                $0.uploadProgress = nil
            }
            if !error.isCancellation { operationError = error.userFacingMessage }
        }
    }

    /// Swaps an optimistic row for the server's, unless the realtime echo already added it.
    /// The server row keeps the optimistic row's `stableID`, so SwiftUI updates the bubble in
    /// place (receipt tick animates) instead of removing and re-inserting it.
    private func replaceOptimistic(_ clientID: String, with serverItem: ChatMessageItem) {
        var server = serverItem
        server.clientMessageID = clientID
        if server.id != clientID, let echoed = items.firstIndex(where: { $0.id == server.id }) {
            // The realtime echo already landed; keep one row with the optimistic identity.
            items[echoed].clientMessageID = clientID
            items.removeAll { $0.id == clientID }
        } else if let index = items.firstIndex(where: { $0.id == clientID }) {
            if server.localMediaURL == nil { server.localMediaURL = items[index].localMediaURL }
            items[index] = server
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
            operationError = error.userFacingMessage
        }
    }

    /// Shares an event/beacon card into this conversation (optimistic, same send animation).
    public func sendBeacon(_ beacon: MapBeacon) async {
        let clientID = UUID().uuidString.lowercased()
        let content = "Beacon: \(beacon.title)"
        let card = SharedBeacon.parse(messageType: "beacon", metadata: ChatRepository.beaconMetadata(beacon, clientMessageID: clientID), content: content)
        await performSend(makeOptimistic(content: content, type: .beacon, reply: nil, beacon: card, clientID: clientID), payload: .beacon(beacon))
    }

    /// Attachments picked but not yet sent (photos, a file, a reviewed voice note).
    public private(set) var staged: [StagedAttachment] = []
    public static let maxStaged = 10

    /// Adds a picked attachment to the tray above the composer after checking server limits.
    public func stage(_ draft: MediaDraft) {
        if let rejection = MediaValidator.validate(draft) {
            operationError = rejection.errorDescription
            return
        }
        guard staged.count < Self.maxStaged else {
            operationError = "You can send up to \(Self.maxStaged) attachments at a time."
            return
        }
        staged.append(StagedAttachment(draft: draft))
    }

    public func unstage(_ id: UUID) {
        staged.removeAll { $0.id == id }
    }

    /// The composer's send: staged attachments (all rows appear at once, uploads run in
    /// parallel), then the text as a caption. Edits go through `sendOrUpdateMessage`.
    public func sendComposer() async {
        guard editTarget == nil, !staged.isEmpty else {
            await sendOrUpdateMessage()
            return
        }
        let drafts = staged.map(\.draft)
        staged.removeAll()
        let reply = replyTarget
        replyTarget = nil
        let chatID = identity.chatID
        let clientIDs = drafts.enumerated().compactMap { index, draft in
            enqueueMedia(draft, reply: index == 0 ? reply : nil)
        }
        await withTaskGroup(of: Void.self) { group in
            for clientID in clientIDs {
                group.addTask { await self.transmitPending(clientID: clientID, chatID: chatID) }
            }
        }
        if !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await sendOrUpdateMessage()
        }
    }

    /// Sends one image, voice note, or file immediately (Click Drop, tests).
    public func sendMedia(_ draft: MediaDraft) async {
        let reply = replyTarget
        replyTarget = nil
        guard let clientID = enqueueMedia(draft, reply: reply) else { return }
        await transmitPending(clientID: clientID, chatID: identity.chatID)
    }

    /// Validates, then shows the optimistic bubble with the local file at its real aspect ratio.
    /// Returns nil (and a clear message) when the server would reject it.
    private func enqueueMedia(_ draft: MediaDraft, reply: ChatMessageItem?) -> String? {
        if let rejection = MediaValidator.validate(draft) {
            operationError = rejection.errorDescription
            return nil
        }
        let clientID = UUID().uuidString.lowercased()
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(clientID).\(MessageMedia.fileExtension(forMIME: draft.mimeType))")
        try? draft.data.write(to: local, options: .completeFileProtection)
        let media = MessageMedia(
            kind: draft.kind, mimeType: draft.mimeType, fileName: draft.fileName, sizeBytes: draft.data.count,
            durationSeconds: draft.durationSeconds, remoteURL: nil, storagePath: nil, v2: nil,
            fileKey: nil, plaintextSha256: nil, isDisposable: false,
            revealAt: nil, waveform: draft.waveform
        )
        let optimistic = makeOptimistic(
            content: draft.fileName ?? "",
            type: MessageType(rawValue: draft.kind.rawValue) ?? .file,
            reply: reply,
            media: media,
            localMediaURL: local,
            clientID: clientID
        )
        let chatID = identity.chatID
        pendingSends.ensureAttached(self, chatID: chatID)
        pendingSends.add(optimistic, chatID: chatID, payload: .media(draft))
        return clientID
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
            operationError = error.userFacingMessage
        }
    }

    public func deleteMessage(item: ChatMessageItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let original = items[index]
        items[index] = original.tombstoned()

        do {
            try await chatRepository.deleteMessage(messageID: item.id, conversation: identity)
            operationError = nil
        } catch {
            if let current = items.firstIndex(where: { $0.id == item.id }) { items[current] = original }
            operationError = error.userFacingMessage
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
            adding: adding,
            userID: currentUserID
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
            operationError = error.userFacingMessage
        }
    }

    private static func mutatedReactions(
        _ source: [ReactionSummary],
        reactionType: String,
        adding: Bool,
        userID: String
    ) -> [ReactionSummary] {
        var reactions = source
        if let index = reactions.firstIndex(where: { $0.reactionType == reactionType }) {
            if adding {
                guard !reactions[index].userReacted else { return reactions }
                reactions[index].count += 1
                reactions[index].userReacted = true
                reactions[index].userIDs.append(userID)
            } else {
                guard reactions[index].userReacted else { return reactions }
                reactions[index].count -= 1
                reactions[index].userReacted = false
                reactions[index].userIDs.removeAll { $0 == userID }
                if reactions[index].count <= 0 {
                    reactions.remove(at: index)
                }
            }
        } else if adding {
            reactions.append(
                ReactionSummary(
                    reactionType: reactionType,
                    count: 1,
                    userReacted: true,
                    userIDs: [userID]
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
                // Shown as "Message deleted" in place rather than vanishing mid-read.
                guard let self, let index = self.items.firstIndex(where: { $0.id == messageID }) else { return }
                self.items[index] = self.items[index].tombstoned()
            }
        }

        realtimeManager.onTypingChanged = { [weak self] userIDs in
            Task { @MainActor in
                await self?.typingChanged(userIDs)
            }
        }
    }

    private func typingChanged(_ userIDs: Set<String>) async {
        if identity.isDirect {
            isPeerTyping = userIDs.contains(identity.peerUserID)
            return
        }
        let others = userIDs.subtracting([currentUserID]).sorted()
        isPeerTyping = !others.isEmpty
        // Names already on screen first, then the shared resolver.
        var names: [String: String] = [:]
        for item in items where others.contains(item.senderID) && !item.senderName.isEmpty { names[item.senderID] = item.senderName }
        let missing = others.filter { names[$0] == nil }
        if !missing.isEmpty, let resolved = await identities?.resolve(missing) {
            for (id, identity) in resolved { if let name = identity.name { names[id] = name } }
        }
        typingNames = others.compactMap { names[$0] }
    }

    /// "Lena is typing…", "Lena and Sam are typing…", "Lena and 2 others are typing…".
    nonisolated static func typingLabel(names: [String], count: Int) -> String {
        let first = names.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        guard let lead = first.first, count > 0 else { return count > 0 ? "Someone is typing…" : "" }
        switch count {
        case 1: return "\(lead) is typing…"
        case 2 where first.count >= 2: return "\(lead) and \(first[1]) are typing…"
        default: return "\(lead) and \(count - 1) \(count - 1 == 1 ? "other" : "others") are typing…"
        }
    }

    // MARK: - Search and jump (spec §34)

    /// IDs of loaded messages whose plaintext matches `query`, oldest first.
    nonisolated static func searchMatches(in items: [ChatMessageItem], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        return items.filter { item in
            guard !item.isDeleted else { return false }
            let text = item.beacon?.title ?? item.media?.displayName ?? item.content
            return text.localizedCaseInsensitiveContains(needle)
        }
        .map(\.id)
    }

    /// Makes `messageID` part of the timeline, loading a window around it when it isn't loaded.
    /// Returns the row's `stableID` to scroll to, or nil when the server doesn't have it.
    public func reveal(messageID: String) async -> String? {
        if let item = items.first(where: { $0.id == messageID || $0.clientMessageID == messageID }) { return item.stableID }
        do {
            let window = try await chatRepository.fetchMessages(around: messageID, conversation: identity, currentUserID: currentUserID, limit: 20)
            guard let target = window.first(where: { $0.id == messageID }) else { return nil }
            items = Self.mergeWindow(window, into: items)
            if !items.contains(where: { $0.id == messageID }) {
                // Not contiguous with what's loaded: show the window alone until "latest".
                isDetachedFromLatest = true
                hasMoreHistory = identity.hubID == nil
                items = (window + items.filter { $0.deliveryStatus == .sending || $0.deliveryStatus == .failed })
                    .sorted { $0.createdAt < $1.createdAt }
            }
            resolveReplyQuotes()
            return target.stableID
        } catch {
            if !error.isCancellation { operationError = error.userFacingMessage }
            return nil
        }
    }

    /// Joins a fetched window to the loaded timeline only when they overlap or touch; otherwise
    /// returns the loaded timeline unchanged (a gap must never look continuous).
    nonisolated static func mergeWindow(_ window: [ChatMessageItem], into loaded: [ChatMessageItem]) -> [ChatMessageItem] {
        let settled = loaded.filter { $0.deliveryStatus != .sending && $0.deliveryStatus != .failed }
        guard let windowNewest = window.map(\.createdAt).max(), let loadedOldest = settled.map(\.createdAt).min() else {
            return settled.isEmpty ? (window + loaded).sorted { $0.createdAt < $1.createdAt } : loaded
        }
        let loadedIDs = Set(loaded.map(\.id))
        let overlaps = window.contains { loadedIDs.contains($0.id) } || windowNewest >= loadedOldest
        guard overlaps else { return loaded }
        return (window.filter { !loadedIDs.contains($0.id) } + loaded).sorted { $0.createdAt < $1.createdAt }
    }

    /// Leaves a detached search window and reloads the latest page.
    public func returnToLatest() async {
        guard isDetachedFromLatest else { return }
        isDetachedFromLatest = false
        items = items.filter { $0.deliveryStatus == .sending || $0.deliveryStatus == .failed }
        await loadMessages()
    }

    /// The next locked Click Drop in this timeline to develop, and whether it's ours.
    public var nextClickDropReveal: (date: Date, isOutgoing: Bool)? {
        items.compactMap { item -> (Date, Bool)? in
            guard let media = item.media, media.isLocked(), let revealAt = media.revealAt else { return nil }
            return (revealAt, item.isOutgoing)
        }
        .min { $0.0 < $1.0 }
    }

    // MARK: - Forward (spec §33)

    /// Messages that can be forwarded: live text and non-Click-Drop media.
    public func canForward(_ item: ChatMessageItem) -> Bool {
        guard !item.isDeleted, item.beacon == nil, item.deliveryStatus != .sending, item.deliveryStatus != .failed else { return false }
        return !(item.media?.isDisposable ?? false)
    }

    /// Re-sends a message's plaintext into another conversation. Media is re-encrypted for the
    /// target from the decrypted local copy (ciphertext never crosses chats), with a fresh client ID.
    public func forward(_ item: ChatMessageItem, to target: ConversationIdentity) async throws {
        let clientID = UUID().uuidString.lowercased()
        if let media = item.media {
            let url = try await mediaURL(for: item)
            var draft = MediaDraft(kind: media.kind, data: try Data(contentsOf: url), mimeType: media.mimeType,
                                   fileName: media.fileName, durationSeconds: media.durationSeconds)
            draft.waveform = media.waveform
            _ = try await chatRepository.sendMedia(conversation: target, currentUserID: currentUserID, currentUserName: currentUserName,
                                                   draft: draft, replyToID: nil, clientMessageID: clientID)
        } else {
            _ = try await chatRepository.sendMessage(conversation: target, currentUserID: currentUserID, currentUserName: currentUserName,
                                                     content: item.content, replyToID: nil, replyToSnippet: nil, replyToSenderName: nil,
                                                     clientMessageID: clientID)
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
            operationError = error.userFacingMessage
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

extension ConversationModel: PendingSendReceiver {
    public func pendingSendChanged(_ item: ChatMessageItem) {
        if let local = item.localMediaURL { mediaURLs[item.id] = local }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else if !items.contains(where: { $0.clientMessageID == item.id && $0.id != item.id }) {
            items.append(item)
        }
    }

    public func pendingSendFinished(clientID: String, serverItem: ChatMessageItem) {
        if let local = mediaURLs[clientID] { mediaURLs[serverItem.id] = serverItem.localMediaURL ?? local }
        replaceOptimistic(clientID, with: serverItem)
        saveToCache()
    }
}
