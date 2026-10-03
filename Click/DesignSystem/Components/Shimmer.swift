import SwiftUI

/// The app's media/drop loading treatment: a soft band of light sweeping across the content
/// (a photo still arriving, a drop developing) instead of a system spinner. Pages use
/// `ClickLoadingView`; anything with a shape of its own shimmers in place. Under Reduce Motion
/// the band holds still and the content gently breathes instead.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.38), .white.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: width * 0.7)
                        .rotationEffect(.degrees(12))
                        .offset(x: reduceMotion ? width * 0.15 : phase * width * 1.4)
                        .opacity(reduceMotion ? (phase > 0 ? 0.5 : 0.2) : 1)
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .onAppear {
                        phase = -1
                        withAnimation(.linear(duration: reduceMotion ? 1.2 : 1.25).repeatForever(autoreverses: reduceMotion)) { phase = 1 }
                    }
                }
            }
            .clipped()
            .animation(ClickMotion.subtleFade, value: active)
    }
}

extension View {
    /// Sweeps a soft light band across this view while `active` (loading media, developing a drop).
    func shimmering(_ active: Bool = true) -> some View { modifier(ShimmerModifier(active: active)) }
}

/// A placeholder with the shape of what's coming (a photo, a tile), shimmering until it lands.
struct ShimmerPlaceholder: View {
    var cornerRadius: CGFloat = 0
    var width: CGFloat?
    var height: CGFloat?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(ClickColors.fillSubtle)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
            .shimmering()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel("Loading")
    }
}

#Preview {
    VStack(spacing: 20) {
        ShimmerPlaceholder(cornerRadius: 16, width: 104, height: 140)
        Color.gray.frame(width: 200, height: 120).shimmering()
    }
}
