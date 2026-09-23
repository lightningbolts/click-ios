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

/// Semantic typography roles for Click iOS.
///
/// Manrope is Click's brand/display voice and is reserved for major hierarchy: root large
/// titles, identity/event titles, and section headlines. Everything else — navigation titles,
/// buttons, rows, body copy, and metadata — uses the system font so the interface keeps native
/// texture. All roles scale with Dynamic Type; sizes are base optical targets, not fixed sizes.
public enum ClickTypography {
    // MARK: - Brand / display (Manrope)

    /// Root screen large title: Manrope ExtraBold 34.
    public static var largeTitle: Font { brand(size: 34, relativeTo: .largeTitle) }
    /// Major identity or event title: Manrope ExtraBold 28.
    public static var identityTitle: Font { brand(size: 28, relativeTo: .title) }
    /// Section headline: Manrope ExtraBold 22.
    public static var sectionTitle: Font { brand(size: 22, relativeTo: .title2) }

    // MARK: - Interface (system / SF Pro)

    /// Body copy and ordinary row titles (17).
    public static let body = Font.body
    /// Emphasized row titles and headings inside rows (17 semibold).
    public static let bodyEmphasized = Font.body.weight(.semibold)
    /// Button labels (17 semibold).
    public static let button = Font.body.weight(.semibold)
    /// Supporting copy under titles (15).
    public static let supporting = Font.subheadline
    /// Chips, compact controls, and small emphasized labels (15 semibold).
    public static let supportingEmphasized = Font.subheadline.weight(.semibold)
    /// Metadata such as timestamps and counts (13).
    public static let metadata = Font.footnote
    /// Emphasized metadata (13 semibold).
    public static let metadataEmphasized = Font.footnote.weight(.semibold)
    /// Captions and tertiary microcopy (12).
    public static let caption = Font.caption
    /// Badges and tiny status labels (11 semibold).
    public static let badge = Font.caption2.weight(.semibold)

    // MARK: - UIKit bridges

    /// Manrope large title for the native navigation bar, scaled for the current content size.
    static func largeTitleUIFont() -> UIFont {
        ClickFonts.registerFonts()
        let base = UIFont(name: FontName.extraBold, size: 34) ?? .systemFont(ofSize: 34, weight: .bold)
        return UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: base)
    }

    // MARK: - Private

    private enum FontName {
        static let extraBold = "Manrope-ExtraBold"
    }

    private static func brand(size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        ClickFonts.registerFonts()
        return Font.custom(FontName.extraBold, size: size, relativeTo: textStyle)
    }
}
