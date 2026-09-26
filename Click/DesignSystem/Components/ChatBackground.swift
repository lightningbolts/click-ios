import SwiftUI

/// A chat's backdrop pattern. Every style is a subtle, static line drawing over the dark chat
/// color, tinted by the conversation's seed colors.
enum ChatBackdropStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case classic, city, nature, coffee, water, night, campus, contours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .city: "City"
        case .nature: "Outdoors"
        case .coffee: "Café"
        case .water: "Waterfront"
        case .night: "Night out"
        case .campus: "Campus"
        case .contours: "Heights"
        }
    }

    /// Keywords, checked in this order against where and how two people met.
    private static let keywords: [(ChatBackdropStyle, [String])] = [
        (.water, ["beach", "pier", "harbor", "harbour", "bay", "ocean", "lake", "river", "marina", "waterfront", "shore", "pool", "sea"]),
        (.contours, ["mountain", "summit", "peak", "ridge", "overlook", "viewpoint", "hill", "canyon"]),
        (.nature, ["park", "trail", "garden", "forest", "woods", "hike", "camp", "outdoor", "nature", "meadow", "arboretum"]),
        (.coffee, ["cafe", "café", "coffee", "espresso", "tea", "bakery", "brunch", "restaurant", "diner", "kitchen", "bistro", "food"]),
        (.night, ["bar", "club", "lounge", "pub", "concert", "party", "festival", "music", "theater", "theatre", "karaoke", "brewery"]),
        (.campus, ["university", "college", "campus", "library", "school", "lecture", "class", "study", "dorm"]),
        (.city, ["street", "avenue", "downtown", "station", "square", "plaza", "mall", "office", "market", "transit"]),
    ]

    /// The style for where two people first met: the first encounter's venue, place, event and
    /// context, else the inbox's encounter location; a late-night meeting reads as a night out,
    /// high ground as contours, a known city as streets. Nil while neither is known.
    static func automatic(encounters: [Encounter]?, place: String?) -> ChatBackdropStyle? {
        let encounter = encounters?.min { $0.date < $1.date }
        guard encounter != nil || place?.nonEmptyTrimmed != nil else { return nil }
        let text = ([encounter?.venue, encounter?.place, encounter?.eventTitle, encounter?.neighbourhood, place]
            .compactMap { $0 } + (encounter?.contextTags ?? []))
            .joined(separator: " ")
            .lowercased()
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        for (style, keys) in keywords where keys.contains(where: { words.contains($0) || words.contains($0 + "s") }) {
            return style
        }
        guard let encounter else { return .classic }
        let hour = Calendar.current.component(.hour, from: encounter.date)
        if hour >= 21 || hour < 5 || (encounter.lux ?? 100) < 5 { return .night }
        if (encounter.relativeAltitudeMeters ?? 0) > 150 { return .contours }
        if encounter.city != nil { return .city }
        return .classic
    }
}

/// A conversation's backdrop: a motif, and for the automatic one the encounter signature that
/// makes it this connection's own (a chosen style uses its fixed palette).
struct ChatBackdrop: Codable, Equatable, Sendable {
    var style: ChatBackdropStyle
    var signature: EncounterSignature?

    /// From where and how you met (a person's encounters, or a group's hangouts); nil while
    /// none of it is known.
    static func automatic(encounters: [Encounter]?, place: String?, seed: String) -> ChatBackdrop? {
        guard let style = ChatBackdropStyle.automatic(encounters: encounters, place: place) else { return nil }
        return ChatBackdrop(style: style, signature: EncounterSignature(encounters: encounters ?? [], seed: seed))
    }
}

/// What made a connection's encounters theirs, reduced to drawing parameters: the sky's hue at
/// the hour you met (shifted by the temperature, muted by grey weather), how lively it was, the
/// wind's direction, and the path through the places you've met.
struct EncounterSignature: Codable, Equatable, Sendable {
    /// 0...1 around the color wheel.
    var hue: Double
    /// 0.3...1: grey or dark moments are muted, clear bright ones vivid.
    var vividness: Double
    /// 0...1: quiet and still → sparse, loud and moving → dense.
    var energy: Double
    /// Tilt of the motif (radians), from the wind.
    var tilt: Double
    /// The spots you've met at, in order, normalized to 0...1 (north up).
    var path: [CGPoint]

    init(encounters: [Encounter], seed: String) {
        let jitter = Double(CardVisual.fnv1a32(seed) % 10_000) / 10_000
        let ordered = encounters.sorted { $0.date < $1.date }
        let first = ordered.first
        if let first {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: first.date)
            let warmth = first.temperatureCelsius.map { min(1, max(-1, ($0 - 15) / 15)) } ?? 0
            hue = Self.skyHue(Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60) - warmth * 0.04 + (jitter - 0.5) * 0.1
        } else {
            hue = jitter
        }
        hue = hue - hue.rounded(.down)
        let weather = first?.weatherCondition?.lowercased() ?? ""
        let grey = ["rain", "cloud", "overcast", "fog", "mist", "drizzle", "snow", "haze", "storm"].contains { weather.contains($0) }
        vividness = (grey ? 0.5 : 0.9) * ((first?.lux).map { $0 < 20 ? 0.85 : 1 } ?? 1)
        let loudness: Double
        if let decibels = first?.noiseDecibels {
            loudness = (decibels - 35) / 50
        } else {
            let level = first?.noiseLevel?.lowercased() ?? ""
            loudness = level.contains("loud") || level.contains("busy") ? 0.8 : level.contains("quiet") ? 0.2 : 0.5
        }
        energy = min(1, max(0, loudness + min(0.3, (first?.motionVariance ?? 0) * 0.1)))
        tilt = ((first?.windDirectionDegrees).map { $0 * .pi / 180 } ?? jitter * .pi * 2)
        path = Self.normalizedPath(ordered)
    }

    /// Dawn pink, morning and midday blues, golden-hour orange, dusk violet, night indigo.
    private static func skyHue(_ hour: Double) -> Double {
        let stops: [(Double, Double)] = [(0, 0.68), (5, 0.70), (6.5, 0.93), (9, 0.57), (13, 0.52), (17, 0.08), (19.5, 0.80), (21.5, 0.70), (24, 0.68)]
        guard let upper = stops.firstIndex(where: { $0.0 >= hour }), upper > 0 else { return 0.68 }
        let (h0, v0) = stops[upper - 1], (h1, v1) = stops[upper]
        var delta = v1 - v0
        if abs(delta) > 0.5 { delta -= delta.sign == .minus ? -1 : 1 }   // the short way around the wheel
        return v0 + delta * (hour - h0) / max(0.001, h1 - h0)
    }

    /// Distinct spots (about 10 m apart), scaled into a unit square keeping their shape.
    private static func normalizedPath(_ encounters: [Encounter]) -> [CGPoint] {
        var spots: [(lat: Double, lon: Double)] = []
        for encounter in encounters {
            guard let lat = encounter.latitude, let lon = encounter.longitude, (lat, lon) != (0, 0) else { continue }
            if let last = spots.last, abs(last.lat - lat) < 0.0001, abs(last.lon - lon) < 0.0001 { continue }
            spots.append((lat, lon * cos(lat * .pi / 180)))
        }
        spots = Array(spots.suffix(12))
        guard spots.count > 1, let minLat = spots.map(\.lat).min(), let maxLat = spots.map(\.lat).max(),
              let minLon = spots.map(\.lon).min(), let maxLon = spots.map(\.lon).max() else {
            return spots.isEmpty ? [] : [CGPoint(x: 0.5, y: 0.5)]
        }
        let span = max(maxLat - minLat, maxLon - minLon, 0.0001)
        let padX = (1 - (maxLon - minLon) / span) / 2, padY = (1 - (maxLat - minLat) / span) / 2
        return spots.map { CGPoint(x: padX + ($0.lon - minLon) / span, y: padY + (maxLat - $0.lat) / span) }
    }
}

/// Chosen styles and automatic backdrops by conversation key (connection ID, else chat ID),
/// stored on this device. The automatic one is remembered, so a chat's first frame already has
/// it (the encounters it comes from load later).
@Observable
@MainActor
final class ChatBackdrops {
    static let shared = ChatBackdrops()

    private static let choicesKey = "click.chat.backdrops"
    private static let automaticKey = "click.chat.backdrops.signatures"

    private var choices: [String: String] = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: String] ?? [:]
    @ObservationIgnored private var automatic: [String: Data] = UserDefaults.standard.dictionary(forKey: automaticKey) as? [String: Data] ?? [:]

    /// The chosen style, or nil for automatic.
    func choice(for key: String) -> ChatBackdropStyle? {
        choices[key].flatMap(ChatBackdropStyle.init(rawValue:))
    }

    func choose(_ style: ChatBackdropStyle?, for key: String) {
        choices[key] = style?.rawValue
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
    }

    /// The automatic backdrop; `resolved` (when the encounters are known) replaces the
    /// remembered one. Before anything is known it is still this conversation's own color.
    func automaticBackdrop(for key: String, resolved: ChatBackdrop?) -> ChatBackdrop {
        guard let resolved else {
            return automatic[key].flatMap { try? JSONDecoder().decode(ChatBackdrop.self, from: $0) }
                ?? ChatBackdrop(style: .classic, signature: EncounterSignature(encounters: [], seed: key))
        }
        if let data = try? JSONEncoder().encode(resolved), automatic[key] != data {
            automatic[key] = data
            UserDefaults.standard.set(automatic, forKey: Self.automaticKey)
        }
        return resolved
    }

    func backdrop(for key: String, resolved: ChatBackdrop?) -> ChatBackdrop {
        choice(for: key).map { ChatBackdrop(style: $0) } ?? automaticBackdrop(for: key, resolved: resolved)
    }
}

/// A style's colors: a base gradient, soft glows for depth, the motif's ink and a second accent.
private struct BackdropPalette {
    let top: Color
    let bottom: Color
    let glows: [Color]
    let ink: Color
    let accent: Color

    init(top: Color, bottom: Color, glows: [Color], ink: Color, accent: Color) {
        self.top = top
        self.bottom = bottom
        self.glows = glows
        self.ink = ink
        self.accent = accent
    }

    init(_ top: String, _ bottom: String, glows: [String], ink: String, accent: String) {
        self.init(top: Color(hex: top), bottom: Color(hex: bottom), glows: glows.map { Color(hex: $0) },
                  ink: Color(hex: ink), accent: Color(hex: accent))
    }

    /// A connection's own spectrum: its sky hue, a neighbouring glow, and the complement as accent.
    static func of(_ signature: EncounterSignature, dark: Bool) -> BackdropPalette {
        let h = signature.hue, v = signature.vividness
        func color(_ shift: Double, _ saturation: Double, _ brightness: Double) -> Color {
            let hue = h + shift
            return Color(hue: hue - hue.rounded(.down), saturation: min(1, saturation), brightness: brightness)
        }
        return dark
            ? .init(top: color(0, 0.25 + 0.45 * v, 0.2), bottom: color(0.06, 0.3 + 0.35 * v, 0.07),
                    glows: [color(0, 0.25 + 0.6 * v, 0.95), color(0.16, 0.25 + 0.55 * v, 0.9), color(-0.1, 0.3 + 0.4 * v, 0.8)],
                    ink: color(0.03, 0.25, 0.97), accent: color(0.5, 0.3 + 0.45 * v, 1))
            : .init(top: color(0, 0.06 + 0.08 * v, 0.99), bottom: color(0.06, 0.12 + 0.12 * v, 0.95),
                    glows: [color(0, 0.3 + 0.4 * v, 1), color(0.16, 0.3 + 0.35 * v, 1), color(-0.1, 0.3 + 0.3 * v, 0.95)],
                    ink: color(0.02, 0.55, 0.5), accent: color(0.5, 0.55, 0.7))
    }

    /// Dark palettes stay deep enough for bubbles and headers to read; light ones stay pale.
    static func of(_ style: ChatBackdropStyle, dark: Bool, visual: CardVisual) -> BackdropPalette {
        switch (style, dark) {
        case (.classic, _):
            let tint = visual.gradient.first ?? "#5A00C6", accent = visual.gradient.last ?? "#224CFF"
            return dark ? .init("#0E0B16", "#0B0B0D", glows: [tint, accent], ink: tint, accent: accent)
                        : .init("#F5F3FB", "#F7F7FA", glows: [tint, accent], ink: tint, accent: accent)
        case (.city, true): return .init("#0A1122", "#070B16", glows: ["#2B5BFF", "#FF9E3D"], ink: "#8FB2FF", accent: "#FFC857")
        case (.city, false): return .init("#EEF2FA", "#E2E8F5", glows: ["#6C8CFF", "#FFB866"], ink: "#3355AA", accent: "#D9921A")
        case (.nature, true): return .init("#07170F", "#050E09", glows: ["#1FA971", "#B6E36B"], ink: "#6FE0A6", accent: "#C8F08F")
        case (.nature, false): return .init("#EEF8F1", "#E0F0E5", glows: ["#5FD39A", "#C8EB8A"], ink: "#2E7D55", accent: "#6E9E2E")
        case (.coffee, true): return .init("#1A1009", "#0E0906", glows: ["#D08A3C", "#7A3E1D"], ink: "#E3B887", accent: "#A8683A")
        case (.coffee, false): return .init("#FBF4EA", "#F1E3D0", glows: ["#E9B77A", "#C98A5A"], ink: "#8B5A2B", accent: "#6B3E1E")
        case (.water, true): return .init("#04182A", "#03101B", glows: ["#1EC8E0", "#2B6BFF"], ink: "#7FE7F5", accent: "#B8F3FF")
        case (.water, false): return .init("#EAF7FB", "#D6ECF5", glows: ["#6FDDEB", "#7FA8FF"], ink: "#1B7A94", accent: "#2FA6C2")
        case (.night, true): return .init("#140829", "#07040F", glows: ["#FF3DA8", "#3DD9FF", "#7B4DFF"], ink: "#FFFFFF", accent: "#FFE08A")
        case (.night, false): return .init("#F1EBFB", "#E6DCF7", glows: ["#FF7AC4", "#7ADFFF", "#A98BFF"], ink: "#5B34B8", accent: "#C98A00")
        case (.campus, true): return .init("#0C1226", "#080C1A", glows: ["#4F74FF", "#FF6B6B"], ink: "#7F9BFF", accent: "#FF7A7A")
        case (.campus, false): return .init("#FBFAF3", "#F1F0E4", glows: ["#9DB4FF", "#FFB0B0"], ink: "#4F74D9", accent: "#E05252")
        case (.contours, true): return .init("#12130B", "#0A0A06", glows: ["#C9A227", "#5E8C3A"], ink: "#E3CD83", accent: "#F2E3A6")
        case (.contours, false): return .init("#F7F3E6", "#ECE5CF", glows: ["#E3C766", "#A9C98A"], ink: "#8A7432", accent: "#5C4B1C")
        }
    }
}

/// Conversation backdrop: the style's own gradient and glows, and its motif drawn over them.
/// Static geometry, rasterized once, so it costs nothing while scrolling.
struct ChatBackground: View, Equatable {
    let seed: String
    var backdrop = ChatBackdrop(style: .classic)
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: ChatBackground, rhs: ChatBackground) -> Bool {
        lhs.seed == rhs.seed && lhs.backdrop == rhs.backdrop
    }

    var body: some View {
        let visual = CardVisual(seed: seed)
        let dark = colorScheme == .dark
        let palette = backdrop.signature.map { BackdropPalette.of($0, dark: dark) }
            ?? BackdropPalette.of(backdrop.style, dark: dark, visual: visual)
        ZStack {
            LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                ChatPattern(style: backdrop.style, hash: visual.hash, size: size, palette: palette, dark: dark,
                            signature: backdrop.signature).draw(in: &context)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The motifs. Deterministic per conversation (a seeded generator), so a chat always looks the
/// same.
private struct ChatPattern {
    let style: ChatBackdropStyle
    let hash: UInt32
    var size: CGSize
    let palette: BackdropPalette
    let dark: Bool
    /// The automatic backdrop's encounter signature: density, tilt and the path you've taken.
    var signature: EncounterSignature?

    /// Motif density: sparse for quiet, still moments; dense for loud, moving ones.
    private var density: CGFloat { signature.map { 0.75 + 0.6 * CGFloat($0.energy) } ?? 1 }

    /// SplitMix64: tiny, stable across launches (unlike `Hasher`).
    private struct Generator {
        var state: UInt64
        mutating func next() -> CGFloat {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
        }
        mutating func next(_ range: ClosedRange<CGFloat>) -> CGFloat { range.lowerBound + next() * (range.upperBound - range.lowerBound) }
        mutating func point(in size: CGSize) -> CGPoint { CGPoint(x: next(0...size.width), y: next(0...size.height)) }
    }

    /// Light palettes need a little more ink for the same presence.
    private func ink(_ alpha: Double) -> GraphicsContext.Shading { .color(palette.ink.opacity(dark ? alpha : alpha * 1.3)) }
    private func accent(_ alpha: Double) -> GraphicsContext.Shading { .color(palette.accent.opacity(dark ? alpha : alpha * 1.3)) }
    private func line(_ width: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }

    func draw(in context: inout GraphicsContext) {
        var random = Generator(state: UInt64(hash) &* 2654435761 &+ UInt64(style.rawValue.count))
        drawGlows(&context, random: &random)
        guard let signature else { return drawMotif(&context, random: &random) }
        // Tilted by the wind: drawn over the square that covers the screen at any angle.
        let side = hypot(size.width, size.height)
        var tilted = context
        tilted.translateBy(x: size.width / 2, y: size.height / 2)
        tilted.rotate(by: .radians(sin(signature.tilt) * 0.35))
        tilted.translateBy(x: -side / 2, y: -side / 2)
        var square = self
        square.size = CGSize(width: side, height: side)
        square.drawMotif(&tilted, random: &random)
        drawPath(&context, signature.path)
    }

    private func drawMotif(_ context: inout GraphicsContext, random: inout Generator) {
        switch style {
        case .classic: drawClassic(&context)
        case .city: drawCity(&context, random: &random)
        case .nature: drawNature(&context, random: &random)
        case .coffee: drawCoffee(&context, random: &random)
        case .water: drawWater(&context, random: &random)
        case .night: drawNight(&context, random: &random)
        case .campus: drawCampus(&context, random: &random)
        case .contours: drawContours(&context, random: &random)
        }
    }

    /// The places you've met, joined in order like a constellation (one place: ripples).
    private func drawPath(_ context: inout GraphicsContext, _ path: [CGPoint]) {
        let points = path.map { CGPoint(x: size.width * (0.14 + 0.72 * $0.x), y: size.height * (0.22 + 0.5 * $0.y)) }
        guard let first = points.first else { return }
        if points.count == 1 {
            for (index, radius) in [16, 34, 58, 88, 124].enumerated() {
                let r = CGFloat(radius)
                context.stroke(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)),
                               with: accent(0.32 - Double(index) * 0.055), style: line(1.5))
            }
        } else {
            var trail = Path()
            trail.move(to: first)
            for (previous, point) in zip(points, points.dropFirst()) {
                let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                trail.addQuadCurve(to: point, control: CGPoint(x: middle.x + (point.y - previous.y) * 0.2, y: middle.y - (point.x - previous.x) * 0.2))
            }
            context.stroke(trail, with: accent(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
        }
        for (index, point) in points.enumerated() {
            let r: CGFloat = index == 0 ? 5 : 3.5
            context.fill(Path(ellipseIn: CGRect(x: point.x - r * 2.2, y: point.y - r * 2.2, width: r * 4.4, height: r * 4.4)), with: accent(0.12))
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)), with: accent(0.6))
        }
    }

    /// Large soft color pools that give each style depth.
    private func drawGlows(_ context: inout GraphicsContext, random: inout Generator) {
        for (index, color) in palette.glows.enumerated() {
            let center = CGPoint(x: random.next(0...size.width), y: size.height * (index.isMultiple(of: 2) ? random.next(0...0.45) : random.next(0.5...1)))
            let radius = max(size.width, size.height) * random.next(0.45...0.7)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [color.opacity(dark ? 0.22 : 0.28), color.opacity(0)]),
                center: center, startRadius: 0, endRadius: radius))
        }
    }

    private func drawClassic(_ context: inout GraphicsContext) {
        var dots = Path()
        let spacing = 26 / density
        for (row, y) in stride(from: 0, to: size.height, by: spacing).enumerated() {
            for x in stride(from: row.isMultiple(of: 2) ? 0 : spacing / 2, to: size.width, by: spacing) {
                dots.addEllipse(in: CGRect(x: x, y: y, width: 2.2, height: 2.2))
            }
        }
        context.fill(dots, with: ink(0.16))
    }

    /// A night map: avenues and side streets, a diagonal boulevard, lit windows in the blocks.
    private func drawCity(_ context: inout GraphicsContext, random: inout Generator) {
        var streets = Path(), avenues = Path()
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var x = random.next(0...30)
        while x < size.width { xs.append(x); x += random.next(40...90) / density }
        var y = random.next(0...30)
        while y < size.height { ys.append(y); y += random.next(50...105) / density }
        for (index, x) in xs.enumerated() {
            var path = index % 3 == 1 ? avenues : streets
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            if index % 3 == 1 { avenues = path } else { streets = path }
        }
        for (index, y) in ys.enumerated() {
            var path = index % 3 == 2 ? avenues : streets
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            if index % 3 == 2 { avenues = path } else { streets = path }
        }
        let start = random.next(size.height * 0.1...size.height * 0.5)
        avenues.move(to: CGPoint(x: -10, y: start)); avenues.addLine(to: CGPoint(x: size.width + 10, y: start + size.width * 0.75))
        context.stroke(streets, with: ink(0.13), style: line(1))
        context.stroke(avenues, with: ink(0.2), style: line(3))
        // Lit windows: tiny squares clustered inside blocks.
        var windows = Path()
        for (i, x0) in xs.dropLast().enumerated() {
            for (j, y0) in ys.dropLast().enumerated() where random.next() < 0.45 {
                let x1 = xs[i + 1], y1 = ys[j + 1]
                for _ in 0..<Int(random.next(3...9)) {
                    windows.addRect(CGRect(x: random.next(x0 + 6...max(x0 + 7, x1 - 10)), y: random.next(y0 + 6...max(y0 + 7, y1 - 10)), width: 3, height: 4))
                }
            }
        }
        context.fill(windows, with: accent(0.3))
    }

    /// Scattered leaves (filled, with a midrib) and a few trailing vines.
    private func drawNature(_ context: inout GraphicsContext, random: inout Generator) {
        var vines = Path()
        for _ in 0..<3 {
            var point = CGPoint(x: random.next(0...size.width), y: -20)
            vines.move(to: point)
            while point.y < size.height + 20 {
                let next = CGPoint(x: point.x + random.next(-60...60), y: point.y + random.next(60...120))
                vines.addQuadCurve(to: next, control: CGPoint(x: point.x + random.next(-70...70), y: (point.y + next.y) / 2))
                point = next
            }
        }
        context.stroke(vines, with: ink(0.12), style: line(1.5))
        for cell in cells(spacing: 62, random: &random) {
            let length = random.next(12...30)
            let leaf = Path { leaf in
                leaf.move(to: CGPoint(x: 0, y: -length / 2))
                leaf.addQuadCurve(to: CGPoint(x: 0, y: length / 2), control: CGPoint(x: length * 0.5, y: 0))
                leaf.addQuadCurve(to: CGPoint(x: 0, y: -length / 2), control: CGPoint(x: -length * 0.5, y: 0))
            }
            var rib = Path()
            rib.move(to: CGPoint(x: 0, y: -length / 2)); rib.addLine(to: CGPoint(x: 0, y: length / 2 + 5))
            let transform = CGAffineTransform(translationX: cell.x, y: cell.y).rotated(by: random.next(0...(.pi * 2)))
            let shade = random.next() < 0.3 ? accent(0.16) : ink(0.12)
            context.fill(leaf.applying(transform), with: shade)
            context.stroke(rib.applying(transform), with: ink(0.24), style: line(1))
        }
    }

    /// Cup rings (uneven, some left open like real stains) and scattered beans.
    private func drawCoffee(_ context: inout GraphicsContext, random: inout Generator) {
        for cell in cells(spacing: 96, random: &random) {
            let radius = random.next(14...30)
            var ring = Path()
            let start = Angle(radians: Double(random.next(0...(.pi * 2))))
            ring.addArc(center: cell, radius: radius, startAngle: start, endAngle: start + .degrees(Double(random.next(250...360))), clockwise: false)
            context.stroke(ring, with: ink(0.18), style: line(random.next(1.5...3.5)))
            if random.next() < 0.4 {
                var inner = Path()
                inner.addEllipse(in: CGRect(x: cell.x - radius + 4, y: cell.y - radius + 4, width: (radius - 4) * 2, height: (radius - 4) * 2))
                context.stroke(inner, with: ink(0.1), style: line(1))
            }
            if random.next() < 0.6 {
                let bean = CGPoint(x: cell.x + random.next(-44...44), y: cell.y + random.next(-44...44))
                let transform = CGAffineTransform(translationX: bean.x, y: bean.y).rotated(by: random.next(0...(.pi)))
                context.fill(Path(ellipseIn: CGRect(x: -6, y: -8.5, width: 12, height: 17)).applying(transform), with: accent(0.3))
                var crease = Path()
                crease.move(to: CGPoint(x: 0, y: -7)); crease.addQuadCurve(to: CGPoint(x: 0, y: 7), control: CGPoint(x: 3.5, y: 0))
                context.stroke(crease.applying(transform), with: .color(palette.top.opacity(0.9)), style: line(1.2))
            }
        }
    }

    /// Layered swells (near ones bolder) with rising bubbles.
    private func drawWater(_ context: inout GraphicsContext, random: inout Generator) {
        for (row, y) in stride(from: CGFloat(16), to: size.height + 20, by: 26 / density).enumerated() {
            let phase = CGFloat(row) * 0.8 + random.next(0...1)
            let amplitude: CGFloat = row.isMultiple(of: 3) ? 7 : 4
            let wavelength: CGFloat = row.isMultiple(of: 2) ? 90 : 64
            var wave = Path()
            wave.move(to: CGPoint(x: 0, y: y + amplitude * sin(phase)))
            for x in stride(from: CGFloat(4), through: size.width + 4, by: 4) {
                wave.addLine(to: CGPoint(x: x, y: y + amplitude * sin(x / wavelength * .pi * 2 + phase)))
            }
            context.stroke(wave, with: ink(row.isMultiple(of: 3) ? 0.2 : 0.1), style: line(row.isMultiple(of: 3) ? 2 : 1))
        }
        for _ in 0..<Int(size.width * size.height / 9000) {
            let point = random.point(in: size), radius = random.next(2...6)
            context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                           with: accent(0.22), style: line(1))
        }
    }

    /// A starfield with sparkles and a crescent moon over neon glows.
    private func drawNight(_ context: inout GraphicsContext, random: inout Generator) {
        let count = Int(size.width * size.height / 1400 * density)
        var faint = Path(), bright = Path()
        for index in 0..<count {
            let point = random.point(in: size), radius = random.next(0.5...1.7)
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            if index % 5 == 0 { bright.addEllipse(in: rect) } else { faint.addEllipse(in: rect) }
        }
        context.fill(faint, with: ink(dark ? 0.3 : 0.18))
        context.fill(bright, with: ink(dark ? 0.7 : 0.35))
        var sparkles = Path()
        for _ in 0..<(count / 18) {
            let center = random.point(in: size), arm = random.next(4...9), waist = arm * 0.22
            sparkles.move(to: CGPoint(x: center.x, y: center.y - arm))
            sparkles.addQuadCurve(to: CGPoint(x: center.x + arm, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
            sparkles.addQuadCurve(to: CGPoint(x: center.x, y: center.y + arm), control: CGPoint(x: center.x + waist, y: center.y + waist))
            sparkles.addQuadCurve(to: CGPoint(x: center.x - arm, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
            sparkles.addQuadCurve(to: CGPoint(x: center.x, y: center.y - arm), control: CGPoint(x: center.x - waist, y: center.y - waist))
        }
        context.fill(sparkles, with: accent(0.55))
        let moon = CGPoint(x: random.next(size.width * 0.55...size.width * 0.85), y: random.next(size.height * 0.08...size.height * 0.2))
        var crescent = Path(ellipseIn: CGRect(x: moon.x - 26, y: moon.y - 26, width: 52, height: 52))
        crescent = crescent.subtracting(Path(ellipseIn: CGRect(x: moon.x - 14, y: moon.y - 34, width: 52, height: 52)))
        context.fill(crescent, with: accent(0.5))
    }

    /// Notebook paper: ruled lines, a red margin, and a few pencil doodles.
    private func drawCampus(_ context: inout GraphicsContext, random: inout Generator) {
        var rules = Path()
        for y in stride(from: CGFloat(28), to: size.height, by: 28) {
            rules.move(to: CGPoint(x: 0, y: y)); rules.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(rules, with: ink(0.2), style: line(1))
        var margin = Path()
        margin.move(to: CGPoint(x: 42, y: 0)); margin.addLine(to: CGPoint(x: 42, y: size.height))
        context.stroke(margin, with: accent(0.4), style: line(1.5))
        var holes = Path()
        for y in stride(from: size.height * 0.15, to: size.height, by: size.height * 0.3) {
            holes.addEllipse(in: CGRect(x: 14, y: y - 7, width: 14, height: 14))
        }
        context.stroke(holes, with: ink(0.3), style: line(1.2))
        var doodles = Path()
        for _ in 0..<Int(size.height / 110) {
            let at = CGPoint(x: random.next(70...max(71, size.width - 40)), y: random.next(20...size.height - 20))
            switch Int(random.next(0...2.99)) {
            case 0: // a five-point star
                for step in 0...5 {
                    let angle = CGFloat(step) * .pi * 4 / 5 - .pi / 2
                    let point = CGPoint(x: at.x + cos(angle) * 11, y: at.y + sin(angle) * 11)
                    if step == 0 { doodles.move(to: point) } else { doodles.addLine(to: point) }
                }
            case 1: // a loopy scribble
                doodles.move(to: at)
                for step in 1...24 {
                    let t = CGFloat(step) / 24 * .pi * 6
                    doodles.addLine(to: CGPoint(x: at.x + t * 4, y: at.y + sin(t) * 7))
                }
            default: // an arrow
                doodles.move(to: at); doodles.addLine(to: CGPoint(x: at.x + 34, y: at.y - 14))
                doodles.addLine(to: CGPoint(x: at.x + 24, y: at.y - 16))
                doodles.move(to: CGPoint(x: at.x + 34, y: at.y - 14)); doodles.addLine(to: CGPoint(x: at.x + 29, y: at.y - 5))
            }
        }
        context.stroke(doodles, with: ink(0.3), style: line(1.4))
    }

    /// Topographic swirls around a few summits, every fifth line bolder, peaks marked.
    private func drawContours(_ context: inout GraphicsContext, random: inout Generator) {
        var thin = Path(), bold = Path(), peaks = Path()
        for _ in 0..<3 {
            let center = random.point(in: size)
            let lobes = CGFloat(Int(random.next(2...5)))
            let phase = random.next(0...(.pi * 2))
            let wobble = random.next(0.1...0.2)
            for ring in 1...14 {
                let base = CGFloat(ring) * 17
                var path = Path()
                for step in 0...90 {
                    let angle = CGFloat(step) / 90 * .pi * 2
                    let radius = base * (1 + wobble * sin(angle * lobes + phase + CGFloat(ring) * 0.3))
                    let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.85)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                if ring.isMultiple(of: 5) { bold.addPath(path) } else { thin.addPath(path) }
            }
            peaks.move(to: CGPoint(x: center.x, y: center.y - 6))
            peaks.addLine(to: CGPoint(x: center.x + 6, y: center.y + 4))
            peaks.addLine(to: CGPoint(x: center.x - 6, y: center.y + 4))
            peaks.closeSubpath()
        }
        context.stroke(thin, with: ink(0.14), style: line(1))
        context.stroke(bold, with: ink(0.26), style: line(2))
        context.fill(peaks, with: accent(0.5))
    }

    /// A jittered grid of points (even coverage without looking tiled).
    private func cells(spacing base: CGFloat, random: inout Generator) -> [CGPoint] {
        let spacing = base / density
        var points: [CGPoint] = []
        for y in stride(from: spacing / 2, to: size.height + spacing, by: spacing) {
            for x in stride(from: spacing / 2, to: size.width + spacing, by: spacing) {
                points.append(CGPoint(x: x + random.next(-spacing * 0.3...spacing * 0.3), y: y + random.next(-spacing * 0.3...spacing * 0.3)))
            }
        }
        return points
    }
}

/// Picks a conversation's backdrop: Automatic (this connection's own, from how you met) or a
/// fixed style.
struct ChatBackdropPicker: View {
    let key: String
    let seed: String
    /// The automatic backdrop, when the encounters are known.
    let automatic: ChatBackdrop?

    private var backdrops: ChatBackdrops { .shared }

    var body: some View {
        let chosen = backdrops.choice(for: key)
        let auto = backdrops.automaticBackdrop(for: key, resolved: automatic)
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                tile("Automatic", subtitle: "Just yours", backdrop: auto, selected: chosen == nil) { backdrops.choose(nil, for: key) }
                ForEach(ChatBackdropStyle.allCases) { style in
                    tile(style.title, subtitle: nil, backdrop: ChatBackdrop(style: style), selected: chosen == style) { backdrops.choose(style, for: key) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func tile(_ title: String, subtitle: String?, backdrop: ChatBackdrop, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ClickHaptics.selection()
            withAnimation(ClickMotion.selection) { action() }
        } label: {
            VStack(spacing: 6) {
                ChatBackground(seed: seed, backdrop: backdrop)
                    .frame(width: 66, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? ClickColors.accentForeground : ClickColors.separator, lineWidth: selected ? 2 : ClickMetrics.strokeWidth)
                    }
                VStack(spacing: 0) {
                    Text(title).font(ClickTypography.caption).foregroundStyle(ClickColors.textPrimary)
                    if let subtitle { Text(subtitle).font(ClickTypography.caption).foregroundStyle(ClickColors.textTertiary) }
                }
                .lineLimit(1)
            }
            .frame(width: 74)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
