import SwiftUI

/// The conversation atmosphere (audit §13.2): a deterministic, low-contrast wash derived from
/// the conversation's seed over the neutral chat surface, with a faint static motif.
///
/// It is a stationary layer behind the timeline — computed once from the seed, never animated
/// or re-rendered by scrolling — and needs no network, so it exists on the first frame.
struct ChatBackground: View {
    let seed: String

    var body: some View {
        let visual = CardVisual(seed: seed)
        let tint = Color(hex: visual.gradient.first ?? "#5A00C6")
        let accent = Color(hex: visual.gradient.last ?? "#224CFF")
        ZStack {
            ClickColors.chatBackground
            LinearGradient(
                colors: [tint.opacity(0.10), .clear, accent.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                // Sparse dot lattice; static geometry so it costs nothing while scrolling.
                let spacing: CGFloat = 28
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
                var y: CGFloat = 0
                var row = 0
                while y < size.height {
                    var x: CGFloat = row.isMultiple(of: 2) ? 0 : spacing / 2
                    while x < size.width {
                        context.fill(dot.offsetBy(dx: x, dy: y), with: .color(tint.opacity(0.08)))
                        x += spacing
                    }
                    y += spacing
                    row += 1
                }
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
