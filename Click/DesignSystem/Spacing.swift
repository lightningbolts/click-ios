import SwiftUI

/// 4pt spacing rhythm and screen layout constants.
public enum ClickSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48

    /// Horizontal gutter between screen edges and root content.
    public static let screenGutter: CGFloat = 16
    /// Inner padding of a grouped surface.
    public static let surfacePadding: CGFloat = 16
}

/// Corner radii by semantic role. Pick the role, not the number; controls such as buttons,
/// chips, and search fields use `Capsule()` rather than a radius.
public enum ClickRadius {
    /// Badges, thumbnails, and compact auxiliary surfaces.
    public static let compact: CGFloat = 12
    /// Text fields and other rectangular inputs.
    public static let field: CGFloat = 14
    /// Grouped semantic regions (lists, settings groups, information blocks).
    public static let surface: CGFloat = 26
    /// Hero and signature surfaces.
    public static let prominent: CGFloat = 30
    /// Chat message bubbles.
    public static let messageBubble: CGFloat = 18
}

/// Control and geometry metrics. Heights are minimums so Dynamic Type can grow content.
public enum ClickMetrics {
    /// Minimum hit target for toolbar and icon-only controls.
    public static let minimumHitTarget: CGFloat = 44
    /// Minimum height of a row in a grouped list.
    public static let rowMinHeight: CGFloat = 54
    /// Minimum height of search fields.
    public static let searchMinHeight: CGFloat = 42
    /// Height of compact filter/selection chips.
    public static let chipHeight: CGFloat = 36
    /// Minimum height of secondary actions.
    public static let secondaryActionHeight: CGFloat = 44
    /// Minimum height of the primary action.
    public static let primaryActionHeight: CGFloat = 50
    /// Visual size of large circular quick actions.
    public static let quickActionSize: CGFloat = 64
    /// Stroke width for the rare surfaces that genuinely need an outline.
    public static let strokeWidth: CGFloat = 1
    /// Stroke width for focused inputs.
    public static let focusStrokeWidth: CGFloat = 2

    /// Avatar diameters by context.
    public enum Avatar {
        /// Navigation bar identity (chat header).
        public static let navigation: CGFloat = 32
        /// Standard list/person rows.
        public static let row: CGFloat = 44
        /// Conversation rows and horizontal people strips.
        public static let conversation: CGFloat = 56
        /// Identity headers (Me, profiles).
        public static let identity: CGFloat = 96
    }
}
