import SwiftUI

/// Semantic spacing, layout, and radius tokens for Click iOS design system.
/// Matches Click Functional Clarity rhythm standards.
public enum ClickSpacing {
    // MARK: - 4pt Rhythm Scale
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48

    // MARK: - Standard Mobile Layout Dimensions
    public static let contentGutter: CGFloat = 12
    public static let mobileMargin: CGFloat = 16

    // MARK: - Corner Radii
    public static let radiusInput: CGFloat = 8
    public static let radiusButton: CGFloat = 8
    public static let radiusCard: CGFloat = 16
    public static let radiusPill: CGFloat = 999

    // MARK: - Stroke Widths
    public static let borderQuietWidth: CGFloat = 1.0
    public static let borderFocusWidth: CGFloat = 2.0

    // MARK: - Compatibility Aliases
    public static let xxxSmall: CGFloat = 2
    public static let xxSmall: CGFloat = 4
    public static let xSmall: CGFloat = 8
    public static let small: CGFloat = 12
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 24
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
    public static let xxxLarge: CGFloat = 48

    public static let radiusSmall: CGFloat = radiusInput
    public static let radiusMedium: CGFloat = 12
    public static let radiusLarge: CGFloat = radiusCard
}
