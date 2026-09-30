import SwiftUI

extension View {
    /// Scrolling content dissolves under whatever sits above it (filter pills, a picker) instead
    /// of being cut on a hard line. It fades the content itself, not a colored band, so it works
    /// over glass too; the matching top margin keeps anything from being faded at rest.
    func edgeFadeTop(_ height: CGFloat = 12) -> some View {
        contentMargins(.top, height, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: height)
                    Color.black
                }
                // Content keeps drawing into the bottom safe area, as it does unmasked.
                .padding(.bottom, -200)
            }
    }
}
