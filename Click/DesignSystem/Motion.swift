import SwiftUI

/// Semantic motion tokens for non-system animation transitions.
public enum ClickMotion {
    public static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
    public static let selection = Animation.spring(response: 0.25, dampingFraction: 0.8)
    public static let content = Animation.spring(response: 0.35, dampingFraction: 0.85)
    public static let reveal = Animation.spring(response: 0.5, dampingFraction: 0.75)
    public static let subtleFade = Animation.easeInOut(duration: 0.2)
}
