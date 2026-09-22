import SwiftUI
import UIKit

/// Semantic color palette for Click iOS design system.
/// Implements Click's purple-first Functional Clarity visual identity.
public enum ClickColors {
    // MARK: - Primary Brand Tokens
    /// Canonical Click purple (#630ED4)
    public static let primary = Color("AccentColor")
    public static let onPrimary = Color(hex: "#FFFFFF")
    public static let primaryContainer = Color(hex: "#7C3AED")
    public static let surfaceTint = Color(hex: "#732EE4")
    public static let secondaryAccent = Color(hex: "#224CFF")

    // MARK: - Primary Fixed (Badges & Highlights)
    public static let primaryFixed = Color(hex: "#EADDFF")
    public static let primaryFixedDim = Color(hex: "#D2BBFF")
    public static let onPrimaryFixed = Color(hex: "#25005A")
    public static let onPrimaryFixedVariant = Color(hex: "#5A00C6")

    // MARK: - Dynamic Semantic Surfaces
    public static let background = dynamic(lightHex: "#F9F9F9", darkHex: "#101212")
    public static let surface = dynamic(lightHex: "#FFFFFF", darkHex: "#1A1C1C")
    public static let surfaceContainerLow = dynamic(lightHex: "#F3F3F4", darkHex: "#1E2020")
    public static let surfaceContainer = dynamic(lightHex: "#EEEEEE", darkHex: "#242626")
    public static let surfaceContainerHigh = dynamic(lightHex: "#E8E8E8", darkHex: "#2A2C2C")
    public static let surfaceVariant = dynamic(lightHex: "#E2E2E2", darkHex: "#2A2C2C")

    // Backward-compatible surface aliases
    public static let secondaryBackground = surfaceContainerLow
    public static let tertiaryBackground = surfaceContainer
    public static let groupedBackground = background

    // MARK: - Content & Typography
    public static let textPrimary = dynamic(lightHex: "#1A1C1C", darkHex: "#F0F1F1")
    public static let textSecondary = dynamic(lightHex: "#4A4455", darkHex: "#D6D9D9")
    public static let outline = Color(hex: "#7B7487")
    public static let quietBorder = dynamic(lightHex: "#CCC3D8", darkHex: "#4A3D5C")

    // Aliases for system compatibility
    public static let label = textPrimary
    public static let secondaryLabel = textSecondary
    public static let tertiaryLabel = dynamic(lightHex: "#7B7487", darkHex: "#8E8B99")
    public static let separator = quietBorder
    public static let opaqueSeparator = quietBorder

    // MARK: - Status & Destructive
    public static let error = Color(hex: "#BA1A1A")
    public static let statusDanger = error
    public static let statusOnline = Color(hex: "#18CC70")
    public static let statusAway = Color(hex: "#F5A623")
    public static let statusOffline = dynamic(lightHex: "#8E8B99", darkHex: "#635F6E")

    // MARK: - Generated Content Palette (Isolated from App Chrome)
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
