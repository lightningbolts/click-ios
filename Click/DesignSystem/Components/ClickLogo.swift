import SwiftUI

/// Canonical Click logo component supporting adaptive presentation variants.
/// References the vector assets imported from Click's official brand design files.
public struct ClickLogo: View {
    public enum Style: Sendable {
        /// Standard container logo with rounded background (adapts to light/dark color scheme)
        case container
        /// Transparent circle-and-square mark (adapts to light/dark color scheme)
        case mark
        /// Explicit light-surface container logo
        case containerLight
        /// Explicit dark-surface container logo
        case containerDark
        /// Explicit transparent mark for light surfaces
        case markLight
        /// Explicit transparent mark for dark surfaces
        case markDark
    }

    @Environment(\.colorScheme) private var colorScheme

    private let style: Style
    private let size: CGFloat

    public init(style: Style = .container, size: CGFloat = 56) {
        self.style = style
        self.size = size
    }

    private var assetName: String {
        switch style {
        case .container:
            return colorScheme == .dark ? "ClickLogo" : "ClickLogoLight"
        case .mark:
            return colorScheme == .dark ? "ClickLogoMarkLight" : "ClickLogoMark"
        case .containerLight:
            return "ClickLogoLight"
        case .containerDark:
            return "ClickLogo"
        case .markLight:
            return "ClickLogoMark"
        case .markDark:
            return "ClickLogoMarkLight"
        }
    }

    public var body: some View {
        Image(assetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Click Logo")
    }
}
