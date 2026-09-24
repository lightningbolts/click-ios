import SwiftUI

extension View {
    /// Liquid Glass capsule/circle on iOS 26+, `.regularMaterial` below (CI builds with the
    /// iOS 18 SDK, so the iOS 26 API is compiled only when available).
    @ViewBuilder
    public func glassCircleBackground(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            } else {
                self.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            materialCapsule(tint: tint)
        }
        #else
        materialCapsule(tint: tint)
        #endif
    }

    @ViewBuilder
    private func materialCapsule(tint: Color?) -> some View {
        if let tint {
            self.background(tint, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}

/// The composer's 40 pt circular control ("+", mic, send), one shape for all three.
public struct ComposerCircleLabel: View {
    let systemImage: String
    let isProminent: Bool
    let foreground: Color

    public init(systemImage: String, isProminent: Bool = false, foreground: Color = ClickColors.textSecondary) {
        self.systemImage = systemImage
        self.isProminent = isProminent
        self.foreground = foreground
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isProminent ? ClickColors.primaryActionForeground : foreground)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 40, height: 40)
            .glassCircleBackground(tint: isProminent ? ClickColors.primaryActionFill : nil)
    }
}
