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

/// WhatsApp-style actions for one message: the message lifted in place, a reaction capsule
/// above it and an action panel below it. There is no dimming or blur: the chat stays exactly
/// as it was, and a tap anywhere else dismisses. Shown as an in-view overlay (not a cover), so
/// the conversation never disappears underneath it.
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
    @State private var isDismissing = false

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    /// Height of the inline navigation bar the overlay must stay clear of.
    private static let navigationBarHeight: CGFloat = 54

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

    /// Window safe area (the overlay itself ignores the safe area, so its proxy reports zero).
    private static var windowSafeArea: UIEdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }

    private func computeLayout(screenSize: CGSize, source: CGRect) -> OverlayLayoutMetrics {
        let safeArea = Self.windowSafeArea
        let menuHeight: CGFloat = CGFloat(actions.count) * 48
        let capsuleHeight: CGFloat = 56
        let gap: CGFloat = 8

        let maxHeight: CGFloat = screenSize.height * 0.40
        let bubbleHeight: CGFloat = min(source.height, maxHeight)

        let topBoundary: CGFloat = safeArea.top + Self.navigationBarHeight + 4
        let bottomBoundary: CGFloat = screenSize.height - safeArea.bottom - 8
        let neededAbove: CGFloat = capsuleHeight + gap + (bubbleHeight / 2)
        let neededBelow: CGFloat = (bubbleHeight / 2) + gap + menuHeight

        var midY: CGFloat = source.midY
        if midY + neededBelow > bottomBoundary {
            midY = bottomBoundary - neededBelow
        }
        if midY - neededAbove < topBoundary {
            midY = topBoundary + neededAbove
        }

        let bubbleTop: CGFloat = midY - (bubbleHeight / 2)
        let bubbleBottom: CGFloat = midY + (bubbleHeight / 2)
        let capsuleCenterY: CGFloat = bubbleTop - gap - (capsuleHeight / 2)
        let menuCenterY: CGFloat = bubbleBottom + gap + (menuHeight / 2)

        let screenWidth: CGFloat = screenSize.width
        let capsuleWidth: CGFloat = min(screenWidth - 32, 332)
        let panelWidth: CGFloat = 250

        func centerX(width: CGFloat) -> CGFloat {
            if message.isOutgoing {
                let maxX = min(screenWidth - 16, max(source.maxX, 16 + width))
                return maxX - width / 2
            }
            let minX = max(16, min(source.minX, screenWidth - 16 - width))
            return minX + width / 2
        }

        return OverlayLayoutMetrics(
            midY: midY,
            bubbleHeight: bubbleHeight,
            capsuleCenterY: capsuleCenterY,
            menuCenterY: menuCenterY,
            capsuleCenterX: centerX(width: capsuleWidth),
            capsuleWidth: capsuleWidth,
            panelCenterX: centerX(width: panelWidth),
            panelWidth: panelWidth
        )
    }

    public var body: some View {
        GeometryReader { geometry in
            // Global → local: the overlay's own origin may not be the screen origin.
            let origin = geometry.frame(in: .global).origin
            let source = sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let metrics = computeLayout(screenSize: geometry.size, source: source)
            ZStack {
                // Invisible catcher: taps and drags anywhere else dismiss; nothing is dimmed.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissOverlay)
                    .gesture(DragGesture(minimumDistance: 8).onEnded { _ in dismissOverlay() })

                bubble
                    .frame(width: source.width, height: metrics.bubbleHeight, alignment: .top)
                    .clipped()
                    .shadow(color: .black.opacity(appeared ? 0.18 : 0), radius: 14, x: 0, y: 6)
                    .scaleEffect(reduceMotion ? 1 : (appeared ? 1.02 : 1))
                    .position(x: source.midX, y: appeared ? metrics.midY : source.midY)
                    .allowsHitTesting(false)

                reactionCapsule
                    .frame(width: metrics.capsuleWidth, height: 56)
                    .position(x: metrics.capsuleCenterX, y: metrics.capsuleCenterY)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (appeared ? 1.0 : 0.9),
                                 anchor: message.isOutgoing ? .bottomTrailing : .bottomLeading)

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
        .allowsHitTesting(!isDismissing)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                appeared = true
            }
        }
    }

    /// Settles the bubble back into its row and fades the controls before removing the
    /// overlay, so tapping away never makes it vanish in one frame.
    private func dismissOverlay() {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            appeared = false
        } completion: {
            onDismiss()
        }
    }

    private var reactionCapsule: some View {
        HStack(spacing: 4) {
            ForEach(Self.quickEmojis, id: \.self) { emoji in
                let hasReacted = message.reactions.contains { $0.reactionType == emoji && $0.userReacted }
                Button {
                    ClickHaptics.impact(.light)
                    onReact(emoji)
                    dismissOverlay()
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
                ClickHaptics.impact(.light)
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
        // Liquid Glass on iOS 26 (material below), like the app's other floating controls.
        .glassCircleBackground()
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private var actionPanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    action.perform()
                    dismissOverlay()
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
        .glassPanelBackground(cornerRadius: 22)
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }
}
