import SwiftUI

/// Semantic color palette for Click iOS design system.
public enum ClickColors {
    // Primary Brand & Accents
    public static let primary = Color("AccentColor")
    public static let brandElectric = Color(red: 0.15, green: 0.45, blue: 1.0)
    public static let brandTeal = Color(red: 0.0, green: 0.8, blue: 0.75)
    public static let brandCoral = Color(red: 1.0, green: 0.35, blue: 0.35)

    // Backgrounds & Material
    public static let background = Color(uiColor: .systemBackground)
    public static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    public static let tertiaryBackground = Color(uiColor: .tertiarySystemBackground)
    public static let groupedBackground = Color(uiColor: .systemGroupedBackground)

    // Content & Typography
    public static let label = Color(uiColor: .label)
    public static let secondaryLabel = Color(uiColor: .secondaryLabel)
    public static let tertiaryLabel = Color(uiColor: .tertiaryLabel)

    // Separators & Borders
    public static let separator = Color(uiColor: .separator)
    public static let opaqueSeparator = Color(uiColor: .opaqueSeparator)

    // Status Indicators
    public static let statusOnline = Color(red: 0.18, green: 0.80, blue: 0.44)
    public static let statusAway = Color(red: 0.95, green: 0.65, blue: 0.15)
    public static let statusOffline = Color(uiColor: .systemGray3)
    public static let statusDanger = Color(red: 0.92, green: 0.23, blue: 0.23)
}
