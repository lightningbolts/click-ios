import SwiftUI

public struct MessageAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public var isDestructive: Bool = false
    public let perform: @MainActor () -> Void

    public init(id: String, title: String, systemImage: String, isDestructive: Bool = false, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.perform = perform
    }
}

private struct OverlayLayoutMetrics {
    let midY: CGFloat
    let bubbleHeight: CGFloat
    let capsuleCenterY: CGFloat
    let menuCenterY: CGFloat
    let capsuleCenterX: CGFloat
    let capsuleWidth: CGFloat
    let panelCenterX: CGFloat
    let panelWidth: CGFloat
}

/// WhatsApp-style actions for one message: dimmed, blurred backdrop; the message lifted in place;
/// a reaction capsule above it; an action panel below it. Tapping the backdrop dismisses.
public struct MessageActionOverlay: View {
    public let message: ChatMessageItem
    public let sourceFrame: CGRect          // bubble frame in global coordinates
    public let bubble: AnyView              // a non-interactive copy of the bubble to show lifted
    public let actions: [MessageAction]     // built by ChatView (only the ones that apply)
    public let onReact: (String) -> Void
    public let onMoreReactions: () -> Void
    public let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    public init(
        message: ChatMessageItem,
        sourceFrame: CGRect,
        bubble: AnyView,
        actions: [MessageAction],
        onReact: @escaping (String) -> Void,
        onMoreReactions: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.sourceFrame = sourceFrame
        self.bubble = bubble
        self.actions = actions
        self.onReact = onReact
        self.onMoreReactions = onMoreReactions
        self.onDismiss = onDismiss
    }

    private func computeLayout(screenSize: CGSize, safeArea: EdgeInsets) -> OverlayLayoutMetrics {
        let topBoundary: CGFloat = safeArea.top + 8
        let bottomBoundary: CGFloat = screenSize.height - safeArea.bottom - 8

        let menuHeight: CGFloat = CGFloat(actions.count) * 48
        let capsuleHeight: CGFloat = 56
        let gap: CGFloat = 8

        let maxHeight: CGFloat = screenSize.height * 0.40
        let bubbleHeight: CGFloat = min(sourceFrame.height, maxHeight)

        let neededAbove: CGFloat = capsuleHeight + gap + (bubbleHeight / 2)
        let neededBelow: CGFloat = (bubbleHeight / 2) + gap + menuHeight

        var midY: CGFloat = sourceFrame.midY
        if midY - neededAbove < topBoundary {
            midY = topBoundary + neededAbove
        }
        if midY + neededBelow > bottomBoundary {
            midY = bottomBoundary - neededBelow
        }

        let bubbleTop: CGFloat = midY - (bubbleHeight / 2)
        let bubbleBottom: CGFloat = midY + (bubbleHeight / 2)
        let capsuleCenterY: CGFloat = bubbleTop - gap - (capsuleHeight / 2)
        let menuCenterY: CGFloat = bubbleBottom + gap + (menuHeight / 2)

        let screenWidth: CGFloat = screenSize.width
        let capsuleWidth: CGFloat = min(screenWidth - 32, 332)
        let panelWidth: CGFloat = 250

        let isOutgoing = message.isOutgoing
        let capsuleCenterX: CGFloat
        if !isOutgoing {
            let minX = max(16, min(sourceFrame.minX, screenWidth - 16 - capsuleWidth))
            capsuleCenterX = minX + (capsuleWidth / 2)
        } else {
            let maxX = min(screenWidth - 16, max(sourceFrame.maxX, 16 + capsuleWidth))
            capsuleCenterX = maxX - (capsuleWidth / 2)
        }

        let panelCenterX: CGFloat
        if !isOutgoing {
            let minX = max(16, min(sourceFrame.minX, screenWidth - 16 - panelWidth))
            panelCenterX = minX + (panelWidth / 2)
        } else {
            let maxX = min(screenWidth - 16, max(sourceFrame.maxX, 16 + panelWidth))
            panelCenterX = maxX - (panelWidth / 2)
        }

        return OverlayLayoutMetrics(
            midY: midY,
            bubbleHeight: bubbleHeight,
            capsuleCenterY: capsuleCenterY,
            menuCenterY: menuCenterY,
            capsuleCenterX: capsuleCenterX,
            capsuleWidth: capsuleWidth,
            panelCenterX: panelCenterX,
            panelWidth: panelWidth
        )
    }

    public var body: some View {
        GeometryReader { geometry in
            let metrics = computeLayout(screenSize: geometry.size, safeArea: geometry.safeAreaInsets)
            ZStack {
                // 1. Backdrop
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    Color.black.opacity(0.35)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .opacity(appeared ? 1 : 0)

                // 2. Lifted Bubble Copy
                bubble
                    .frame(height: metrics.bubbleHeight)
                    .clipped()
                    .position(x: sourceFrame.midX, y: metrics.midY)
                    .allowsHitTesting(false)

                // 3. Reaction Capsule Above
                reactionCapsule
                    .frame(width: metrics.capsuleWidth, height: 56)
                    .position(x: metrics.capsuleCenterX, y: metrics.capsuleCenterY)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (appeared ? 1.0 : 0.9),
                                 anchor: message.isOutgoing ? .bottomTrailing : .bottomLeading)

                // 4. Action Panel Below
                if !actions.isEmpty {
                    actionPanel
                        .frame(width: metrics.panelWidth)
                        .position(x: metrics.panelCenterX, y: metrics.menuCenterY)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(reduceMotion ? 1 : (appeared ? 1.0 : 0.9),
                                     anchor: message.isOutgoing ? .topTrailing : .topLeading)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                appeared = true
            }
        }
    }

    private var reactionCapsule: some View {
        HStack(spacing: 4) {
            ForEach(Self.quickEmojis, id: \.self) { emoji in
                let hasReacted = message.reactions.contains { $0.reactionType == emoji && $0.userReacted }
                Button {
                    ClickHaptics.impact(.light)
                    onReact(emoji)
                    onDismiss()
                } label: {
                    ZStack {
                        if hasReacted {
                            Circle()
                                .fill(ClickColors.selectionTint.opacity(0.35))
                                .frame(width: 38, height: 38)
                        }
                        Text(emoji)
                            .font(.system(size: 30))
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            Button {
                ClickHaptics.impact(.medium)
                onDismiss()
                onMoreReactions()
            } label: {
                ZStack {
                    Circle()
                        .fill(ClickColors.fillStrong)
                        .frame(width: 40, height: 40)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ClickColors.textPrimary)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassCircleBackground()
    }

    private var actionPanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    onDismiss()
                    action.perform()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 22, alignment: .center)
                            .foregroundStyle(action.isDestructive ? ClickColors.destructive : ClickColors.textPrimary)
                        Text(action.title)
                            .font(ClickTypography.body)
                            .foregroundStyle(action.isDestructive ? ClickColors.destructive : ClickColors.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < actions.count - 1 {
                    Divider()
                        .padding(.horizontal, 16)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
    }
}
