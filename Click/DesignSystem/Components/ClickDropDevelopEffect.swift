import SwiftUI
import UIKit

/// The Click Drop develop moment, shared by chat, event and shared drops: the photo resolves out of
/// its pixels. Finer and finer pixel layers bloom out from the center, the photo last, so the
/// middle sharpens first. Plain SwiftUI (no shader), so every Xcode builds it.
///
/// `plays` is decided when the view appears: true plays the develop when `isDeveloped` (a drop
/// developed on this screen just now); false shows the photo at once, or fades it in when it
/// develops later (Reduce Motion). Callers keep their pixelated preview underneath until the
/// photo covers it.
struct ClickDropDevelopingImage: View {
    let image: UIImage
    let isDeveloped: Bool
    var contentMode: ContentMode = .fill

    @State private var plays: Bool
    @State private var revealed: Bool
    /// Coarse to fine (12, 24, 48, 96 blocks across); only built for a drop that plays.
    @State private var layers: [UIImage] = []

    /// Each finer layer starts blooming this long after the one before.
    private static let stagger: Double = 0.14
    private static let bloom: Double = 0.5
    /// How long a played develop takes from start to the photo fully in place.
    static let duration: TimeInterval = stagger * 3 + bloom
    private nonisolated static let blocksPerSide: [CGFloat] = [12, 24, 48, 96]

    init(image: UIImage, isDeveloped: Bool, plays: Bool, contentMode: ContentMode = .fill) {
        self.image = image
        self.isDeveloped = isDeveloped
        self.contentMode = contentMode
        _plays = State(initialValue: plays)
        _revealed = State(initialValue: isDeveloped && !plays)
    }

    var body: some View {
        // Always present and filling its frame, so the task runs and the size never collapses
        // while the layers are built.
        Color.clear.overlay {
            if !plays {
                if revealed { layer(image, pixelated: false).transition(.opacity) }
            } else if let coarsest = layers.first {
                ZStack {
                    layer(coarsest, pixelated: true)
                    ForEach(Array((layers.dropFirst() + [image]).enumerated()), id: \.offset) { index, finer in
                        layer(finer, pixelated: finer !== image)
                            .mask { bloomMask(delay: Double(index) * Self.stagger) }
                    }
                }
                // After the layers are on screen, so the bloom animates from the center.
                .onAppear(perform: reveal)
            }
        }
        .task {
            if plays, layers.isEmpty {
                let source = image
                layers = await Task.detached(priority: .userInitiated) { Self.makeLayers(source) }.value
            }
        }
        .onChange(of: isDeveloped) { reveal() }
    }

    private func reveal() {
        guard isDeveloped, !revealed, !plays || !layers.isEmpty else { return }
        withAnimation(plays ? nil : ClickMotion.subtleFade) { revealed = true }
    }

    private func layer(_ image: UIImage, pixelated: Bool) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(pixelated ? .none : .high)
                    .aspectRatio(contentMode: contentMode)
            }
            .clipped()
    }

    /// A soft-edged circle growing from the center until it covers the corners.
    private func bloomMask(delay: Double) -> some View {
        GeometryReader { proxy in
            let diameter = hypot(proxy.size.width, proxy.size.height) * 1.4
            Circle()
                .fill(RadialGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                     center: .center, startRadius: 0, endRadius: diameter / 2))
                .frame(width: diameter, height: diameter)
                .scaleEffect(revealed ? 1 : 0.001)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .animation(.easeOut(duration: Self.bloom).delay(delay), value: revealed)
        }
    }

    /// The photo drawn `n` pixels across for each step; shown without interpolation, each pixel is
    /// a crisp block.
    private nonisolated static func makeLayers(_ image: UIImage) -> [UIImage] {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return [] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return blocksPerSide.map { blocks in
            let size = CGSize(width: max(1, (image.size.width / longest * blocks).rounded()),
                              height: max(1, (image.size.height / longest * blocks).rounded()))
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
