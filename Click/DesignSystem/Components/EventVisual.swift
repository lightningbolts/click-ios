import SwiftUI

/// Deterministic generated identity for beacons, events, and hubs (spec §53).
///
/// A line-for-line port of click-web `lib/ui/generateCardVisual.ts` (itself mirroring the
/// KMP `CardVisual.kt`): same FNV-1a seed over UTF-16 code units, same 16 weighted hue
/// buckets, same scrim search. The same beacon therefore looks the same on iOS, Android,
/// and web, and never changes between renders. Golden fixtures live in `CardVisualTests`.
public struct CardVisual: Equatable, Sendable {
    public enum Pattern: String, CaseIterable, Sendable {
        case dots, diagonals, grain, grid, chevron
    }

    public enum HueFamily: String, CaseIterable, Sendable {
        case purple, blue, teal, coral, gold, magenta, green
    }

    public let hash: UInt32
    public let gradient: [String]
    public let pattern: Pattern
    public let hueFamily: HueFamily
    public let scrimAlpha: Double

    public init(seed rawSeed: String) {
        let seed = rawSeed.isEmpty ? "click" : rawSeed
        let hash = Self.fnv1a32(seed)
        let family = Self.hueBuckets[Int(hash % UInt32(Self.hueBuckets.count))]
        let primary = Self.hueStops[family]!
        let others = HueFamily.allCases.filter { $0 != family }
        let secondaryFamily = others[Int((hash / 16) % UInt32(others.count))]
        let secondary = Self.hueStops[secondaryFamily]!

        let stopA = primary[Int((hash / 8) % UInt32(primary.count))]
        let stopB = primary[Int((hash / 64) % UInt32(primary.count))]
        let stopC = secondary[Int((hash / 512) % UInt32(secondary.count))]
        var gradient: [String] = []
        for stop in [stopA, stopB, stopC] where !gradient.contains(stop) {
            gradient.append(stop)
        }

        self.hash = hash
        self.gradient = gradient
        self.pattern = Pattern.allCases[Int((hash / 7) % UInt32(Pattern.allCases.count))]
        self.hueFamily = family
        self.scrimAlpha = Self.scrimAlphaForContrast(gradient)
    }

    // MARK: - Palette (content identity only, never app chrome)

    static let hueStops: [HueFamily: [String]] = [
        .purple: ["#630ED4", "#7C3AED", "#5A00C6", "#732EE4", "#4C1D95", "#D2BBFF"],
        .blue: ["#224CFF", "#3D63FF", "#1A3FD9", "#0D2BB8", "#6B8CFF", "#102A9E"],
        .teal: ["#0F766E", "#0D9488", "#14B8A6", "#115E59", "#2DD4BF"],
        .coral: ["#E11D48", "#F43F5E", "#BE123C", "#FB7185", "#EA580C"],
        .gold: ["#D97706", "#F59E0B", "#B45309", "#FBBF24"],
        .magenta: ["#A21CAF", "#C026D3", "#86198F", "#DB2777", "#E879F9"],
        .green: ["#15803D", "#16A34A", "#166534", "#22C55E", "#4ADE80"]
    ]

    static let hueBuckets: [HueFamily] = [
        .purple, .purple, .purple, .purple, .purple,
        .blue, .blue, .blue,
        .teal, .teal,
        .coral, .coral,
        .magenta, .magenta,
        .gold,
        .green
    ]

    static func fnv1a32(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for unit in text.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
        }
        return hash
    }

    /// Smallest black scrim keeping white text at WCAG AA over every stop. Iterates with the
    /// same floating-point accumulation as the web implementation so results match exactly.
    static func scrimAlphaForContrast(_ backgrounds: [String]) -> Double {
        let floor = 0.28, ceiling = 0.82, step = 0.02
        guard !backgrounds.isEmpty else { return floor }
        var alpha = floor
        while alpha < ceiling {
            let readable = backgrounds.allSatisfy { hex in
                let (r, g, b) = rgb(hex)
                let keep = 1 - alpha
                let scrimmed = luminance(r * keep, g * keep, b * keep)
                return 1.05 / (scrimmed + 0.05) >= 4.5
            }
            if readable { return (alpha * 100).rounded() / 100 }
            alpha += step
        }
        return ceiling
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        let raw = hex.dropFirst()
        func channel(_ offset: Int) -> Double {
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 2)
            return Double(Int(raw[start..<end], radix: 16) ?? 0) / 255
        }
        return (channel(0), channel(2), channel(4))
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

/// Renders a beacon/event/hub visual: the uploaded image when present, otherwise the
/// deterministic generated gradient and pattern. Static — nothing animates while scrolling.
public struct EventVisual: View {
    private let seed: String
    private let imageURL: URL?
    private let symbol: String?
    private let cornerRadius: CGFloat

    @State private var image: UIImage?

    /// - Parameters:
    ///   - seed: the raw entity ID (beacon/hub ID) — never a list-key prefix.
    ///   - symbol: optional SF Symbol drawn over the generated visual (kind glyph).
    public init(seed: String, imageURL: String? = nil, symbol: String? = nil, cornerRadius: CGFloat = ClickRadius.compact) {
        self.seed = seed
        let trimmed = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        self.imageURL = url
        self.symbol = symbol
        self.cornerRadius = cornerRadius
        self._image = State(initialValue: url.flatMap {
            ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: Self.pixelSize)
        })
    }

    private static let pixelSize: CGFloat = 900

    /// Decodes these pictures into memory ahead of display.
    static func prefetch(_ urls: [String?]) {
        ImagePipeline.shared.prefetch(urls.compactMap { $0?.nonEmptyTrimmed.flatMap(URL.init(string:)) }, maxPixelSize: pixelSize)
    }

    public var body: some View {
        let visual = CardVisual(seed: seed)
        ZStack {
            if let image {
                // Overlay on a size-neutral base: an aspect-filled image must never grow the
                // visual beyond its frame (it overlapped neighboring chat cards).
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                LinearGradient(
                    colors: visual.gradient.map(Color.init(hex:)),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                CardPatternLayer(pattern: visual.pattern)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(visual.scrimAlpha), radius: 3)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: imageURL) {
            guard let imageURL, image == nil else { return }
            let loaded = await ImagePipeline.shared.image(for: imageURL, maxPixelSize: Self.pixelSize)
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// An event/beacon (or event hub) visual that uses the event's banner image when it has one:
/// the given URL, else the beacon's own image (resolved once through the beacon cache), else
/// the generated visual with its kind symbol.
struct BeaconVisual: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment?
    /// Nil for things with no beacon behind them (community hubs): always the generated visual.
    let beaconID: String?
    /// Seed for the generated visual (defaults to the beacon ID).
    var seed: String? = nil
    var imageURL: String? = nil
    var symbol: String? = "calendar"
    var cornerRadius: CGFloat = ClickRadius.compact

    @State private var resolvedURL: String?

    var body: some View {
        let url = imageURL?.nonEmptyTrimmed ?? resolvedURL ?? beaconID.flatMap { Self.knownURL($0) }
        EventVisual(seed: seed ?? beaconID ?? "", imageURL: url, symbol: symbol, cornerRadius: cornerRadius)
            .id(url)   // a newly resolved picture seeds from the memory cache like the first one
            .task(id: beaconID) {
                guard imageURL?.nonEmptyTrimmed == nil, let beaconID, let env else { return }
                resolvedURL = await env.beacons.imageURL(beaconID: beaconID)
                Self.remember(resolvedURL, for: beaconID)
            }
    }

    /// Banner URLs resolved before, by beacon ID (persisted), so a visual paints its picture
    /// on its first frame, even right after launch.
    private static let knownKey = "click.beacon.image-urls"
    private static var known: [String: String] = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: String] ?? [:]

    static func knownURL(_ beaconID: String) -> String? { known[beaconID]?.nonEmptyTrimmed }

    private static func remember(_ url: String?, for beaconID: String) {
        let value = url ?? ""
        guard known[beaconID] != value else { return }
        known[beaconID] = value
        if known.count > 500 { known = Dictionary(uniqueKeysWithValues: known.suffix(400).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(known, forKey: knownKey)
    }
}

/// Pattern ink over the generated gradient, matching web `cardVisualPattern.ts`
/// (white at 14% alpha). Drawn once with `Canvas`; no per-frame work.
private struct CardPatternLayer: View {
    let pattern: CardVisual.Pattern

    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(.white.opacity(0.14))
            switch pattern {
            case .dots:
                grid(size, spacing: 14) { context.fill(Path(ellipseIn: CGRect(x: $0 - 1.6, y: $1 - 1.6, width: 3.2, height: 3.2)), with: ink) }
            case .grain:
                grid(size, spacing: 5) { context.fill(Path(ellipseIn: CGRect(x: $0 - 0.8, y: $1 - 0.8, width: 1.6, height: 1.6)), with: ink) }
            case .grid:
                var path = Path()
                for x in stride(from: 0, through: size.width, by: 16) { path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height)) }
                for y in stride(from: 0, through: size.height, by: 16) { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
                context.fill(path, with: ink)
            case .diagonals:
                context.stroke(diagonals(size, spacing: 12, rising: true), with: ink, lineWidth: 1.2)
            case .chevron:
                context.stroke(diagonals(size, spacing: 18, rising: true), with: ink, lineWidth: 1.4)
                context.stroke(diagonals(size, spacing: 18, rising: false), with: ink, lineWidth: 1.4)
            }
        }
        .allowsHitTesting(false)
    }

    private func grid(_ size: CGSize, spacing: CGFloat, _ draw: (CGFloat, CGFloat) -> Void) {
        for x in stride(from: spacing / 2, through: size.width, by: spacing) {
            for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                draw(x, y)
            }
        }
    }

    private func diagonals(_ size: CGSize, spacing: CGFloat, rising: Bool) -> Path {
        var path = Path()
        let extent = size.width + size.height
        for offset in stride(from: -size.height, through: extent, by: spacing) {
            if rising {
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
            } else {
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
            }
        }
        return path
    }
}
