import SwiftUI

/// Native conversation destination for direct chats, verified groups, and hubs.
///
/// Navigation chrome, interactive back progress, keyboard, and tab-bar visibility are owned by
/// SwiftUI rather than a second custom navigation hierarchy.
public struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ConversationModel
    @State private var isNearBottom = true
    @State private var screenWidth: CGFloat = 390
    @State private var viewerURL: ViewerURL?
    @State private var safetyAction: SafetyAction?
    @State private var notice: String?

    private enum SafetyAction: Identifiable {
        case report, block
        var id: Self { self }
    }
    @State private var quickLookURL: URL?
    @State private var sharingBeacon = false

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
                if let error = model.operationError, !model.items.isEmpty {
                    operationBanner(error)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                if model.identity.hubID == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        conversationMenu
                    }
                }
            }
            .task {
                await model.onAppear(
                    supabaseURL: AppConfig.shared.supabaseURL,
                    anonKey: AppConfig.shared.supabaseAnonKey,
                    authToken: env.session.currentSession?.jwt
                )
            }
            .fullScreenCover(item: $viewerURL) { item in
                MediaViewer(url: item.url)
            }
            .quickLookPreview($quickLookURL)
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
                guard newPhase == .loaded else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: model.items.count) { oldCount, newCount in
                guard newCount > oldCount else { return }
                guard isNearBottom || model.items.last?.isOutgoing == true else { return }
                withAnimation(ClickMotion.selection) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
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
                        .onAppear { Task { await model.loadOlder() } }
                }
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    if shouldShowDateHeader(at: index) {
                        dateHeader(item.createdAt)
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
                        }
                    )
                    .id(item.id)
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
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 90
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
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
                    await model.sendOrUpdateMessage()
                }
            },
            onTypingChanged: { hasText in
                model.noteTypingActivity(hasText: hasText)
            },
            onDraft: model.supportsMedia ? { draft in Task { await model.sendMedia(draft) } } : nil,
            onAttachmentError: { message in model.operationError = message },
            onShareBeacon: model.supportsMedia ? { sharingBeacon = true } : nil
        )
        // Dialogs hang off the composer so the main body stays type-checkable.
        .confirmationDialog(
            safetyAction == .block ? "Block \(model.identity.peerDisplayName)?" : "Report this conversation?",
            isPresented: Binding(get: { safetyAction != nil }, set: { if !$0 { safetyAction = nil } }),
            titleVisibility: .visible
        ) {
            if safetyAction == .block {
                Button("Block", role: .destructive) { Task { await block() } }
            } else {
                Button("Report", role: .destructive) { Task { await report() } }
            }
        } message: {
            Text(safetyAction == .block
                 ? "They won't be able to message you or see you on Click."
                 : "Click's safety team will review this conversation.")
        }
        .alert("Chat", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private var conversationMenu: some View {
        Menu {
            switch model.identity.kind {
            case .direct:
                Button("View profile", systemImage: "person.crop.circle") {
                    env.router.navigate(to: .userProfile(userID: model.identity.peerUserID, connectionID: model.identity.connectionID))
                }
                if model.identity.connectionID != nil {
                    Section {
                        Button("Report", systemImage: "exclamationmark.bubble") { safetyAction = .report }
                        Button("Block", systemImage: "hand.raised", role: .destructive) { safetyAction = .block }
                    }
                }
            case .group:
                Button("Group info", systemImage: "info.circle") {
                    env.router.navigate(to: .groupProfile(chatID: model.identity.chatID))
                }
            case .hub:
                EmptyView()
            }
        } label: {
            Label("Conversation options", systemImage: "ellipsis")
        }
    }

    private func report() async {
        guard let connectionID = model.identity.connectionID else { return }
        do {
            try await env.profiles.report(connectionID: connectionID, reason: "Reported from chat")
            notice = "Thanks. Click's safety team will review it."
        } catch {
            notice = "Couldn't send the report. \(error.userFacingMessage)"
        }
    }

    private func block() async {
        do {
            try await env.profiles.block(userID: model.identity.peerUserID)
            env.router.resetCurrentTabPath()
        } catch {
            notice = "Couldn't block. \(error.userFacingMessage)"
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
            return model.identity.isDirect ? "typing…" : "Someone is typing…"
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
