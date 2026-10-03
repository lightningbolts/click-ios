import SwiftUI

extension View {
    /// The Click Drop develop moment, shared by chat, event and shared drops: the photo holds its
    /// pixels (the drop's 12-blocks-across look) until `isDeveloped`, then resolves out of them.
    ///
    /// `plays` is decided when the view appears: true plays the full develop (a drop developed
    /// on this screen just now); false resolves in a quick fade (Reduce Motion), or shows the
    /// photo from the first frame when it's already developed.
    func clickDropDevelop(_ isDeveloped: Bool, plays: Bool) -> some View {
        modifier(ClickDropDevelopModifier(isDeveloped: isDeveloped, plays: plays))
    }
}

private struct ClickDropDevelopModifier: ViewModifier {
    let isDeveloped: Bool
    @State private var plays: Bool
    @State private var progress: Double

    /// Slow out of the pixels, settling softly into the photo.
    static let animation = Animation.timingCurve(0.25, 0.1, 0.1, 1, duration: ClickDropDevelopEffect.duration)

    init(isDeveloped: Bool, plays: Bool) {
        self.isDeveloped = isDeveloped
        _plays = State(initialValue: plays)
        _progress = State(initialValue: isDeveloped && !plays ? 1 : 0)
    }

    func body(content: Content) -> some View {
        content
            .modifier(ClickDropDevelopEffect(animatableData: progress))
            .onAppear(perform: develop)
            .onChange(of: isDeveloped) { develop() }
    }

    private func develop() {
        guard isDeveloped, progress < 1 else { return }
        withAnimation(plays ? Self.animation : ClickMotion.subtleFade) { progress = 1 }
    }
}

/// Renders `animatableData` (0 the pixels, 1 the photo) through the `clickDropDevelop` shader;
/// off entirely once developed, so a developed photo costs nothing.
struct ClickDropDevelopEffect: ViewModifier, Animatable {
    nonisolated var animatableData: Double

    static let duration: TimeInterval = 1.1

    func body(content: Content) -> some View {
        let progress = animatableData
        return content.visualEffect { effect, proxy in
            let block = max(proxy.size.width, proxy.size.height) / ClickDropPixelation.blocksPerSide
            return effect.layerEffect(
                ShaderLibrary.clickDropDevelop(.float2(proxy.size), .float(progress), .float(block)),
                maxSampleOffset: CGSize(width: block, height: block),
                isEnabled: progress < 1
            )
        }
    }
}
