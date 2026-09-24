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
    /// Group and hub timelines label incoming runs with the sender's name.
    let showsSenderName: Bool
    /// Hubs have no delivery/read receipts; only pending/failed state is shown.
    let showsReceipts: Bool
    /// Decrypted-media provider and opener; nil renders media as an unavailable label.
    let mediaLoader: ((ChatMessageItem) async throws -> URL)?
    let onOpenMedia: ((URL, MessageMedia.Kind) -> Void)?
    let onOpenBeacon: ((SharedBeacon) -> Void)?

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
        onRetrySend: ((ChatMessageItem) -> Void)? = nil,
        showsSenderName: Bool = false,
        showsReceipts: Bool = true,
        mediaLoader: ((ChatMessageItem) async throws -> URL)? = nil,
        onOpenMedia: ((URL, MessageMedia.Kind) -> Void)? = nil,
        onOpenBeacon: ((SharedBeacon) -> Void)? = nil
    ) {
        self.onOpenBeacon = onOpenBeacon
        self.mediaLoader = mediaLoader
        self.onOpenMedia = onOpenMedia
        self.showsSenderName = showsSenderName
        self.showsReceipts = showsReceipts
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
                if showsSenderName, !message.isOutgoing {
                    Text(message.senderName)
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(1)
                        .padding(.leading, 12)
                        .padding(.top, 6)
                }
                content
                    .frame(maxWidth: 320, alignment: message.isOutgoing ? .trailing : .leading)
                    .offset(x: dragOffset)
                    // A voice note's seek slider must win over swipe-to-reply (spec §37.6).
                    .simultaneousGesture(replyGesture, including: message.media?.kind == .audio ? .subviews : .all)
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

                        if !message.isMedia {
                            Button {
                                UIPasteboard.general.string = message.content
                                ClickHaptics.success()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }

                        if message.isOutgoing {
                            if !message.isMedia {
                                Button {
                                    onEdit(message)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
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

    @ViewBuilder
    private var content: some View {
        if let beacon = message.beacon {
            BeaconMessageCard(beacon: beacon, time: message.formattedTime, isOutgoing: message.isOutgoing) {
                onOpenBeacon?(beacon)
            }
        } else if let media = message.media, let mediaLoader {
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if let snippet = message.replyToSnippet, !snippet.isEmpty {
                    replyQuote(snippet: snippet)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            message.isOutgoing ? ClickColors.messageOutgoing : ClickColors.messageIncoming,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .frame(maxWidth: 240)
                }
                MessageMediaContent(
                    message: message,
                    media: media,
                    load: { try await mediaLoader(message) },
                    onOpen: { url in onOpenMedia?(url, media.kind) }
                )
                HStack(spacing: 4) {
                    Text(message.formattedTime).monospacedDigit()
                    if message.isOutgoing, showsReceipts || [.pending, .sending, .failed].contains(message.deliveryStatus) {
                        statusIcon
                    }
                }
                .font(ClickTypography.caption)
                .foregroundStyle(ClickColors.textSecondary)
            }
        } else {
            bubbleContainer
        }
    }

    private var bubbleContainer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let snippet = message.replyToSnippet, !snippet.isEmpty {
                replyQuote(snippet: snippet)
            }

            // The bubble hugs its text: the timestamp sits in space reserved at the end of the
            // last line (an invisible copy), so short messages get short bubbles.
            (Text(message.content)
                + Text(verbatim: "\u{2003}" + timePlaceholder).font(ClickTypography.caption).foregroundColor(.clear))
                .font(ClickTypography.body)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
                .overlay(alignment: .bottomTrailing) {
                    metaRow.offset(y: 3)
                }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: ClickRadius.messageBubble,
                bottomLeadingRadius: message.isOutgoing ? ClickRadius.messageBubble : 6,
                bottomTrailingRadius: message.isOutgoing ? 6 : ClickRadius.messageBubble,
                topTrailingRadius: ClickRadius.messageBubble,
                style: .continuous
            )
            .fill(message.isOutgoing ? ClickColors.messageOutgoing : ClickColors.messageIncoming)
        }
        .contentShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
    }

    private var foreground: Color {
        message.isOutgoing ? ClickColors.messageOutgoingForeground : ClickColors.messageIncomingForeground
    }

    private var showsStatus: Bool {
        message.isOutgoing && (showsReceipts || [.pending, .sending, .failed].contains(message.deliveryStatus))
    }

    /// Same characters as the visible meta row, used only to reserve its width.
    private var timePlaceholder: String {
        (message.isEdited ? "edited " : "") + message.formattedTime + (showsStatus ? " ✓✓" : "")
    }

    private var metaRow: some View {
        HStack(spacing: 3) {
            if message.isEdited { Text("edited") }
            Text(message.formattedTime).monospacedDigit()
            if showsStatus { statusIcon }
        }
        .font(ClickTypography.caption)
        .foregroundStyle(message.isOutgoing ? ClickColors.messageOutgoingForeground.opacity(0.72) : ClickColors.textSecondary)
    }

    private func replyQuote(snippet: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(message.isOutgoing ? ClickColors.messageOutgoingForeground.opacity(0.85) : ClickColors.accentForeground)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.replyToSenderName ?? "Reply")
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(message.isOutgoing ? ClickColors.messageOutgoingForeground : ClickColors.accentForeground)
                Text(snippet)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(message.isOutgoing ? ClickColors.messageOutgoingForeground.opacity(0.78) : ClickColors.textSecondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            (message.isOutgoing ? Color.white.opacity(0.14) : ClickColors.fillSubtle),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))

        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))

        case .delivered:
            doubleCheck

        case .read:
            doubleCheck.foregroundStyle(Color(hex: "#7DD3FC"))

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

    private var doubleCheck: some View {
        HStack(spacing: -5) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
        }
        .font(.system(size: 10, weight: .bold))
    }
}

/// A shared event/beacon as a card (prototype "Sunset Run Club"), not as "Beacon: …" text.
private struct BeaconMessageCard: View {
    let beacon: SharedBeacon
    let time: String
    let isOutgoing: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                EventVisual(seed: beacon.beaconID, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: 14)
                    .frame(height: 120)
                    .padding(6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(beacon.title)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(2)
                    }
                    HStack {
                        Text(beacon.isEvent ? "View event" : "View \(beacon.kind.label.lowercased())")
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.accentForeground)
                        Spacer()
                        Text(time)
                            .font(ClickTypography.caption)
                            .foregroundStyle(ClickColors.textSecondary)
                            .monospacedDigit()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 4)
            }
            .frame(width: 260)
            .background(ClickColors.messageIncoming, in: RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(beacon.title). \(detail ?? ""). Opens details.")
    }

    private var detail: String? {
        let parts = [beacon.scheduleLabel ?? beacon.start.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) },
                     beacon.locationName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
