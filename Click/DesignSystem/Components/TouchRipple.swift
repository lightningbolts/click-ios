import SwiftUI

extension View {
    /// An accent "drop of water" that grows from the exact touch point when the view is tapped,
    /// clipped to its bounds. `bleed` extends it past the content (a list row's side insets).
    /// Recognized alongside the row's own buttons, so it never takes their taps.
    func touchRipple(bleed: CGFloat = 0) -> some View {
        modifier(TouchRipple(bleed: bleed))
    }
}

private struct TouchRipple: ViewModifier {
    let bleed: CGFloat
    @State private var drops: [Drop] = []

    private struct Drop: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    ZStack {
                        ForEach(drops) { drop in
                            RippleDrop(point: drop.point, size: geometry.size)
                        }
                    }
                }
                .padding(.horizontal, -bleed)
                .clipped()
                .allowsHitTesting(false)
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                // Content coordinates → the bled ripple layer's.
                let drop = Drop(point: CGPoint(x: value.location.x + bleed, y: value.location.y))
                drops.append(drop)
                Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    drops.removeAll { $0.id == drop.id }
                }
            })
    }
}

/// One drop: a soft accent circle that expands to cover the row while fading out.
private struct RippleDrop: View {
    let point: CGPoint
    let size: CGSize
    @State private var grown = false
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Far enough to reach the farthest corner from the touch.
        let reach = max(hypot(point.x, point.y), hypot(size.width - point.x, point.y),
                        hypot(point.x, size.height - point.y), hypot(size.width - point.x, size.height - point.y))
        Circle()
            .fill(RadialGradient(colors: [ClickColors.accentForeground.opacity(0.4), ClickColors.accentForeground.opacity(0.2)],
                                 center: .center, startRadius: 0, endRadius: reach))
            .frame(width: reach * 2, height: reach * 2)
            .scaleEffect(reduceMotion || grown ? 1 : 0.04)
            .opacity(faded ? 0 : 1)
            .position(point)
            .onAppear {
                // Spreads first, then fades: the highlight reads before it goes.
                withAnimation(.easeOut(duration: 0.45)) { grown = true }
                withAnimation(.easeIn(duration: 0.35).delay(0.3)) { faded = true }
            }
    }
}
