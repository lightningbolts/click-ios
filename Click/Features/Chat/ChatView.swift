import SwiftUI

/// Native conversation destination for direct chats, verified groups, and hubs.
///
/// Navigation chrome, interactive back progress, keyboard, and tab-bar visibility are owned by
/// SwiftUI rather than a second custom navigation hierarchy.
public struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ConversationModel
    /// Moves the UIKit timeline (jump to latest / to a message).
    @State private var timeline = TimelineController()
    /// Messages that arrived while the reader was scrolled up.
    @State private var unseenCount = 0
    @State private var screenWidth: CGFloat = 390
    @State private var viewerURL: ViewerURL?
    @Environment(ConversationListModel.self) private var conversations: ConversationListModel?
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingAction: PendingConversationAction?
    @State private var notice: String?

    @State private var quickLookURL: URL?
    @State private var sharingBeacon = false
    @State private var forwarding: ChatMessageItem?
    @State private var shareFile: ViewerURL?
    @State private var reactorsFor: ReactorsTarget?
    private struct ActionTarget: Identifiable {
        let message: ChatMessageItem
        let frame: CGRect
        var id: String { message.stableID }
    }
    @State private var actionTarget: ActionTarget?
    @State private var emojiPickerTarget: ChatMessageItem?
    @State private var confirmingDeleteMessage: ChatMessageItem?
    @State private var isSearching = false
    @State private var searchQuery = ""
    /// Index into the current matches (oldest first); nil until the reader steps.
    @State private var searchPosition: Int?
    @State private var highlightedID: String?
    /// Short confirmation capsule ("Your Click Drop developed").
    @State private var toast: String?


    private struct ReactorsTarget: Identifiable {
        let message: ChatMessageItem
        let reaction: String
        var id: String { message.id + reaction }
    }

    private struct ViewerURL: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// Hub-only extras: the hub (header visual), items for the options menu and the title tap (hub info).
    private let hub: HubInfo?
    private let hubMenu: AnyView?
    private let onOpenHubInfo: (() -> Void)?

    public init(model: ConversationModel, hub: HubInfo? = nil, hubMenu: AnyView? = nil, onOpenHubInfo: (() -> Void)? = nil) {
        self._model = State(initialValue: model)
        self.hub = hub
        self.hubMenu = hubMenu
        self.onOpenHubInfo = onOpenHubInfo
    }

    public var body: some View {
        chatSurface
            .task {
                await model.onAppear(
                    supabaseURL: AppConfig.shared.supabaseURL,
                    anonKey: AppConfig.shared.supabaseAnonKey,
                    authToken: env.session.currentSession?.jwt
                )
                // A search result opened this chat: bring that message into view.
                if let focus = env.pendingMessageFocus, focus.matches(model.identity) {
                    env.pendingMessageFocus = nil
                    await jump(to: focus.messageID)
                }
            }
            .fullScreenCover(item: $viewerURL) { item in
                MediaViewer(url: item.url)
            }
            .quickLookPreview($quickLookURL)
            .sheet(item: $forwarding) { item in
                ChatTargetPicker(title: "Forward", excludedChatIDs: Set([model.identity.chatID, model.identity.connectionID].compactMap { $0 })) { target in
                    try await model.forward(item, to: target)
                }
            }
            .sheet(item: $shareFile) { ActivityShareSheet(items: [$0.url]).presentationDetents([.medium, .large]) }
            .sheet(item: $reactorsFor) { target in
                ReactorsSheet(
                    reactions: target.message.reactions,
                    initial: target.reaction,
                    currentUserID: env.session.currentSession?.userId ?? "",
                    onRemoveOwnReaction: { emoji in
                        react(to: target.message, with: emoji)
                    },
                    onAddReaction: {
                        emojiPickerTarget = target.message
                    }
                )
            }
            .sheet(item: $emojiPickerTarget) { target in
                EmojiPickerSheet { emoji in
                    react(to: target, with: emoji)
                }
            }
            .confirmationDialog("Delete for everyone?", isPresented: Binding(
                get: { confirmingDeleteMessage != nil },
                set: { if !$0 { confirmingDeleteMessage = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let target = confirmingDeleteMessage {
                        Task { await model.deleteMessage(item: target) }
                    }
                }
            } message: {
                Text("Everyone in this chat will see \"Message deleted\" instead.")
            }
            .sheet(isPresented: $sharingBeacon) {
                BeaconSharePicker { beacon in Task { await model.sendBeacon(beacon) } }
            }
            .onDisappear {
                if env.activeChatID == model.identity.chatID {
                    env.activeChatID = nil
                    env.activeConnectionID = nil
                }
                model.onDisappear()
            }
            // Also on every re-appear (back from a profile pushed on top), not just the first.
            .onAppear(perform: markOnScreen)
            .onChange(of: model.identity.chatID) { markOnScreen() }
            // Only a new *latest* message matters here: the timeline keeps itself pinned while
            // the reader is at the bottom; our own sends always bring it into view.
            .onChange(of: model.items.last?.stableID) { oldID, newID in
                guard let newID, let oldID, newID != oldID else { return }
                if model.items.last?.isOutgoing == true {
                    timeline.scrollToBottom(animated: true)
                    unseenCount = 0
                } else if !timeline.isNearBottom {
                    unseenCount += 1
                }
            }
            .onChange(of: timeline.isNearBottom) { _, nearBottom in
                if nearBottom { unseenCount = 0 }
            }
            .onChange(of: highlightedID) { timeline.refreshVisibleRows() }
            .onChange(of: actionTarget?.id) { timeline.refreshVisibleRows() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.resume() } }
            }
            .task(id: model.nextClickDropReveal?.date) {
                // Local, in-chat only: the server's `disposable_reveal` push covers the background.
                guard let next = model.nextClickDropReveal else { return }
                try? await Task.sleep(for: .seconds(max(0, next.date.timeIntervalSinceNow) + 0.5))
                guard !Task.isCancelled else { return }
                await showToast(next.isOutgoing ? "Your Click Drop developed" : "A Click Drop developed")
            }
    }

    private var chatSurface: some View {
        Group {
            switch model.phase {
            case .initial where model.items.isEmpty:
                loadingState
            case .loading where model.items.isEmpty:
                loadingState
            case .failed(let message) where model.items.isEmpty:
                failureState(message: message)
            default:
                timelineView
            }
        }
        .background { ChatBackground(seed: model.identity.connectionID ?? model.identity.chatID).equatable() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        // In-view (not a cover): the chat never disappears underneath, so realtime, audio
        // and the keyboard state are untouched while actions are open.
        .overlay {
            if let target = actionTarget {
                actionOverlay(for: target).id(target.id)
            }
        }
        .overlay(alignment: .top) {
            if isSearching {
                searchBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let error = model.operationError, !model.items.isEmpty {
                operationBanner(error)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let connection = sayHiConnection {
                SayHiPanel(
                    deadline: connection.sayHiDeadline,
                    context: ([connection.encounterLocation] + connection.mutualTags).joined(separator: " "),
                    seed: connection.connectionID
                ) { prompt in
                    Task { await model.sendText(prompt) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                conversationTitle
                    .frame(width: max(120, screenWidth - 132), alignment: .leading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                conversationMenu
            }
        }
    }

    /// Tells the inbox and push presentation which conversation the reader is looking at.
    private func markOnScreen() {
        env.activeChatID = model.identity.chatID
        env.activeConnectionID = model.identity.connectionID
    }

    /// Rows for the timeline: day headers, the "New messages" divider, messages, typing.
    private var timelineRows: [ChatTimelineRow] {
        var rows: [ChatTimelineRow] = []
        rows.reserveCapacity(model.items.count + 8)
        var previousDay: Date?
        for item in model.items {
            let day = Calendar.current.startOfDay(for: item.createdAt)
            if day != previousDay {
                rows.append(.dateHeader(day))
                previousDay = day
            }
            if item.id == model.firstUnreadID { rows.append(.unreadDivider) }
            rows.append(.message(item.stableID))
        }
        if model.isPeerTyping { rows.append(.typing) }
        return rows
    }

    private var timelineView: some View {
        let items = model.items
        let indexByStableID = Dictionary(items.enumerated().map { ($0.element.stableID, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hasher = Hasher()
        hasher.combine(items)
        hasher.combine(model.typingNames)
        let version = hasher.finalize()
        return ChatTimelineView(
            rows: timelineRows,
            contentVersion: version,
            hasMoreHistory: model.hasMoreHistory,
            isLoadingOlder: model.isLoadingOlder,
            controller: timeline,
            rowContent: { row in
                switch row {
                case .dateHeader(let day):
                    AnyView(Self.dateHeader(day).frame(maxWidth: .infinity))
                case .unreadDivider:
                    AnyView(UnreadDivider())
                case .typing:
                    AnyView(typingIndicator)
                case .message(let stableID):
                    if let index = indexByStableID[stableID], items.indices.contains(index) {
                        AnyView(bubble(for: items[index], at: index, in: items, byID: byID))
                    } else {
                        AnyView(Color.clear.frame(height: 1))
                    }
                }
            },
            onNearTop: {
                Task { await model.loadOlder() }
            },
            onUserScroll: {
                if actionTarget != nil { actionTarget = nil }
            }
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            // Only when the reader has genuinely reached the start while a page is loading.
            if model.isLoadingOlder, model.items.count < 8 {
                ClickLoadingView(size: 24, fillsSpace: false).padding(.top, 4)
            }
        }
        .dropDestination(for: Data.self) { payloads, _ in
            Task {
                for data in payloads.prefix(ConversationModel.maxStaged) {
                    if let draft = await MediaDraftBuilder.image(from: data) {
                        model.stage(draft)
                    } else {
                        model.operationError = "Only photos can be dropped here. Use + to attach a file."
                    }
                }
            }
            return true
        }
        .overlay(alignment: .bottomTrailing) {
            if !timeline.isNearBottom || model.isDetachedFromLatest, !model.items.isEmpty {
                jumpToLatestButton
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCircleBackground()
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    private func bubble(for item: ChatMessageItem, at index: Int, in items: [ChatMessageItem], byID: [String: ChatMessageItem]) -> some View {
        MessageBubbleView(
            message: item,
            onReply: { target in
                withAnimation(ClickMotion.selection) {
                    model.editTarget = nil
                    model.replyTarget = target
                }
            },
            onEdit: { target in
                withAnimation(ClickMotion.selection) {
                    model.replyTarget = nil
                    model.editTarget = target
                    model.composerText = target.content
                }
            },
            onDelete: { target in Task { await model.deleteMessage(item: target) } },
            onToggleReaction: { target, emoji in react(to: target, with: emoji) },
            onRetrySend: { target in Task { await model.retrySend(item: target) } },
            showsSenderName: !model.identity.isDirect && Self.startsSenderRun(at: index, in: items),
            showsReceipts: model.identity.supportsReceipts,
            mediaLoader: { message in try await model.mediaURL(for: message) },   // never nil
            onOpenMedia: { url, kind in
                if kind == .image { viewerURL = ViewerURL(url: url) } else { quickLookURL = url }
            },
            onOpenBeacon: { beacon in
                env.router.navigate(to: beacon.isEvent ? .event(beaconID: beacon.beaconID) : .beacon(beaconID: beacon.beaconID))
            },
            onDiscardFailed: { target in withAnimation(ClickMotion.content) { model.discardFailed(item: target) } },
            onForward: conversations != nil && model.canForward(item) ? { forwarding = $0 } : nil,
            onSaveMedia: { target in Task { await saveOrShare(target) } },
            onShowReactions: { target, reaction in reactorsFor = ReactorsTarget(message: target, reaction: reaction) },
            replyTarget: item.replyToID.flatMap { byID[$0] },
            onTapReplyQuote: { id in Task { await jump(to: id) } },
            onLongPress: { message, frame in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                actionTarget = ActionTarget(message: message, frame: frame)
            },
            // The lifted copy stands in for the bubble while actions are open.
            isBubbleHidden: actionTarget?.message.stableID == item.stableID
        )
        .background {
            if highlightedID == item.stableID {
                ClickColors.accentForeground.opacity(0.14)
            }
        }
    }

    private func react(to item: ChatMessageItem, with emoji: String) {
        Task { await model.toggleReaction(item: item, reactionType: emoji) }
    }

    private func actionOverlay(for target: ActionTarget) -> some View {
        MessageActionOverlay(
            message: target.message,
            sourceFrame: target.frame,
            bubble: AnyView(
                MessageBubbleView(
                    message: target.message,
                    showsSenderName: false,
                    showsReceipts: model.identity.supportsReceipts,
                    mediaLoader: { msg in try await model.mediaURL(for: msg) },
                    replyTarget: target.message.replyToID.flatMap { replyID in
                        model.items.first { $0.id == replyID }
                    },
                    isLiftedCopy: true
                )
            ),
            actions: messageActions(for: target.message),
            onReact: { emoji in
                react(to: target.message, with: emoji)
            },
            onMoreReactions: {
                actionTarget = nil
                emojiPickerTarget = target.message
            },
            onDismiss: {
                // A settling overlay must not close one opened on another message meanwhile.
                if actionTarget?.id == target.id { actionTarget = nil }
            }
        )
    }

    private func messageActions(for item: ChatMessageItem) -> [MessageAction] {
        var actions: [MessageAction] = []

        // Reply: always
        actions.append(MessageAction(id: "reply", title: "Reply", systemImage: "arrowshape.turn.up.left") {
            withAnimation(ClickMotion.selection) {
                model.editTarget = nil
                model.replyTarget = item
            }
        })

        // Forward: if model.canForward(item) and conversations != nil
        if conversations != nil && model.canForward(item) {
            actions.append(MessageAction(id: "forward", title: "Forward", systemImage: "arrowshape.turn.up.right") {
                forwarding = item
            })
        }

        // Copy: if not media
        if !item.isMedia {
            actions.append(MessageAction(id: "copy", title: "Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = item.content
                ClickHaptics.success()
            })
        }

        // Edit: own text messages only (not media, event cards or call logs)
        if item.isOutgoing && item.messageType == .text && !item.isMedia && item.beacon == nil {
            actions.append(MessageAction(id: "edit", title: "Edit", systemImage: "pencil") {
                withAnimation(ClickMotion.selection) {
                    model.replyTarget = nil
                    model.editTarget = item
                    model.composerText = item.content
                }
            })
        }

        // Save to Photos / Share…: if media and not locked
        if let media = item.media, !media.isLocked() {
            let title = media.kind == .image ? "Save to Photos" : "Share…"
            let icon = media.kind == .image ? "square.and.arrow.down" : "square.and.arrow.up"
            actions.append(MessageAction(id: "save-share", title: title, systemImage: icon) {
                Task { await saveOrShare(item) }
            })
        }

        // Delete: if outgoing; destructive
        if item.isOutgoing {
            actions.append(MessageAction(id: "delete", title: "Delete", systemImage: "trash", isDestructive: true) {
                confirmingDeleteMessage = item
            })
        }

        return actions
    }

    private var jumpToLatestButton: some View {
        Button {
            Task {
                // A search window that isn't joined to the latest page reloads it first.
                await model.returnToLatest()
                timeline.scrollToBottom(animated: true)
            }
            unseenCount = 0
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                if unseenCount > 0 {
                    Text("\(unseenCount)")
                        .font(ClickTypography.metadataEmphasized)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(ClickColors.textPrimary)
            .frame(minWidth: 40, minHeight: 40)
            .padding(.horizontal, unseenCount > 0 ? 8 : 0)
            .glassCircleBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unseenCount > 0 ? "Jump to latest, \(unseenCount) new" : "Jump to latest")
    }

    private var composer: some View {
        ChatComposerView(
            text: $model.composerText,
            placeholder: composerPlaceholder,
            replyTarget: model.replyTarget,
            editTarget: model.editTarget,
            isSending: model.isSending,
            onCancelReply: {
                withAnimation(ClickMotion.selection) {
                    model.replyTarget = nil
                }
            },
            onCancelEdit: {
                withAnimation(ClickMotion.selection) {
                    model.editTarget = nil
                    model.composerText = ""
                }
            },
            onSend: {
                Task {
                    await model.sendComposer()
                }
            },
            onTypingChanged: { hasText in
                model.noteTypingActivity(hasText: hasText)
            },
            onDraft: { draft in
                // Click Drops go straight out from the camera; everything else is reviewed first.
                if draft.isClickDrop {
                    var drop = draft
                    drop.encounterID = env.clickDropSession?.encounterID(for: model.identity.connectionID)
                    Task { await model.sendMedia(drop) }
                } else {
                    model.stage(draft)
                }
            },
            onAttachmentError: { message in model.operationError = message },
            onShareBeacon: model.identity.hubID == nil ? { sharingBeacon = true } : nil,
            staged: model.staged,
            onUnstage: { id in model.unstage(id) },
            photosOnly: model.identity.hubID != nil,
            replyMediaLoader: { message in try await model.mediaURL(for: message) }
        )
        // Dialogs hang off the composer so the main body stays type-checkable.
        .modifier(OptionalConversationActionDialogs(model: conversations, pending: $pendingAction) {
            env.router.resetCurrentTabPath()
        })
        .alert("Chat", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    /// The same action list as the inbox row (one implementation, spec §29.7).
    @ViewBuilder
    private var conversationMenu: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass") {
                withAnimation(ClickMotion.selection) { isSearching = true }
            }
            switch model.identity.kind {
            case .direct:
                if let conversations, let item = conversations.connection(connectionID: model.identity.connectionID) {
                    DirectConversationActions(item: item, model: conversations, pending: $pendingAction) {
                        env.router.navigate(to: .userProfile(userID: model.identity.peerUserID, connectionID: model.identity.connectionID))
                    }
                } else {
                    Button("View profile", systemImage: "person.crop.circle") {
                        env.router.navigate(to: .userProfile(userID: model.identity.peerUserID, connectionID: model.identity.connectionID))
                    }
                    if let connectionID = model.identity.connectionID {
                        Section {
                            Button("Report", systemImage: "exclamationmark.bubble") {
                                pendingAction = .report(connectionID: connectionID, name: model.identity.peerDisplayName)
                            }
                            Button("Block", systemImage: "hand.raised", role: .destructive) {
                                pendingAction = .block(userID: model.identity.peerUserID, name: model.identity.peerDisplayName, connectionID: connectionID)
                            }
                        }
                    }
                }
            case .group:
                if let conversations, let group = conversations.group(chatID: model.identity.chatID) {
                    GroupConversationActions(
                        group: group,
                        model: conversations,
                        currentUserID: env.session.currentSession?.userId,
                        pending: $pendingAction,
                        onInfo: { env.router.navigate(to: .groupProfile(chatID: model.identity.chatID)) }
                    )
                } else {
                    Button("Group info", systemImage: "info.circle") {
                        env.router.navigate(to: .groupProfile(chatID: model.identity.chatID))
                    }
                }
            case .hub:
                hubMenu
            }
        } label: {
            Label("Conversation options", systemImage: "ellipsis")
        }
    }

    /// A new direct Click with fewer than 5 messages gets icebreakers (KMP rule, spec §42).
    private var sayHiConnection: ConnectionItem? {
        guard model.identity.isDirect, model.phase == .loaded,
              model.items.filter({ !$0.isDeleted }).count < Icebreakers.messageThreshold,
              let item = conversations?.connection(connectionID: model.identity.connectionID) else { return nil }
        return item
    }

    // MARK: - Search, jump, save

    private var searchMatches: [String] {
        ConversationModel.searchMatches(in: model.items, query: searchQuery)
    }

    private var searchBar: some View {
        let matches = searchMatches
        return ChatSearchBar(
            query: $searchQuery,
            matchCount: matches.count,
            position: searchPosition,
            canSearchOlder: model.hasMoreHistory,
            onPrevious: { Task { await stepSearch(older: true) } },
            onNext: { Task { await stepSearch(older: false) } },
            onDone: {
                withAnimation(ClickMotion.selection) { isSearching = false }
                searchQuery = ""
                searchPosition = nil
            }
        )
        .onChange(of: searchQuery) { searchPosition = nil }
    }

    /// Steps through matches newest → oldest; past the oldest, loads older history and retries.
    private func stepSearch(older: Bool) async {
        var matches = searchMatches
        let current = searchPosition ?? matches.count
        var next = older ? current - 1 : current + 1
        if older, next < 0 || matches.isEmpty, model.hasMoreHistory {
            let before = matches.count
            await model.loadOlder()
            matches = searchMatches
            next = matches.count - before - 1
        }
        guard matches.indices.contains(next) else { return }
        searchPosition = next
        await jump(to: matches[next])
    }

    /// Scrolls to a message (loading a window around it when needed) and flashes it.
    private func jump(to messageID: String) async {
        guard let stableID = await model.reveal(messageID: messageID) else {
            notice = "That message isn't available anymore."
            return
        }
        // Let the timeline apply the revealed window before scrolling to it.
        try? await Task.sleep(for: .milliseconds(60))
        timeline.scrollTo(stableID: stableID, animated: true)
        withAnimation(ClickMotion.subtleFade) { highlightedID = stableID }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(ClickMotion.subtleFade) { if highlightedID == stableID { highlightedID = nil } }
    }

    private func showToast(_ text: String) async {
        withAnimation(ClickMotion.content) { toast = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation(ClickMotion.content) { if toast == text { toast = nil } }
    }

    /// Images go to Photos; files and voice notes open the share sheet.
    private func saveOrShare(_ item: ChatMessageItem) async {
        do {
            let url = try await model.mediaURL(for: item)
            if item.media?.kind == .image {
                try await PhotoLibrarySaver.saveImage(at: url)
                ClickHaptics.success()
                await showToast("Saved to Photos")
            } else {
                shareFile = ViewerURL(url: url)
            }
        } catch {
            notice = error.userFacingMessage
        }
    }

    private var composerPlaceholder: String {
        switch model.identity.kind {
        case .direct, .group: "Message \(model.identity.peerDisplayName)…"
        case .hub: "Message everyone here…"
        }
    }

    private static func startsSenderRun(at index: Int, in items: [ChatMessageItem]) -> Bool {
        guard items.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        let previous = items[index - 1]
        let current = items[index]
        return previous.senderID != current.senderID
            || !Calendar.current.isDate(previous.createdAt, inSameDayAs: current.createdAt)
    }

    private var conversationTitle: some View {
        Button {
            switch model.identity.kind {
            case .direct:
                guard !model.identity.peerUserID.isEmpty else { return }
                ClickHaptics.selection()
                env.router.navigate(to: .userProfile(userID: model.identity.peerUserID, connectionID: model.identity.connectionID))
            case .group:
                ClickHaptics.selection()
                env.router.navigate(to: .groupProfile(chatID: model.identity.chatID))
            case .hub:
                onOpenHubInfo?()
            }
        } label: {
            HStack(spacing: 8) {
                if let hub {
                    // Event chats wear the event's banner, like their inbox row.
                    BeaconVisual(beaconID: hub.eventBeaconID, seed: hub.id, symbol: hub.isEventHub ? "calendar" : "house",
                                 cornerRadius: ClickMetrics.Avatar.navigation / 2)
                        .frame(width: ClickMetrics.Avatar.navigation, height: ClickMetrics.Avatar.navigation)
                } else {
                    AvatarView(
                        imageURL: model.identity.peerAvatarURL,
                        seed: model.identity.isDirect ? model.identity.peerUserID : model.identity.chatID,
                        initials: model.identity.initials,
                        size: ClickMetrics.Avatar.navigation
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.identity.peerDisplayName)
                        .font(ClickTypography.supportingEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)

                    Text(statusText)
                        .font(ClickTypography.caption)
                        .foregroundStyle(
                            model.isPeerTyping
                                ? ClickColors.accentForeground
                                : (model.identity.isOnline && model.identity.isDirect ? ClickColors.online : ClickColors.textSecondary)
                        )
                        .lineLimit(1)
                        .animation(.none, value: statusText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.identity.peerDisplayName), \(statusText)")
    }

    private var statusText: String {
        if model.isPeerTyping {
            return model.identity.isDirect
                ? "typing…"
                : ConversationModel.typingLabel(names: model.typingNames, count: max(1, model.typingNames.count))
        }
        switch model.identity.kind {
        case .group:
            let count = model.identity.participantUserIDs.count
            return count > 0 ? "\(count) members" : "Group"
        case .hub:
            return "Hub chat"
        case .direct:
            break
        }
        if model.identity.isOnline {
            return "Online"
        }
        if !model.identity.lastActiveText.isEmpty {
            return model.identity.lastActiveText
        }
        if !model.identity.peerHandle.isEmpty {
            return model.identity.peerHandle
        }
        return "Click"
    }

    private var loadingState: some View {
        ClickLoadingView("Loading conversation…")
    }

    private func failureState(message: String) -> some View {
        ContentUnavailableView {
            Label("Conversation unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await model.loadMessages() }
            }
            .buttonStyle(.borderedProminent)
            .tint(ClickColors.primaryActionFill)
        }
    }

    private func operationBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))

            Text(message)
                .font(ClickTypography.metadata)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button {
                withAnimation(ClickMotion.subtleFade) {
                    model.operationError = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(ClickColors.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ClickColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
    }

    private var typingIndicator: some View {
        HStack {
            TypingDots()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(ClickColors.messageIncoming)
                .clipShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
                .accessibilityLabel(statusText)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    /// Three dots pulsing in a wave (Messages-style), still under Reduce Motion.
    private struct TypingDots: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        // Each dot peaks a third of a cycle after the previous one.
                        let phase = (time * 2 * Double.pi / 1.2) - (Double(index) * 0.9)
                        let wave: Double = reduceMotion ? 0.5 : (sin(phase) + 1) / 2
                        let opacity = 0.4 + 0.5 * wave
                        let scale = 0.85 + 0.2 * wave
                        let offset = -2.5 * wave
                        Circle()
                            .fill(ClickColors.textSecondary.opacity(opacity))
                            .frame(width: 7, height: 7)
                            .scaleEffect(scale)
                            .offset(y: offset)
                    }
                }
                .frame(height: 12)
            }
        }
    }

    fileprivate static func dateHeader(_ date: Date) -> some View {
        Text(dateLabel(date))
            .font(ClickTypography.caption)
            .foregroundStyle(ClickColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ClickColors.surface)
            .clipShape(Capsule())
            .padding(.vertical, 8)
    }

    fileprivate static func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
