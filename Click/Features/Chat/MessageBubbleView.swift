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
    /// Decrypted-media provider and opener; cannot be nil.
    let mediaLoader: (ChatMessageItem) async throws -> URL
    let onOpenMedia: ((URL, MessageMedia.Kind) -> Void)?
    let onOpenBeacon: ((SharedBeacon) -> Void)?
    /// Removes a failed outgoing row (✕ on a failed attachment).
    var onDiscardFailed: ((ChatMessageItem) -> Void)?
    /// Forward, save/share and "who reacted"; nil hides the matching menu item.
    var onForward: ((ChatMessageItem) -> Void)?
    var onSaveMedia: ((ChatMessageItem) -> Void)?
    var onShowReactions: ((ChatMessageItem, String) -> Void)?
    /// Renders only the bubble itself (no row spacing, name, reactions or gestures): the copy
    /// lifted by the message action overlay, which must match the on-screen bubble exactly.
    var isLiftedCopy = false
    /// Hides the bubble (keeping its space) while the action overlay shows its lifted copy.
    var isBubbleHidden = false
    /// The message this one replies to (for its thumbnail) and a tap on the quote.
    var replyTarget: ChatMessageItem?
    var onTapReplyQuote: ((String) -> Void)?
    var onLongPress: ((ChatMessageItem, CGRect) -> Void)?

    @State private var dragOffset: CGFloat = 0
    @State private var hasTriggeredReplyHaptic = false
    @State private var bubbleFrame: CGRect = .zero

    public init(
        message: ChatMessageItem,
        onReply: @escaping (ChatMessageItem) -> Void = { _ in },
        onEdit: @escaping (ChatMessageItem) -> Void = { _ in },
        onDelete: @escaping (ChatMessageItem) -> Void = { _ in },
        onToggleReaction: @escaping (ChatMessageItem, String) -> Void = { _, _ in },
        onRetrySend: ((ChatMessageItem) -> Void)? = nil,
        showsSenderName: Bool = false,
        showsReceipts: Bool = true,
        mediaLoader: @escaping (ChatMessageItem) async throws -> URL,
        onOpenMedia: ((URL, MessageMedia.Kind) -> Void)? = nil,
        onOpenBeacon: ((SharedBeacon) -> Void)? = nil,
        onDiscardFailed: ((ChatMessageItem) -> Void)? = nil,
        onForward: ((ChatMessageItem) -> Void)? = nil,
        onSaveMedia: ((ChatMessageItem) -> Void)? = nil,
        onShowReactions: ((ChatMessageItem, String) -> Void)? = nil,
        replyTarget: ChatMessageItem? = nil,
        onTapReplyQuote: ((String) -> Void)? = nil,
        isLiftedCopy: Bool = false,
        onLongPress: ((ChatMessageItem, CGRect) -> Void)? = nil,
        isBubbleHidden: Bool = false
    ) {
        self.isBubbleHidden = isBubbleHidden
        self.onLongPress = onLongPress
        self.isLiftedCopy = isLiftedCopy
        self.replyTarget = replyTarget
        self.onTapReplyQuote = onTapReplyQuote
        self.onForward = onForward
        self.onSaveMedia = onSaveMedia
        self.onShowReactions = onShowReactions
        self.onDiscardFailed = onDiscardFailed
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
        if isLiftedCopy {
            content
                .frame(maxWidth: 320, alignment: message.isOutgoing ? .trailing : .leading)
        } else if message.isDeleted {
            deletedPlaceholder
        } else {
            liveBubble
        }
    }

    private var deletedPlaceholder: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 58) }
            Label("Message deleted", systemImage: "nosign")
                .font(ClickTypography.supporting.italic())
                .foregroundStyle(ClickColors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
                        .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                )
            if !message.isOutgoing { Spacer(minLength: 58) }
        }
        .padding(.horizontal, 5)
        .accessibilityLabel(message.isOutgoing ? "You deleted a message" : "\(message.senderName) deleted a message")
    }

    private var liveBubble: some View {
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
                    .opacity(isBubbleHidden ? 0 : 1)
                    .overlay(alignment: message.isOutgoing ? .trailing : .leading) { replyHint }
                    // A voice note's seek slider must win over swipe-to-reply (spec §37.6).
                    .gesture(HorizontalSwipeGesture(
                        isEnabled: message.media?.kind != .audio && message.deliveryStatus != .sending,
                        direction: message.isOutgoing ? -1 : 1,
                        onChanged: swipeChanged,
                        onEnded: swipeEnded
                    ))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bubbleFrame = $0 }
                    .gesture(PressAndHoldGesture {
                        ClickHaptics.impact(.medium)
                        onLongPress?(message, bubbleFrame)
                    })
                    .accessibilityAction(named: "Message actions") {
                        onLongPress?(message, bubbleFrame)
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
            BeaconMessageCard(beacon: beacon, time: message.formattedTime, isOutgoing: message.isOutgoing,
                              onOpen: BubbleTapGate.gated { onOpenBeacon?(beacon) })
        } else if let media = message.media {
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
                    onOpen: { url in if BubbleTapGate.allowsTap { onOpenMedia?(url, media.kind) } }
                )
                .overlay { UploadStateOverlay(message: message, onRetry: onRetrySend, onDiscard: onDiscardFailed) }
                HStack(spacing: 4) {
                    Text(message.formattedTime).monospacedDigit()
                    if showsStatus {
                        animatedStatusIcon(readTint: ClickColors.accentForeground)
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
            (bodyText
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

    /// The message text; a call log leads with its direction/outcome icon.
    private var bodyText: Text {
        guard message.messageType == .callLog else { return Text(message.content) }
        let unanswered = CallLogFormatting.isUnanswered(message.content)
        let symbol = unanswered ? "phone.down.fill" : (message.isOutgoing ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill")
        return Text(Image(systemName: symbol)).foregroundColor(unanswered ? ClickColors.destructive : foreground)
            + Text(verbatim: " " + message.content)
    }

    private var foreground: Color {
        message.isOutgoing ? ClickColors.messageOutgoingForeground : ClickColors.messageIncomingForeground
    }

    private var showsStatus: Bool {
        message.isOutgoing && (showsReceipts || [.pending, .sending, .failed].contains(message.deliveryStatus))
    }

    /// Same characters as the visible meta row, used only to reserve its width. " ✓✓" is at
    /// least as wide as the fixed receipt slot, whatever the receipt state.
    private var timePlaceholder: String {
        (message.isEdited ? "edited " : "") + message.formattedTime + (showsStatus ? " ✓✓" : "")
    }

    private var metaRow: some View {
        HStack(spacing: 3) {
            if message.isEdited { Text("edited") }
            Text(message.formattedTime).monospacedDigit()
            if showsStatus { animatedStatusIcon(readTint: Color(hex: "#7DD3FC")) }
        }
        .font(ClickTypography.caption)
        .foregroundStyle(message.isOutgoing ? ClickColors.messageOutgoingForeground.opacity(0.72) : ClickColors.textSecondary)
    }

    private func replyQuote(snippet: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
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
            .padding(.trailing, ReplyThumbnail.applies(to: replyTarget) ? 0 : 10)
            if let replyTarget, ReplyThumbnail.applies(to: replyTarget) {
                ReplyThumbnail(target: replyTarget, load: mediaLoader)
                    .padding(.trailing, 6)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture(perform: BubbleTapGate.gated {
            if let id = message.replyToID { onTapReplyQuote?(id) }
        })
        .accessibilityAddTraits(onTapReplyQuote == nil ? [] : .isButton)
        .accessibilityHint(onTapReplyQuote == nil ? "" : "Shows the original message")
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
                // Long press lists who reacted.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    guard let onShowReactions else { return }
                    ClickHaptics.impact(.medium)
                    onShowReactions(message, reaction.reactionType)
                })
                .accessibilityLabel("\(reaction.reactionType), \(reaction.count)\(reaction.userReacted ? ", including you" : "")")
                .accessibilityAction(named: "Show who reacted") { onShowReactions?(message, reaction.reactionType) }
            }
        }
        .padding(.horizontal, 5)
    }

    /// Reply arrow that fades and scales in from 20 pt of drag and fills at the threshold.
    private var replyHint: some View {
        let progress = SwipeReplyPhysics.hintProgress(offset: abs(dragOffset))
        return Image(systemName: progress >= 1 ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(progress >= 1 ? ClickColors.accentForeground : ClickColors.textSecondary)
            .frame(width: 30, height: 30)
            .background(ClickColors.fillStrong.opacity(progress), in: Circle())
            .scaleEffect(0.6 + 0.4 * progress * (progress >= 1 ? 1.12 : 1))
            .opacity(progress)
            // Centered in the space the bubble reveals as it moves.
            .offset(x: dragOffset * 0.5 + (message.isOutgoing ? 15 : -15))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func swipeChanged(_ dx: CGFloat) {
        // Incoming bubbles swipe right, outgoing swipe left; the other way is inert.
        let allowed = message.isOutgoing ? min(dx, 0) : max(dx, 0)
        dragOffset = SwipeReplyPhysics.rubberBand(allowed)
        let crossed = abs(dragOffset) >= SwipeReplyPhysics.threshold
        if crossed, !hasTriggeredReplyHaptic {
            ClickHaptics.impact(.light)
            hasTriggeredReplyHaptic = true
        } else if !crossed {
            // Backing off re-arms, but only one haptic fires per crossing.
            hasTriggeredReplyHaptic = false
        }
    }

    private func swipeEnded() {
        if abs(dragOffset) >= SwipeReplyPhysics.threshold {
            onReply(message)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            dragOffset = 0
        }
        hasTriggeredReplyHaptic = false
    }

    /// clock → ✓ → ◯✓ (delivered) → ●✓ (read, highlighted), with a small pop on each step.
    /// Every state has the same fixed width, so a receipt changing never moves the time or
    /// reflows the bubble (the same circle-check language as the inbox).
    private func animatedStatusIcon(readTint: Color) -> some View {
        statusIcon(readTint: readTint)
            .frame(width: Self.statusIconWidth)
            .id(message.deliveryStatus)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .animation(ClickMotion.press, value: message.deliveryStatus)
    }

    /// Fixed receipt slot; the invisible time copy reserves the same width.
    private static let statusIconWidth: CGFloat = 14

    @ViewBuilder
    private func statusIcon(readTint: Color) -> some View {
        switch message.deliveryStatus {
        case .pending, .sending:
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityLabel("Sending")

        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .accessibilityLabel("Sent")

        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityLabel("Delivered")

        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(readTint)
                .accessibilityLabel("Read")

        case .failed:
            Button(action: BubbleTapGate.gated {
                ClickHaptics.warning()
                onRetrySend?(message)
            }) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ClickColors.messageOutgoingForeground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message failed. Tap to retry.")
        }
    }
}

/// A shared event/beacon as a card (prototype "Sunset Run Club"), not as "Beacon: …" text.
private struct BeaconMessageCard: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment?
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
        .task(id: beacon.beaconID) { await env?.beacons.prefetch(id: beacon.beaconID) }
    }

    private var detail: String? {
        let parts = [beacon.scheduleLabel ?? beacon.start.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) },
                     beacon.locationName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Swipe-to-reply physics (prototype interaction contract), pure for unit tests.
enum SwipeReplyPhysics {
    enum Intent: Equatable { case horizontal, vertical }

    nonisolated static let activationDistance: CGFloat = 6
    nonisolated static let threshold: CGFloat = 58
    nonisolated static let hintStart: CGFloat = 20
    nonisolated static let resistance: CGFloat = 90

    /// Follows the finger with exponential resistance so it never stops dead:
    /// `L · (1 − e^(−|dx|/L))`, signed.
    nonisolated static func rubberBand(_ dx: CGFloat, limit: CGFloat = resistance) -> CGFloat {
        let magnitude = limit * (1 - exp(-abs(dx) / limit))
        return dx < 0 ? -magnitude : magnitude
    }

    /// 0 below 20 pt, 1 at the threshold.
    nonisolated static func hintProgress(offset: CGFloat) -> Double {
        Double(min(1, max(0, (offset - hintStart) / (threshold - hintStart))))
    }

    /// Horizontal only when clearly sideways; vertical scrolling wins once it passes 8 pt.
    nonisolated static func intent(dx: CGFloat, dy: CGFloat) -> Intent? {
        if abs(dy) > 8, abs(dy) >= abs(dx) { return .vertical }
        if abs(dx) > abs(dy) * 1.2, abs(dx) >= activationDistance { return .horizontal }
        return nil
    }
}

/// Progress veil over an outgoing attachment's own frame: a determinate "encrypting" stage, then
/// byte-accurate upload progress; on failure, retry or remove in place.
private struct UploadStateOverlay: View {
    let message: ChatMessageItem
    let onRetry: ((ChatMessageItem) -> Void)?
    let onDiscard: ((ChatMessageItem) -> Void)?

    var body: some View {
        if message.isOutgoing, message.deliveryStatus == .sending || message.deliveryStatus == .failed {
            ZStack {
                RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
                    .fill(.black.opacity(0.28))
                if message.deliveryStatus == .failed {
                    HStack(spacing: 14) {
                        circleButton("arrow.clockwise", label: "Retry sending") { onRetry?(message) }
                        if let onDiscard {
                            circleButton("xmark", label: "Remove") { onDiscard(message) }
                        }
                    }
                } else {
                    ring
                }
            }
            .transition(.opacity)
            .animation(ClickMotion.subtleFade, value: message.deliveryStatus)
        }
    }

    private var fraction: Double? {
        switch message.uploadProgress {
        case .uploading(let fraction)?: fraction
        case .encrypting?, nil: nil
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 3)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: fraction)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityElement()
        .accessibilityLabel(fraction.map { "Uploading, \(Int($0 * 100)) percent" } ?? "Encrypting")
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
