import SwiftUI
import UIKit

/// Compact native message bubble with optimistic status, reply, reactions, and direction-locked
/// swipe-to-reply. Visuals follow Click Functional Clarity rather than generic Material cards.
public struct MessageBubbleView: View {
    let message: ChatMessageItem
    let onReply: (ChatMessageItem) -> Void
    let onEdit: (ChatMessageItem) -> Void
    let onDelete: (ChatMessageItem) -> Void
    let onToggleReaction: (ChatMessageItem, String) -> Void
    let onRetrySend: ((ChatMessageItem) -> Void)?

    @State private var dragOffset: CGFloat = 0
    @State private var dragIntent: DragIntent = .undecided
    @State private var hasTriggeredReplyHaptic = false

    private enum DragIntent {
        case undecided
        case horizontal
        case vertical
    }

    private let replyThreshold: CGFloat = 60
    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "😡"]

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
        HStack(alignment: .bottom, spacing: 0) {
            if message.isOutgoing {
                Spacer(minLength: 58)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                bubbleContainer
                    .frame(maxWidth: 320, alignment: message.isOutgoing ? .trailing : .leading)
                    .offset(x: dragOffset)
                    .simultaneousGesture(replyGesture)
                    .contextMenu {
                        Section {
                            ForEach(quickEmojis, id: \.self) { emoji in
                                Button {
                                    ClickHaptics.impact(.light)
                                    onToggleReaction(message, emoji)
                                } label: {
                                    Text(emoji)
                                }
                            }
                        }

                        Button {
                            ClickHaptics.impact(.medium)
                            onReply(message)
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }

                        Button {
                            UIPasteboard.general.string = message.content
                            ClickHaptics.success()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        if message.isOutgoing {
                            Button {
                                onEdit(message)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                onDelete(message)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                if !message.reactions.isEmpty {
                    reactionsStrip
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 58)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1.5)
    }

    private var bubbleContainer: some View {
        VStack(
            alignment: message.isOutgoing ? .trailing : .leading,
            spacing: 4
        ) {
            if let snippet = message.replyToSnippet, !snippet.isEmpty {
                replyQuote(snippet: snippet)
            }

            Text(message.content)
                .font(ClickTypography.body)
                .foregroundStyle(
                    message.isOutgoing
                        ? ClickColors.messageOutgoingForeground
                        : ClickColors.messageIncomingForeground
                )
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if message.isEdited {
                    Text("edited")
                }

                Text(message.formattedTime)
                    .monospacedDigit()

                if message.isOutgoing {
                    statusIcon
                }
            }
            .font(ClickTypography.caption)
            .foregroundStyle(
                message.isOutgoing
                    ? ClickColors.messageOutgoingForeground.opacity(0.72)
                    : ClickColors.textSecondary
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.top, message.replyToSnippet == nil ? 8 : 7)
        .padding(.bottom, 7)
        .background {
            RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
                .fill(
                    message.isOutgoing
                        ? ClickColors.messageOutgoing
                        : ClickColors.messageIncoming
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
    }

    private func replyQuote(snippet: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    message.isOutgoing
                        ? ClickColors.messageOutgoingForeground.opacity(0.75)
                        : ClickColors.accentForeground
                )
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(message.replyToSenderName ?? "Reply")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(
                        message.isOutgoing
                            ? ClickColors.messageOutgoingForeground.opacity(0.9)
                            : ClickColors.accentForeground
                    )

                Text(snippet)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(
                        message.isOutgoing
                            ? ClickColors.messageOutgoingForeground.opacity(0.74)
                            : ClickColors.textSecondary
                    )
                    .lineLimit(2)
            }
        }
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reactionsStrip: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Button {
                    ClickHaptics.impact(.light)
                    onToggleReaction(message, reaction.reactionType)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.reactionType)
                            .font(.system(size: 13))

                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(ClickTypography.caption)
                                .foregroundStyle(ClickColors.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        reaction.userReacted
                            ? ClickColors.selectionTint
                            : ClickColors.messageIncoming
                    )
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(
                                reaction.userReacted
                                    ? ClickColors.accentForeground.opacity(0.45)
                                    : ClickColors.separator,
                                lineWidth: ClickMetrics.strokeWidth
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
    }

    private var replyGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                if dragIntent == .undecided {
                    if abs(dx) > abs(dy) * 1.2 {
                        dragIntent = .horizontal
                    } else if abs(dy) > abs(dx) {
                        dragIntent = .vertical
                    }
                }

                guard dragIntent == .horizontal else { return }

                let allowed = message.isOutgoing ? min(dx, 0) : max(dx, 0)
                dragOffset = max(-72, min(72, allowed * 0.56))

                if abs(dragOffset) >= replyThreshold,
                   !hasTriggeredReplyHaptic {
                    ClickHaptics.impact(.heavy)
                    hasTriggeredReplyHaptic = true
                }
            }
            .onEnded { _ in
                if dragIntent == .horizontal,
                   abs(dragOffset) >= replyThreshold {
                    onReply(message)
                }

                withAnimation(ClickMotion.selection) {
                    dragOffset = 0
                }
                dragIntent = .undecided
                hasTriggeredReplyHaptic = false
            }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.deliveryStatus {
        case .pending, .sending:
            ProgressView()
                .controlSize(.mini)
                .tint(ClickColors.messageOutgoingForeground.opacity(0.8))

        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))

        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10, weight: .semibold))

        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hex: "#7DD3FC"))

        case .failed:
            Button {
                ClickHaptics.warning()
                onRetrySend?(message)
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ClickColors.messageOutgoingForeground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message failed. Tap to retry.")
        }
    }
}
