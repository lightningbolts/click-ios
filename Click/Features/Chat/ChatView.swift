import SwiftUI

/// Native direct-chat destination.
///
/// Navigation chrome, interactive back progress, keyboard, and tab-bar visibility are owned by
/// SwiftUI rather than a second custom navigation hierarchy.
public struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ConversationModel
    @State private var isNearBottom = true

    public init(model: ConversationModel) {
        self._model = State(initialValue: model)
    }

    public var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch model.phase {
                case .initial, .loading where model.items.isEmpty:
                    loadingState

                case .failed(let message) where model.items.isEmpty:
                    failureState(message: message)

                default:
                    timeline(proxy: proxy)
                }
            }
            .background(ClickColors.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposerView(
                    text: $model.composerText,
                    placeholder: "Message \(model.identity.peerDisplayName)…",
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
                    }
                )
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
                ToolbarItem(placement: .principal) {
                    conversationTitle
                }
            }
            .toolbarBackground(ClickColors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                await model.onAppear(
                    supabaseURL: AppConfig.shared.supabaseURL,
                    anonKey: AppConfig.shared.supabaseAnonKey,
                    authToken: env.session.currentSession?.jwt
                )
            }
            .onDisappear {
                model.onDisappear()
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
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 90
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
    }

    private var conversationTitle: some View {
        Button {
            guard !model.identity.peerUserID.isEmpty else { return }
            ClickHaptics.selection()
            env.router.connectionsPath.append(
                .userProfile(
                    userID: model.identity.peerUserID,
                    connectionID: model.identity.connectionID
                )
            )
        } label: {
            HStack(spacing: 8) {
                peerAvatar(size: 32)

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.identity.peerDisplayName)
                        .font(ClickTypography.titleSmall)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)

                    Text(statusText)
                        .font(ClickTypography.microcopy)
                        .foregroundStyle(
                            model.isPeerTyping
                                ? ClickColors.primary
                                : ClickColors.textSecondary
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
            return "typing…"
        }
        if model.identity.isOnline {
            return "Active now"
        }
        if !model.identity.lastActiveText.isEmpty {
            return model.identity.lastActiveText
        }
        if !model.identity.peerHandle.isEmpty {
            return model.identity.peerHandle
        }
        return "Click"
    }

    @ViewBuilder
    private func peerAvatar(size: CGFloat) -> some View {
        if let raw = model.identity.peerAvatarURL,
           let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                avatarFallback(size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            avatarFallback(size: size)
        }
    }

    private func avatarFallback(size: CGFloat) -> some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.55))
            .frame(width: size, height: size)
            .overlay {
                Text(model.identity.initials)
                    .font(ClickTypography.microcopy)
                    .foregroundStyle(ClickColors.primary)
            }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(ClickColors.primary)

            Text("Loading conversation…")
                .font(ClickTypography.bodySmall)
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
            .tint(ClickColors.primary)
        }
    }

    private func operationBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))

            Text(message)
                .font(ClickTypography.captionSmall)
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
        .background(ClickColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ClickColors.quietBorder, lineWidth: 1)
        }
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
            .background(ClickColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ClickColors.quietBorder.opacity(0.78), lineWidth: 1)
            }

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
            .font(ClickTypography.microcopy)
            .foregroundStyle(ClickColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ClickColors.surfaceContainerLow)
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
