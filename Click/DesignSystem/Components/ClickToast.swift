import SwiftUI

/// A short confirmation that floats at the bottom and fades after a moment (announced to
/// VoiceOver). Same look as the chat's toasts.
struct ClickToastModifier: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCircleBackground()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        UIAccessibility.post(notification: .announcement, argument: text)
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(ClickMotion.content) { if self.text == text { self.text = nil } }
                    }
            }
        }
        .animation(ClickMotion.content, value: text)
    }
}

extension View {
    func clickToast(_ text: Binding<String?>) -> some View {
        modifier(ClickToastModifier(text: text))
    }
}
