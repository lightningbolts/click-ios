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
    /// Tertiary text: #6C6C71 in light mode keeps 5.1:1 contrast on grouped backgrounds.
    public static let textTertiary = dynamic(lightHex: "#6C6C71", darkHex: "#98989F")

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
    public static let selectionTint = dynamic(lightHex: "#EEE5FF", darkHex: "#24133F")

    // MARK: - Chat

    public static let messageIncoming = dynamic(lightHex: "#E9E9EB", darkHex: "#232326")
    public static let messageIncomingForeground = textPrimary
    public static let messageOutgoing = dynamic(lightHex: "#5B21B6", darkHex: "#4A1FA6")
    public static let messageOutgoingForeground = Color.white
    public static let chatBackground = dynamic(lightHex: "#F7F7FA", darkHex: "#0B0B0D")

    // MARK: - Status

    public static let success = Color(uiColor: .systemGreen)
    public static let warning = Color(uiColor: .systemOrange)
    public static let destructive = dynamic(lightHex: "#D70015", darkHex: "#FF453A")
    public static let online = dynamic(lightHex: "#1FA855", darkHex: "#30D158")
    public static let offline = Color(uiColor: .systemGray)

    // MARK: - Generated Content Palette (content visuals only, never app chrome)

    public enum GeneratedContent {
        /// Avatar fallback colors. Order and values match the shipping Android/KMP client's
        /// `PlaceholderAvatarColors` so a person gets the same color on every platform.
        static let avatarPalette: [Color] = [
            "#4F46E5", "#7C3AED", "#0D9488", "#2563EB", "#BE185D",
            "#B45309", "#0F766E", "#4338CA", "#15803D", "#92400E"
        ].map(Color.init(hex:))

        /// Stable fallback color for a user or group ID. Mirrors KMP's
        /// `stableAvatarPlaceholderColor`: a 32-bit `31 * h + char` hash over UTF-16 units.
        public static func avatarColor(for seed: String) -> Color {
            avatarPalette[avatarPaletteIndex(for: seed)]
        }

        static func avatarPaletteIndex(for seed: String) -> Int {
            guard !seed.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
            var hash: Int32 = 0
            for unit in seed.utf16 {
                hash = 31 &* hash &+ Int32(unit)
            }
            return Int(hash & Int32.max) % avatarPalette.count
        }
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
