import SwiftUI

/// High-fidelity chat bubble rendering outgoing and incoming messages, reply references, status ticks, and reactions.
public struct MessageBubbleView: View {
    let message: ChatMessageItem
    let onReply: (ChatMessageItem) -> Void
    let onEdit: (ChatMessageItem) -> Void
    let onDelete: (ChatMessageItem) -> Void
    let onToggleReaction: (ChatMessageItem, String) -> Void
    let onRetrySend: ((ChatMessageItem) -> Void)?

    @State private var dragOffset: CGFloat = 0
    @State private var hasTriggeredReplyHaptic = false

    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    public init(
        message: ChatMessageItem,
        onReply: @escaping (ChatMessageItem) -> Void,
        onEdit: @escaping (ChatMessageItem) -> Void,
        onDelete: @escaping (ChatMessageItem) -> Void,
        onToggleReaction: @escaping (ChatMessageItem, String) -> Void,
        onRetrySend: ((ChatMessageItem) -> Void)? = nil
    ) {
        self.message = message
        self.onReply = onReply
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onToggleReaction = onToggleReaction
        self.onRetrySend = onRetrySend
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: ClickSpacing.xs) {
            if message.isOutgoing {
                Spacer(minLength: 48)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: ClickSpacing.xxs) {
                // Reply quote header inside bubble if present
                bubbleContainer
                    .offset(x: dragOffset)
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { value in
                                // Only swipe towards center
                                if message.isOutgoing {
                                    if value.translation.width < 0 {
                                        dragOffset = max(value.translation.width * 0.4, -60)
                                    }
                                } else {
                                    if value.translation.width > 0 {
                                        dragOffset = min(value.translation.width * 0.4, 60)
                                    }
                                }

                                if abs(dragOffset) >= 40 && !hasTriggeredReplyHaptic {
                                    ClickHaptics.selection()
                                    hasTriggeredReplyHaptic = true
                                }
                            }
                            .onEnded { _ in
                                if abs(dragOffset) >= 40 {
                                    onReply(message)
                                }
                                withAnimation(ClickMotion.selection) {
                                    dragOffset = 0
                                    hasTriggeredReplyHaptic = false
                                }
                            }
                    )
                    .contextMenu {
                        // Emoji reaction strip
                        Section {
                            ForEach(quickEmojis, id: \.self) { emoji in
                                Button {
                                    ClickHaptics.selection()
                                    onToggleReaction(message, emoji)
                                } label: {
                                    Text(emoji)
                                }
                            }
                        }

                        Button {
                            onReply(message)
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }

                        Button {
                            UIPasteboard.general.string = message.content
                            ClickHaptics.success()
                        } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }

                        if message.isOutgoing {
                            Button {
                                onEdit(message)
                            } label: {
                                Label("Edit Message", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                onDelete(message)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                // Reactions strip under bubble
                if !message.reactions.isEmpty {
                    HStack(spacing: ClickSpacing.xxs) {
                        ForEach(message.reactions) { reaction in
                            Button {
                                ClickHaptics.selection()
                                onToggleReaction(message, reaction.reactionType)
                            } label: {
                                HStack(spacing: 2) {
                                    Text(reaction.reactionType)
                                        .font(.system(size: 12))
                                    if reaction.count > 1 {
                                        Text("\(reaction.count)")
                                            .font(ClickTypography.labelSmall)
                                            .foregroundStyle(reaction.userReacted ? ClickColors.primary : ClickColors.textSecondary)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    reaction.userReacted
                                        ? ClickColors.primaryFixed.opacity(0.3)
                                        : ClickColors.surfaceContainerHigh
                                )
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(
                                        reaction.userReacted ? ClickColors.primary : Color.clear,
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, ClickSpacing.xs)
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 48)
            }
        }
        .padding(.horizontal, ClickSpacing.md)
        .padding(.vertical, ClickSpacing.xxs)
    }

    private var bubbleContainer: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: ClickSpacing.xxs) {
            // Reply context preview
            if let snippet = message.replyToSnippet, !snippet.isEmpty {
                HStack(spacing: ClickSpacing.xs) {
                    Rectangle()
                        .fill(message.isOutgoing ? ClickColors.onPrimary.opacity(0.6) : ClickColors.primary)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.replyToSenderName ?? "Reply")
                            .font(ClickTypography.labelSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(message.isOutgoing ? ClickColors.onPrimary.opacity(0.8) : ClickColors.primary)

                        Text(snippet)
                            .font(ClickTypography.bodySmall)
                            .lineLimit(1)
                            .foregroundStyle(message.isOutgoing ? ClickColors.onPrimary.opacity(0.7) : ClickColors.textSecondary)
                    }
                }
                .padding(.horizontal, ClickSpacing.xs)
                .padding(.top, ClickSpacing.xs)
            }

            // Message content
            Text(message.content)
                .font(ClickTypography.bodyMedium)
                .foregroundStyle(message.isOutgoing ? ClickColors.onPrimary : ClickColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ClickSpacing.sm)
                .padding(.top, (message.replyToSnippet != nil) ? 2 : ClickSpacing.sm)
                .padding(.bottom, 2)

            // Metadata row: Time + Status ticks
            HStack(spacing: ClickSpacing.xxs) {
                if message.isEdited {
                    Text("edited")
                        .font(ClickTypography.labelSmall)
                        .foregroundStyle(message.isOutgoing ? ClickColors.onPrimary.opacity(0.6) : ClickColors.textSecondary)
                }

                Text(message.formattedTime)
                    .font(ClickTypography.labelSmall)
                    .foregroundStyle(message.isOutgoing ? ClickColors.onPrimary.opacity(0.7) : ClickColors.textSecondary)

                if message.isOutgoing {
                    statusIcon
                }
            }
            .padding(.horizontal, ClickSpacing.sm)
            .padding(.bottom, ClickSpacing.xs)
        }
        .background(
            message.isOutgoing ? ClickColors.primary : ClickColors.surfaceContainerHigh
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: ClickSpacing.radiusCard,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.deliveryStatus {
        case .pending, .sending:
            ProgressView()
                .scaleEffect(0.6)
                .tint(ClickColors.onPrimary.opacity(0.7))
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ClickColors.onPrimary.opacity(0.7))
        case .delivered:
            HStack(spacing: -5) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ClickColors.onPrimary.opacity(0.8))
        case .read:
            HStack(spacing: -5) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(hex: "#60A5FA")) // distinct delivered/read blue
        case .failed:
            Button {
                onRetrySend?(message)
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ClickColors.error)
            }
        }
    }
}
