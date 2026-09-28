import SwiftUI

extension View {
    /// Asks before a destructive or irreversible action. Always an alert, never an action sheet:
    /// every button shows (an iOS 26 action sheet drops Cancel and leaves tapping away as the
    /// only way out), and the safe choice, `keep`, is the highlighted default.
    func confirmation<Actions: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        keep: String = "Cancel",
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        alert(title, isPresented: isPresented) {
            actions()
            PreferredButton(keep) {}
        } message: {
            if let message { Text(message) }
        }
    }
}

/// An alert's highlighted default (bold, in the app tint): the answer the alert encourages.
struct PreferredButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action).keyboardShortcut(.defaultAction)
    }
}
