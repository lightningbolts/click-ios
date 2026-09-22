import SwiftUI

/// Semantic typography tokens for Click iOS design system.
/// Uses Manrope product font family with full Dynamic Type support.
public enum ClickTypography {
    // MARK: - Manrope PostScript Font Names
    public enum FontName {
        public static let regular = "Manrope-Regular"
        public static let medium = "Manrope-Medium"
        public static let semiBold = "Manrope-SemiBold"
        public static let bold = "Manrope-Bold"
        public static let extraBold = "Manrope-ExtraBold"
        public static let light = "Manrope-Light"
        public static let extraLight = "Manrope-ExtraLight"
    }

    // MARK: - Core Role Scale (Click Functional Clarity)
    /// Display Large: 48pt / ExtraBold (Relative to .largeTitle)
    public static let displayLarge = Font.custom(FontName.extraBold, size: 48, relativeTo: .largeTitle)

    /// Display Medium: 40pt / Bold (Relative to .largeTitle)
    public static let displayMedium = Font.custom(FontName.bold, size: 40, relativeTo: .largeTitle)

    /// Display Small: 36pt / Bold (Relative to .largeTitle)
    public static let displaySmall = Font.custom(FontName.bold, size: 36, relativeTo: .largeTitle)

    /// Headline Large: 32pt / Bold (Relative to .title)
    public static let headlineLarge = Font.custom(FontName.bold, size: 32, relativeTo: .title)

    /// Headline Medium: 24pt / Bold (Relative to .title2)
    public static let headlineMedium = Font.custom(FontName.bold, size: 24, relativeTo: .title2)

    /// Headline Small: 20pt / Bold (Relative to .title3)
    public static let headlineSmall = Font.custom(FontName.bold, size: 20, relativeTo: .title3)

    /// Title Large: 20pt / Bold (Relative to .title3)
    public static let titleLarge = Font.custom(FontName.bold, size: 20, relativeTo: .title3)

    /// Title Medium: 16pt / SemiBold (Relative to .headline)
    public static let titleMedium = Font.custom(FontName.semiBold, size: 16, relativeTo: .headline)

    /// Title Small: 14pt / SemiBold (Relative to .subheadline)
    public static let titleSmall = Font.custom(FontName.semiBold, size: 14, relativeTo: .subheadline)

    /// Body Large: 18pt / Medium (Relative to .body)
    public static let bodyLarge = Font.custom(FontName.medium, size: 18, relativeTo: .body)

    /// Body Medium: 16pt / Medium (Relative to .callout)
    public static let bodyMedium = Font.custom(FontName.medium, size: 16, relativeTo: .callout)

    /// Body Small: 14pt / Medium (Relative to .subheadline)
    public static let bodySmall = Font.custom(FontName.medium, size: 14, relativeTo: .subheadline)

    /// Label Bold: 14pt / Bold (Relative to .footnote)
    public static let labelBold = Font.custom(FontName.bold, size: 14, relativeTo: .footnote)

    /// Label Medium: 14pt / SemiBold (Relative to .footnote)
    public static let labelMedium = Font.custom(FontName.semiBold, size: 14, relativeTo: .footnote)

    /// Label Small: 12pt / SemiBold (Relative to .caption)
    public static let labelSmall = Font.custom(FontName.semiBold, size: 12, relativeTo: .caption)

    // MARK: - Backward Compatibility Aliases (Preserves Existing Callers)
    public static let largeTitle = headlineLarge
    public static let title = headlineMedium
    public static let title2 = headlineSmall
    public static let title3 = titleLarge
    public static let headline = titleMedium
    public static let body = bodyMedium
    public static let callout = titleMedium
    public static let subheadline = bodySmall
    public static let footnote = labelMedium
    public static let caption = labelSmall
    public static let caption2 = Font.custom(FontName.semiBold, size: 11, relativeTo: .caption2)
}
