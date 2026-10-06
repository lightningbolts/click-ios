import UIKit

/// App-wide keyboard control for moments SwiftUI focus can't reach (another view owns the field).
@MainActor
public enum ClickKeyboard {
    /// Ends editing wherever it is: the focused field resigns and the keyboard slides away.
    public static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
