import SwiftUI

/// Small state indicator ("Live now", "Core", "Going", "36h left").
///
/// Presence-style pills must only assert what the data knows: never show "Offline" merely
/// because a presence subscription is disconnected.
public struct StatusPill: View {
    public enum Style: Sendable {
        /// Something happening right now (red dot).
        case live
        /// Quiet purple-tinted state (Core, Going).
        case tinted
        /// Neutral translucent state over imagery or surfaces.
        case neutral
    }

    private let text: String
    private let style: Style

    public init(_ text: String, style: Style = .tinted) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 5) {
            if style == .live {
                Circle().fill(Color.white).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(ClickTypography.metadataEmphasized)
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .frame(minHeight: 24)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch style {
        case .live, .neutral: .white
        case .tinted: ClickColors.accentForeground
        }
    }

    private var background: Color {
        switch style {
        case .live: Color(uiColor: .systemRed)
        case .tinted: ClickColors.selectionTint
        case .neutral: Color.black.opacity(0.45)
        }
    }
}
