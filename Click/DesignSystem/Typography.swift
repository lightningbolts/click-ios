import SwiftUI
import CoreText
import UIKit

/// Manages registration of custom Click font resources (Manrope) into CoreText.
public enum ClickFonts: Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var isRegistered = false
    }
    private static let storage = Storage()

    public static func registerFonts() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard !storage.isRegistered else { return }

        let fontFiles = [
            "Manrope-Regular",
            "Manrope-Medium",
            "Manrope-SemiBold",
            "Manrope-Bold",
            "Manrope-ExtraBold",
            "Manrope-Light",
            "Manrope-ExtraLight"
        ]

        var candidateBundles = [Bundle.main]
        candidateBundles.append(contentsOf: Bundle.allBundles)
        candidateBundles.append(contentsOf: Bundle.allFrameworks)

        for bundle in candidateBundles {
            for fontName in fontFiles {
                if let url = bundle.url(forResource: fontName, withExtension: "ttf") {
                    var error: Unmanaged<CFError>?
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                }
            }
        }
        storage.isRegistered = true
    }
}

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

    private static func font(name: String, size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        ClickFonts.registerFonts()
        return Font.custom(name, size: size, relativeTo: textStyle)
    }

    // MARK: - Core Role Scale (Click Functional Clarity)
    /// Display Large: 48pt / ExtraBold (Relative to .largeTitle)
    public static var displayLarge: Font {
        font(name: FontName.extraBold, size: 48, relativeTo: .largeTitle)
    }

    /// Display Medium: 40pt / Bold (Relative to .largeTitle)
    public static var displayMedium: Font {
        font(name: FontName.bold, size: 40, relativeTo: .largeTitle)
    }

    /// Display Small: 36pt / Bold (Relative to .largeTitle)
    public static var displaySmall: Font {
        font(name: FontName.bold, size: 36, relativeTo: .largeTitle)
    }

    /// Headline Large: 32pt / Bold (Relative to .title)
    public static var headlineLarge: Font {
        font(name: FontName.bold, size: 32, relativeTo: .title)
    }

    /// Headline Medium: 24pt / Bold (Relative to .title2)
    public static var headlineMedium: Font {
        font(name: FontName.bold, size: 24, relativeTo: .title2)
    }

    /// Headline Small: 20pt / Bold (Relative to .title3)
    public static var headlineSmall: Font {
        font(name: FontName.bold, size: 20, relativeTo: .title3)
    }

    /// Title Large: 20pt / Bold (Relative to .title3)
    public static var titleLarge: Font {
        font(name: FontName.bold, size: 20, relativeTo: .title3)
    }

    /// Title Medium: 16pt / SemiBold (Relative to .headline)
    public static var titleMedium: Font {
        font(name: FontName.semiBold, size: 16, relativeTo: .headline)
    }

    /// Title Small: 14pt / SemiBold (Relative to .subheadline)
    public static var titleSmall: Font {
        font(name: FontName.semiBold, size: 14, relativeTo: .subheadline)
    }

    /// Body Large: 18pt / Medium (Relative to .body)
    public static var bodyLarge: Font {
        font(name: FontName.medium, size: 18, relativeTo: .body)
    }

    /// Body Medium: 16pt / Medium (Relative to .callout)
    public static var bodyMedium: Font {
        font(name: FontName.medium, size: 16, relativeTo: .callout)
    }

    /// Body Small: 14pt / Medium (Relative to .subheadline)
    public static var bodySmall: Font {
        font(name: FontName.medium, size: 14, relativeTo: .subheadline)
    }

    /// Label Bold: 14pt / Bold (Relative to .footnote)
    public static var labelBold: Font {
        font(name: FontName.bold, size: 14, relativeTo: .footnote)
    }

    /// Label Medium: 14pt / SemiBold (Relative to .footnote)
    public static var labelMedium: Font {
        font(name: FontName.semiBold, size: 14, relativeTo: .footnote)
    }

    /// Label Small: 12pt / SemiBold (Relative to .caption)
    public static var labelSmall: Font {
        font(name: FontName.semiBold, size: 12, relativeTo: .caption)
    }

    // MARK: - Backward Compatibility Aliases (Preserves Existing Callers)
    public static var largeTitle: Font { headlineLarge }
    public static var title: Font { headlineMedium }
    public static var title2: Font { headlineSmall }
    public static var title3: Font { titleLarge }
    public static var headline: Font { titleMedium }
    public static var body: Font { bodyMedium }
    public static var callout: Font { titleMedium }
    public static var subheadline: Font { bodySmall }
    public static var footnote: Font { labelMedium }
    public static var caption: Font { labelSmall }
    public static var caption2: Font { font(name: FontName.semiBold, size: 11, relativeTo: .caption2) }
}
