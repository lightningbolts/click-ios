import SwiftUI

/// The app's loading indicator: the Click mark, gently pulsing. Used for full-screen and
/// section loads (inline buttons keep the system spinner; media uses `ArcSpinner`). Under
/// Reduce Motion the mark holds still and only fades.
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
                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
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
}

#Preview {
    VStack {
        ClickLoadingView("Opening hub…")
        ClickLoadingView(size: 28, fillsSpace: false)
    }
}

/// Click's inline spinner (in place of the system one on media and attachments): a short arc
/// circling a faint track. Under Reduce Motion the arc holds still.
public struct ArcSpinner: View {
    private let tint: Color
    private let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color = .white, lineWidth: CGFloat = 3) {
        self.tint = tint
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.3), lineWidth: lineWidth)
            TimelineView(.animation(paused: reduceMotion)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : turn * 360 - 90))
            }
        }
        .accessibilityLabel("Loading")
    }
}
