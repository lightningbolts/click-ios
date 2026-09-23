import SwiftUI
import UIKit

/// Semantic color roles for Click iOS.
///
/// The palette is a neutral, system-like foundation where purple is an accent rather than a
/// surface. Ordinary labels, fills, surfaces, and separators are backed by iOS semantic colors so
/// they follow light/dark mode, Increase Contrast, and elevated presentation contexts natively.
/// Exact hex values are used only where the value is intentionally Click-specific.
///
/// Purple has four distinct jobs; do not substitute one for another:
/// - `accentForeground`: icons, links, selected text, control tint.
/// - `primaryActionFill`: the single strongly filled action in a region.
/// - `selectionTint`: quiet purple background for selected/highlighted state.
/// - `messageOutgoing`: outgoing chat bubbles (deliberately darker than the action fill).
public enum ClickColors {
    // MARK: - Backgrounds & Surfaces

    /// Root screen background. Pure black in dark mode; grouped gray in light mode.
    public static let background = Color(uiColor: .systemGroupedBackground)
    /// Plain (non-grouped) background for full-bleed content such as sheets and media.
    public static let plainBackground = Color(uiColor: .systemBackground)
    /// Primary grouped surface (#1C1C1E dark) for semantic regions.
    public static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// A surface raised above `surface`, e.g. a control inside a grouped region.
    public static let surfaceElevated = Color(uiColor: .tertiarySystemGroupedBackground)
    /// Low-emphasis translucent fill for chips, search fields, and secondary controls.
    public static let fillSubtle = Color(uiColor: .tertiarySystemFill)
    /// Stronger translucent fill for pressed/disabled controls.
    public static let fillStrong = Color(uiColor: .secondarySystemFill)
    /// Neutral hairline separator (rgba(84,84,88,.6) in dark mode).
    public static let separator = Color(uiColor: .separator)

    // MARK: - Text

    public static let textPrimary = Color(uiColor: .label)
    public static let textSecondary = Color(uiColor: .secondaryLabel)
    public static let textTertiary = dynamic(lightHex: "#8A8A8E", darkHex: "#98989F")

    // MARK: - Brand & Accent

    /// Canonical Click brand purple (#630ED4). Use for brand marks, not generic UI.
    public static let brand = Color(hex: "#630ED4")
    /// Accent foreground for icons, links, selected labels, and control tint.
    /// Backed by the `AccentColor` asset so system controls resolve to the same value.
    public static let accentForeground = Color("AccentColor")
    /// Fill for the one prominent primary action in a region.
    public static let primaryActionFill = Color(hex: "#7C3AED")
    public static let primaryActionForeground = Color.white
    /// Quiet purple-tinted background for selected state and low-emphasis highlights.
    public static let selectionTint = dynamic(lightHex: "#EFE7FD", darkHex: "#24133F")

    // MARK: - Chat

    public static let messageIncoming = dynamic(lightHex: "#E9E9EB", darkHex: "#232326")
    public static let messageIncomingForeground = textPrimary
    public static let messageOutgoing = dynamic(lightHex: "#5B21B6", darkHex: "#4A1FA6")
    public static let messageOutgoingForeground = Color.white
    public static let chatBackground = dynamic(lightHex: "#F7F7FA", darkHex: "#0B0B0D")

    // MARK: - Status

    public static let success = Color(uiColor: .systemGreen)
    public static let warning = Color(uiColor: .systemOrange)
    public static let destructive = Color(uiColor: .systemRed)
    public static let online = Color(uiColor: .systemGreen)
    public static let offline = Color(uiColor: .systemGray)

    // MARK: - Generated Content Palette (content visuals only, never app chrome)

    public enum GeneratedContent {
        public static let purple = Color(hex: "#630ED4")
        public static let blue = Color(hex: "#224CFF")
        public static let teal = Color(hex: "#0D9488")
        public static let coral = Color(hex: "#EA580C")
        public static let gold = Color(hex: "#CA8A04")
        public static let magenta = Color(hex: "#C026D3")
        public static let green = Color(hex: "#16A34A")
    }

    // MARK: - Dynamic Color Helpers

    private static func dynamic(lightHex: String, darkHex: String) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: darkHex) : UIColor(hex: lightHex)
        })
    }
}

// MARK: - Hex Initializers
extension UIColor {
    convenience init(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        var rgbValue: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&rgbValue)

        let r, g, b, a: CGFloat
        if cleanHex.count == 6 {
            r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgbValue & 0x0000FF) / 255.0
            a = 1.0
        } else if cleanHex.count == 8 {
            r = CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgbValue & 0x000000FF) / 255.0
        } else {
            r = 0; g = 0; b = 0; a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}
