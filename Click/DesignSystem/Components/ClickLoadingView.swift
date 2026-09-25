import SwiftUI

/// The app's loading indicator: the Click mark, gently pulsing. Used for full-screen and
/// section loads (inline button and media spinners stay native). Under Reduce Motion the mark
/// holds still and only fades.
public struct ClickLoadingView: View {
    private let caption: String?
    private let size: CGFloat
    private let fillsSpace: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    /// - Parameters:
    ///   - caption: optional line under the mark ("Opening hub…").
    ///   - size: mark size; 44 for screens, ~28 for sections.
    ///   - fillsSpace: centers in all available space (screens) vs. a compact row (sections).
    public init(_ caption: String? = nil, size: CGFloat = 44, fillsSpace: Bool = true) {
        self.caption = caption
        self.size = size
        self.fillsSpace = fillsSpace
    }

    public var body: some View {
        VStack(spacing: 12) {
            ClickLogo(style: .mark, size: size)
                .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.0 : 0.88))
                .opacity(pulsing ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
            if let caption {
                Text(caption)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
        .padding(.vertical, fillsSpace ? 0 : 12)
        .onAppear { pulsing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#Preview {
    VStack {
        ClickLoadingView("Opening hub…")
        ClickLoadingView(size: 28, fillsSpace: false)
    }
}
