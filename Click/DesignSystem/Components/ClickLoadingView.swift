import SwiftUI

/// The app's loading indicator: the Click mark breathing on a soft accent glow while rings
/// ripple out of it, like the tap that makes a click. Used for full-screen and section loads
/// (inline button and media spinners stay native). The rings are drawn over the layout, so the
/// loader takes no more room than its mark. Under Reduce Motion the mark holds still and only fades.
public struct ClickLoadingView: View {
    private let caption: String?
    private let size: CGFloat
    private let fillsSpace: Bool
    private let appearDelay: Duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    /// Loads that finish quickly (cached data, local reads) never flash a loader.
    @State private var isShown = false

    /// - Parameters:
    ///   - caption: optional line under the mark ("Opening hub…").
    ///   - size: mark size; `launchSize` for the app's launch screens, 44 for screens, ~28 for sections.
    ///   - fillsSpace: centers in all available space (screens) vs. a compact row (sections).
    ///   - appearDelay: how long to wait before showing anything (space is still reserved).
    /// The launch screen's mark, as large as Instagram's / WhatsApp's splash logo.
    public static let launchSize: CGFloat = 84

    public init(_ caption: String? = nil, size: CGFloat = 44, fillsSpace: Bool = true, appearDelay: Duration = .milliseconds(200)) {
        self.caption = caption
        self.size = size
        self.fillsSpace = fillsSpace
        self.appearDelay = appearDelay
    }

    public var body: some View {
        VStack(spacing: 12) {
            ClickLogo(style: .mark, size: size)
                .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.0 : 0.88))
                .opacity(pulsing ? 1 : 0.55)
                .animation(.easeInOut(duration: Self.beat / 2).repeatForever(autoreverses: true), value: pulsing)
                .background { if !reduceMotion { ripples } }
            if let caption {
                Text(caption)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
        .padding(.vertical, fillsSpace ? 0 : 12)
        .opacity(isShown ? 1 : 0)
        .task {
            try? await Task.sleep(for: appearDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { isShown = true }
            pulsing = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// One full breath of the mark; a ring leaves it every half breath, as the mark is smallest.
    private static let beat = 1.7

    /// A glow that breathes with the mark, and two rings that grow out of it and fade.
    private var ripples: some View {
        let beat = Self.beat
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [ClickColors.accentForeground.opacity(0.28), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.85))
                .frame(width: size * 1.7, height: size * 1.7)
                .opacity(pulsing ? 1 : 0.4)
                .animation(.easeInOut(duration: beat / 2).repeatForever(autoreverses: true), value: pulsing)
            // Each ring grows out of the mark and fades, half a breath apart: one leaves as the
            // other is halfway out.
            if pulsing {
                ForEach([0.0, 0.5], id: \.self) { start in
                    Circle()
                        .strokeBorder(ClickColors.accentForeground.opacity(0.5), lineWidth: max(1, size / 30))
                        .frame(width: size, height: size)
                        .keyframeAnimator(initialValue: start, repeating: true) { ring, phase in
                            let grown = 1 - (1 - phase) * (1 - phase)
                            ring.scaleEffect(0.75 + 0.85 * grown).opacity(1 - phase)
                        } keyframes: { _ in
                            KeyframeTrack {
                                LinearKeyframe(1.0, duration: (1 - start) * beat)
                                MoveKeyframe(0.0)
                                LinearKeyframe(start, duration: start * beat)
                            }
                        }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    VStack {
        ClickLoadingView("Opening hub…")
        ClickLoadingView(size: 28, fillsSpace: false)
    }
}
