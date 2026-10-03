import SwiftUI

/// The media/drop loading treatment: a faint band of light that drifts across a photo still
/// arriving or a drop developing, then rests, instead of a system spinner. Deliberately quiet —
/// pages use `ClickLoadingView`, and small row placeholders hold still. Under Reduce Motion
/// nothing moves.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    /// One sweep, then a rest, so the band reads as light passing rather than a strobe.
    private static let sweep: Double = 1.6
    private static let rest: Duration = .milliseconds(1100)

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(0.1), .white.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: phase * proxy.size.width * 1.5)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .task {
                        while !Task.isCancelled {
                            phase = -0.5
                            withAnimation(.easeInOut(duration: Self.sweep)) { phase = 1 }
                            try? await Task.sleep(for: .seconds(Self.sweep) + Self.rest)
                        }
                    }
                }
            }
            .clipped()
            .animation(ClickMotion.subtleFade, value: active)
    }
}

extension View {
    /// A faint light band drifting across this view while `active` (loading media, developing a drop).
    func shimmering(_ active: Bool = true) -> some View { modifier(ShimmerModifier(active: active)) }
}

/// A placeholder with the shape of what's coming. Media placeholders shimmer faintly; small row
/// placeholders (`animated: false`) hold still so a list never flickers.
struct ShimmerPlaceholder: View {
    var cornerRadius: CGFloat = 0
    var width: CGFloat?
    var height: CGFloat?
    var animated = true

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(ClickColors.fillSubtle)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
            .shimmering(animated)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityLabel("Loading")
    }
}

#Preview {
    VStack(spacing: 20) {
        ShimmerPlaceholder(cornerRadius: 16, width: 104, height: 140)
        ShimmerPlaceholder(cornerRadius: 5, width: 54, height: 14, animated: false)
    }
}
