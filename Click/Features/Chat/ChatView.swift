import SwiftUI

/// Primary direct chat timeline and interaction view.
/// Conforms to §31-§35 of CLICK_NATIVE_IOS_REBUILD_SPEC.
public struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConversationModel

    public init(model: ConversationModel) {
        self._model = State(initialValue: model)
    }

    public init(
        chatID: String,
        connectionID: String? = nil,
        peerUserID: String,
        peerDisplayName: String,
        peerHandle: String = "",
        peerAvatarURL: String? = nil,
        isOnline: Bool = false
    ) {
        let identity = ConversationIdentity(
            chatID: chatID,
            connectionID: connectionID,
            peerUserID: peerUserID,
            peerDisplayName: peerDisplayName,
            peerHandle: peerHandle,
            peerAvatarURL: peerAvatarURL,
            isOnline: isOnline
        )
        // Temporary placeholder model until onAppear resolves environment
        let dummy = ConversationModel(
            identity: identity,
            chatRepository: DummyChatRepository(),
            currentUserID: "",
            currentUserName: "You"
        )
        self._model = State(initialValue: dummy)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Custom Navigation Header
            navigationHeader

            Divider()
                .background(ClickColors.outline.opacity(0.15))

            // Timeline area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ClickSpacing.xs) {
                        // Date separator
                        dateHeader("Today")

                        // Message bubbles
                        ForEach(model.items) { item in
                            MessageBubbleView(
                                message: item,
                                onReply: { target in
                                    withAnimation(ClickMotion.subtleFade) {
                                        model.editTarget = nil
                                        model.replyTarget = target
                                    }
                                },
                                onEdit: { target in
                                    withAnimation(ClickMotion.subtleFade) {
                                        model.replyTarget = nil
                                        model.editTarget = target
                                        model.composerText = target.content
                                    }
                                },
                                onDelete: { target in
                                    Task { await model.deleteMessage(item: target) }
                                },
                                onToggleReaction: { target, emoji in
                                    model.toggleReaction(item: target, reactionType: emoji)
                                },
                                onRetrySend: { target in
                                    Task { await model.retrySend(item: target) }
                                }
                            )
                            .id(item.id)
                        }

                        // Peer typing indicator
                        if model.isPeerTyping {
                            typingIndicatorBubble
                                .id("typing-indicator")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                    }
                    .padding(.top, ClickSpacing.sm)
                    .padding(.bottom, ClickSpacing.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.items.count) { _, _ in
                    withAnimation(ClickMotion.selection) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }

            // Composer bar
            ChatComposerView(
                text: $model.composerText,
                replyTarget: model.replyTarget,
                editTarget: model.editTarget,
                isSending: model.isSending,
                onCancelReply: {
                    withAnimation(ClickMotion.subtleFade) {
                        model.replyTarget = nil
                    }
                },
                onCancelEdit: {
                    withAnimation(ClickMotion.subtleFade) {
                        model.editTarget = nil
                        model.composerText = ""
                    }
                },
                onSend: {
                    Task {
                        await model.sendOrUpdateMessage()
                    }
                },
                onTypingChanged: { isTyping in
                    model.setTyping(isTyping: isTyping)
                }
            )
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .task {
            // If initialized with dummy repo, bind real environment repo
            if model.items.isEmpty, let currentUserID = env.session.currentSession?.userId {
                let identity = model.identity
                let realModel = ConversationModel(
                    identity: identity,
                    chatRepository: env.chat,
                    currentUserID: currentUserID,
                    currentUserName: "You"
                )
                self.model = realModel
                let supabaseURL = AppConfig.shared.supabaseURL
                let anonKey = AppConfig.shared.supabaseAnonKey
                let jwt = env.session.currentSession?.jwt
                await realModel.onAppear(supabaseURL: supabaseURL, anonKey: anonKey, authToken: jwt)
            }
        }
        .onDisappear {
            model.onDisappear()
        }
    }

    // MARK: - Subviews

    private var navigationHeader: some View {
        HStack(spacing: ClickSpacing.sm) {
            Button {
                ClickHaptics.selection()
                dismiss()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Clicks")
                        .font(ClickTypography.bodyMedium)
                }
                .foregroundStyle(ClickColors.primary)
            }

            Spacer()

            // Peer Identity info
            VStack(spacing: 2) {
                HStack(spacing: ClickSpacing.xxs) {
                    Text(model.identity.peerDisplayName)
                        .font(ClickTypography.titleSmall)
                        .fontWeight(.bold)
                        .foregroundStyle(ClickColors.textPrimary)

                    if model.identity.isOnline {
                        Circle()
                            .fill(Color(hex: "#10B981"))
                            .frame(width: 8, height: 8)
                    }
                }

                Text(model.identity.isOnline ? "Active now" : (model.identity.peerHandle.isEmpty ? "Direct Chat" : model.identity.peerHandle))
                    .font(ClickTypography.labelSmall)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            Spacer()

            // Peer Avatar
            ZStack {
                Circle()
                    .fill(ClickColors.primaryFixed.opacity(0.4))
                    .frame(width: 36, height: 36)
                Text(model.identity.initials)
                    .font(ClickTypography.labelSmall)
                    .fontWeight(.bold)
                    .foregroundStyle(ClickColors.primary)
            }
        }
        .padding(.horizontal, ClickSpacing.md)
        .padding(.vertical, ClickSpacing.xs)
        .background(ClickColors.background)
    }

    private func dateHeader(_ text: String) -> some View {
        Text(text)
            .font(ClickTypography.labelSmall)
            .fontWeight(.semibold)
            .foregroundStyle(ClickColors.textSecondary)
            .padding(.horizontal, ClickSpacing.sm)
            .padding(.vertical, 4)
            .background(ClickColors.surfaceContainerLow)
            .clipShape(Capsule())
            .padding(.vertical, ClickSpacing.xs)
    }

    private var typingIndicatorBubble: some View {
        HStack {
            HStack(spacing: 4) {
                Circle().fill(ClickColors.textSecondary).frame(width: 6, height: 6)
                Circle().fill(ClickColors.textSecondary.opacity(0.7)).frame(width: 6, height: 6)
                Circle().fill(ClickColors.textSecondary.opacity(0.4)).frame(width: 6, height: 6)
            }
            .padding(.horizontal, ClickSpacing.md)
            .padding(.vertical, 10)
            .background(ClickColors.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))

            Spacer()
        }
        .padding(.horizontal, ClickSpacing.md)
    }
}

private struct DummyChatRepository: ChatRepositoryProtocol {
    func fetchMessages(chatID: String, connectionID: String?, peerUserID: String, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] { [] }
    func sendMessage(chatID: String, connectionID: String?, peerUserID: String, currentUserID: String, currentUserName: String, content: String, replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String) async throws -> ChatMessageItem {
        ChatMessageItem(id: clientMessageID, chatID: chatID, senderID: currentUserID, senderName: currentUserName, content: content, isOutgoing: true)
    }
    func editMessage(messageID: String, newContent: String) async throws {}
    func deleteMessage(messageID: String) async throws {}
    func markRead(chatID: String, messageIDs: [String]) async throws {}
    func markDelivered(chatID: String, messageIDs: [String]) async throws {}
    func registerDevice() async throws {}
}
