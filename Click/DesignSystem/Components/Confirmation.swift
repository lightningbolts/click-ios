import SwiftUI

extension View {
    /// Asks before a destructive or irreversible action. Always an alert, never an action sheet:
    /// every button shows (an iOS 26 action sheet drops Cancel and leaves tapping away as the
    /// only way out), and the safe choice, `keep`, is the highlighted default. `keep` is the
    /// alert's cancel button, so the system doesn't add a second "Cancel" doing the same thing.
    func confirmation<Actions: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        keep: String = "Cancel",
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        alert(title, isPresented: isPresented) {
            actions()
            PreferredButton(keep, role: .cancel) {}
        } message: {
            if let message { Text(message) }
        }
    }
}

/// An alert's highlighted default: the answer the alert encourages. Its fill is the alert tint
/// set at launch (`ClickApp`), under the accent label, like the app's selected pills.
struct PreferredButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(title, role: role, action: action).keyboardShortcut(.defaultAction)
    }
}
