import SwiftUI

/// Native conversation destination for direct chats, verified groups, and hubs.
///
/// Navigation chrome, interactive back progress, keyboard, and tab-bar visibility are owned by
/// SwiftUI rather than a second custom navigation hierarchy.
public struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ConversationModel
    @State private var isNearBottom = true
    /// Topmost visible message, used to hold the reader's place while older history loads.
    @State private var topVisibleID: String?
    @State private var isTopSentinelVisible = false
    /// Messages that arrived while the reader was scrolled up.
    @State private var unseenCount = 0
    /// Insert animations run only after the first paint, never for the initial page.
    @State private var animatesInserts = false
    @State private var screenWidth: CGFloat = 390
    @State private var viewerURL: ViewerURL?
    @Environment(ConversationListModel.self) private var conversations: ConversationListModel?
    @State private var pendingAction: PendingConversationAction?
    @State private var notice: String?

    @State private var quickLookURL: URL?
    @State private var sharingBeacon = false
    @State private var forwarding: ChatMessageItem?
    @State private var shareFile: ViewerURL?
    @State private var reactorsFor: ReactorsTarget?
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

    public init(model: ConversationModel) {
        self._model = State(initialValue: model)
    }

    public var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch model.phase {
                case .initial where model.items.isEmpty:
                    loadingState

                case .loading where model.items.isEmpty:
                    loadingState

                case .failed(let message) where model.items.isEmpty:
                    failureState(message: message)

                default:
                    timeline(proxy: proxy)
                }
            }
            .background { ChatBackground(seed: model.identity.connectionID ?? model.identity.chatID) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .overlay(alignment: .top) {
                if isSearching {
                    searchBar(proxy: proxy)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let error = model.operationError, !model.items.isEmpty {
                    operationBanner(error)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let connection = sayHiConnection {
                    // An overlay, so it appears and leaves without moving the timeline.
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
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                // Identity cluster sits right after the back button, leading-aligned (prototype
                // chat header). The principal slot keeps it free of per-item glass chrome.
                ToolbarItem(placement: .principal) {
                    // The principal slot sizes to content (centered); an explicit width that
                    // spans back-button to menu keeps the cluster leading-aligned.
                    conversationTitle
                        .frame(width: max(120, screenWidth - 132), alignment: .leading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    conversationMenu
                }
            }
            .task {
                await model.onAppear(
                    supabaseURL: AppConfig.shared.supabaseURL,
                    anonKey: AppConfig.shared.supabaseAnonKey,
                    authToken: env.session.currentSession?.jwt
                )
                // A search result opened this chat: bring that message into view.
                if let focus = env.pendingMessageFocus, focus.matches(model.identity) {
                    env.pendingMessageFocus = nil
                    await jump(to: focus.messageID, proxy: proxy)
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
                ReactorsSheet(reactions: target.message.reactions, initial: target.reaction,
                              currentUserID: env.session.currentSession?.userId ?? "")
            }
            .sheet(isPresented: $sharingBeacon) {
                BeaconSharePicker { beacon in Task { await model.sendBeacon(beacon) } }
            }
            .onDisappear {
                if env.activeChatID == model.identity.chatID { env.activeChatID = nil }
                model.onDisappear()
            }
            .onChange(of: model.identity.chatID, initial: true) { _, chatID in
                env.activeChatID = chatID
            }
            .onChange(of: model.phase) { _, newPhase in
                guard newPhase == .loaded, !animatesInserts else { return }
                DispatchQueue.main.async {
                    // Open at the first unread message when there is one.
                    if model.firstUnreadID != nil {
                        proxy.scrollTo("unread-divider", anchor: .top)
                    } else {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { animatesInserts = true }
                }
            }
            // Only a new *latest* message moves the timeline. Loading older history prepends
            // and never changes the last ID, so the reader keeps their place.
            .onChange(of: model.items.last?.stableID) { oldID, newID in
                guard let newID, let oldID, newID != oldID else { return }
                if isNearBottom || model.items.last?.isOutgoing == true {
                    withAnimation(ClickMotion.content) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                    unseenCount = 0
                } else {
                    unseenCount += 1
                }
            }
            .onChange(of: isNearBottom) { _, nearBottom in
                if nearBottom { unseenCount = 0 }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom || model.isDetachedFromLatest, !model.items.isEmpty {
                    jumpToLatestButton(proxy: proxy)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(ClickMotion.selection, value: isNearBottom)
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
            .task(id: model.nextClickDropReveal?.date) {
                // Local, in-chat only: the server's `disposable_reveal` push covers the background.
                guard let next = model.nextClickDropReveal else { return }
                try? await Task.sleep(for: .seconds(max(0, next.date.timeIntervalSinceNow) + 0.5))
                guard !Task.isCancelled else { return }
                await showToast(next.isOutgoing ? "Your Click Drop developed" : "A Click Drop developed")
            }
            .onChange(of: model.isPeerTyping) { _, isTyping in
                guard isTyping, isNearBottom else { return }
                withAnimation(ClickMotion.selection) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
        }
    }

    private func timeline(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Reaching the top loads the previous page (spec §31.3).
                if model.hasMoreHistory, model.identity.hubID == nil, !model.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .opacity(model.isLoadingOlder ? 1 : 0.4)
                        .onAppear {
                            isTopSentinelVisible = true
                            requestOlderHistory(proxy: proxy)
                        }
                        .onDisappear { isTopSentinelVisible = false }
                }
                ForEach(Array(model.items.enumerated()), id: \.element.stableID) { index, item in
                    if shouldShowDateHeader(at: index) {
                        dateHeader(item.createdAt)
                    }
                    if item.id == model.firstUnreadID {
                        UnreadDivider().id("unread-divider")
                    }

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
                        onDelete: { target in
                            Task { await model.deleteMessage(item: target) }
                        },
                        onToggleReaction: { target, emoji in
                            Task { await model.toggleReaction(item: target, reactionType: emoji) }
                        },
                        onRetrySend: { target in
                            Task { await model.retrySend(item: target) }
                        },
                        showsSenderName: !model.identity.isDirect && startsSenderRun(at: index),
                        showsReceipts: model.identity.supportsReceipts,
                        mediaLoader: { message in try await model.mediaURL(for: message) },
                        onOpenMedia: { url, kind in
                            if kind == .image { viewerURL = ViewerURL(url: url) } else { quickLookURL = url }
                        },
                        onOpenBeacon: { beacon in
                            env.router.navigate(to: beacon.isEvent ? .event(beaconID: beacon.beaconID) : .beacon(beaconID: beacon.beaconID))
                        },
                        onDiscardFailed: { target in
                            withAnimation(ClickMotion.content) { model.discardFailed(item: target) }
                        },
                        onForward: conversations != nil && model.canForward(item) ? { forwarding = $0 } : nil,
                        onSaveMedia: { target in Task { await saveOrShare(target) } },
                        onShowReactions: { target, reaction in reactorsFor = ReactorsTarget(message: target, reaction: reaction) }
                    )
                    .background {
                        if highlightedID == item.stableID {
                            ClickColors.accentForeground.opacity(0.14).transition(.opacity)
                        }
                    }
                    .id(item.stableID)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .scale(scale: 0.92, anchor: item.isOutgoing ? .bottomTrailing : .bottomLeading)).combined(with: .opacity),
                        removal: .opacity
                    ))
                }

                if model.isPeerTyping {
                    typingIndicator
                        .id("typing-indicator")
                }

                Color.clear
                    .frame(height: 1)
                    .id("bottom-anchor")
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .scrollTargetLayout()
            .animation(animatesInserts ? ClickMotion.content : nil, value: model.items.last?.stableID)
        }
        .scrollPosition(id: $topVisibleID, anchor: .top)
        .dropDestination(for: Data.self) { payloads, _ in
            guard model.supportsMedia else { return false }
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
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 90
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
    }

    /// Debounced (300 ms) older-history request that restores the reader's anchor afterwards.
    private func requestOlderHistory(proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard isTopSentinelVisible, model.hasMoreHistory, !model.isLoadingOlder else { return }
            let anchor = topVisibleID ?? model.items.first?.stableID
            await model.loadOlder()
            guard let anchor else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            Task {
                // A search window that isn't joined to the latest page reloads it first.
                await model.returnToLatest()
                withAnimation(ClickMotion.content) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
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
            onDraft: model.supportsMedia ? { draft in
                // Click Drops go straight out from the camera; everything else is reviewed first.
                if draft.isClickDrop {
                    var drop = draft
                    drop.encounterID = env.clickDropSession?.encounterID(for: model.identity.connectionID)
                    Task { await model.sendMedia(drop) }
                } else {
                    model.stage(draft)
                }
            } : nil,
            onAttachmentError: { message in model.operationError = message },
            onShareBeacon: model.supportsMedia ? { sharingBeacon = true } : nil,
            staged: model.staged,
            onUnstage: { id in model.unstage(id) }
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
                EmptyView()
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

    private func searchBar(proxy: ScrollViewProxy) -> some View {
        let matches = searchMatches
        return ChatSearchBar(
            query: $searchQuery,
            matchCount: matches.count,
            position: searchPosition,
            canSearchOlder: model.hasMoreHistory && model.identity.hubID == nil,
            onPrevious: { Task { await stepSearch(older: true, proxy: proxy) } },
            onNext: { Task { await stepSearch(older: false, proxy: proxy) } },
            onDone: {
                withAnimation(ClickMotion.selection) { isSearching = false }
                searchQuery = ""
                searchPosition = nil
            }
        )
        .onChange(of: searchQuery) { searchPosition = nil }
    }

    /// Steps through matches newest → oldest; past the oldest, loads older history and retries.
    private func stepSearch(older: Bool, proxy: ScrollViewProxy) async {
        var matches = searchMatches
        let current = searchPosition ?? matches.count
        var next = older ? current - 1 : current + 1
        if older, next < 0 || matches.isEmpty, model.hasMoreHistory, model.identity.hubID == nil {
            let before = matches.count
            await model.loadOlder()
            matches = searchMatches
            next = matches.count - before - 1
        }
        guard matches.indices.contains(next) else { return }
        searchPosition = next
        await jump(to: matches[next], proxy: proxy)
    }

    /// Scrolls to a message (loading a window around it when needed) and flashes it.
    private func jump(to messageID: String, proxy: ScrollViewProxy) async {
        guard let stableID = await model.reveal(messageID: messageID) else {
            notice = "That message isn't available anymore."
            return
        }
        try? await Task.sleep(for: .milliseconds(50))
        withAnimation(ClickMotion.content) { proxy.scrollTo(stableID, anchor: .center) }
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

    private func startsSenderRun(at index: Int) -> Bool {
        guard model.items.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        let previous = model.items[index - 1]
        let current = model.items[index]
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
                break
            }
        } label: {
            HStack(spacing: 8) {
                AvatarView(
                    imageURL: model.identity.peerAvatarURL,
                    seed: model.identity.isDirect ? model.identity.peerUserID : model.identity.chatID,
                    initials: model.identity.initials,
                    size: ClickMetrics.Avatar.navigation
                )

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
        VStack(spacing: 10) {
            ProgressView()
                .tint(ClickColors.accentForeground)

            Text("Loading conversation…")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(ClickColors.textSecondary.opacity(0.85 - Double(index) * 0.2))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ClickColors.messageIncoming)
            .clipShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func shouldShowDateHeader(at index: Int) -> Bool {
        guard model.items.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            model.items[index - 1].createdAt,
            inSameDayAs: model.items[index].createdAt
        )
    }

    private func dateHeader(_ date: Date) -> some View {
        Text(dateLabel(date))
            .font(ClickTypography.caption)
            .foregroundStyle(ClickColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ClickColors.surface)
            .clipShape(Capsule())
            .padding(.vertical, 8)
    }

    private func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
