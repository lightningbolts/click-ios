import SwiftUI

/// A chat's backdrop pattern. Every style is a subtle, static line drawing over the dark chat
/// color, tinted by the conversation's seed colors.
enum ChatBackdropStyle: String, CaseIterable, Identifiable, Sendable {
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

/// Chosen and automatic backdrops by conversation key (connection ID, else chat ID), stored
/// on this device. The automatic style is remembered too, so a chat's first frame already has
/// its pattern (the encounter it comes from loads later).
@Observable
@MainActor
final class ChatBackdrops {
    static let shared = ChatBackdrops()

    private static let choicesKey = "click.chat.backdrops"
    private static let automaticKey = "click.chat.backdrops.automatic"

    private var choices: [String: String] = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: String] ?? [:]
    @ObservationIgnored private var automatic: [String: String] = UserDefaults.standard.dictionary(forKey: automaticKey) as? [String: String] ?? [:]

    /// The chosen style, or nil for automatic.
    func choice(for key: String) -> ChatBackdropStyle? {
        choices[key].flatMap(ChatBackdropStyle.init(rawValue:))
    }

    func choose(_ style: ChatBackdropStyle?, for key: String) {
        choices[key] = style?.rawValue
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
    }

    /// The automatic style; `resolved` (when the encounter is known) replaces the remembered one.
    func automaticStyle(for key: String, resolved: ChatBackdropStyle?) -> ChatBackdropStyle {
        guard let resolved else { return automatic[key].flatMap(ChatBackdropStyle.init(rawValue:)) ?? .classic }
        if automatic[key] != resolved.rawValue {
            automatic[key] = resolved.rawValue
            UserDefaults.standard.set(automatic, forKey: Self.automaticKey)
        }
        return resolved
    }

    func style(for key: String, resolved: ChatBackdropStyle?) -> ChatBackdropStyle {
        choice(for: key) ?? automaticStyle(for: key, resolved: resolved)
    }
}

/// Conversation backdrop: the chat color, a soft seed-tinted gradient, and the style's pattern.
/// Static geometry, rasterized once, so it costs nothing while scrolling.
struct ChatBackground: View, Equatable {
    let seed: String
    var style: ChatBackdropStyle = .classic

    nonisolated static func == (lhs: ChatBackground, rhs: ChatBackground) -> Bool {
        lhs.seed == rhs.seed && lhs.style == rhs.style
    }

    var body: some View {
        let visual = CardVisual(seed: seed)
        let tint = Color(hex: visual.gradient.first ?? "#5A00C6")
        let accent = Color(hex: visual.gradient.last ?? "#224CFF")
        ZStack {
            ClickColors.chatBackground
            LinearGradient(
                colors: [tint.opacity(0.10), .clear, accent.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                ChatPattern(style: style, hash: visual.hash, size: size).draw(in: &context, ink: tint)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The line drawings. Deterministic per conversation (a seeded generator), so a chat always
/// looks the same.
private struct ChatPattern {
    let style: ChatBackdropStyle
    let hash: UInt32
    let size: CGSize

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
    }

    func draw(in context: inout GraphicsContext, ink: Color) {
        var random = Generator(state: UInt64(hash))
        let line = GraphicsContext.Shading.color(ink.opacity(0.09))
        let fill = GraphicsContext.Shading.color(ink.opacity(0.08))
        let stroke = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        var path = Path()

        switch style {
        case .classic:
            // Sparse, offset dot lattice.
            for (row, y) in stride(from: 0, to: size.height, by: 28).enumerated() {
                for x in stride(from: row.isMultiple(of: 2) ? 0 : 14, to: size.width, by: 28) {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
            context.fill(path, with: fill)
            return

        case .city:
            // A street map: uneven blocks and one avenue across.
            var x: CGFloat = random.next(0...40)
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                x += random.next(44...96)
            }
            var y: CGFloat = random.next(0...40)
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                y += random.next(52...110)
            }
            let start = random.next(0...size.height * 0.5)
            path.move(to: CGPoint(x: 0, y: start)); path.addLine(to: CGPoint(x: size.width, y: start + size.width * 0.7))

        case .nature:
            // Scattered leaves: two arcs and a midrib, at random turns.
            for cell in cells(spacing: 74, random: &random) {
                let length = random.next(14...24)
                let leaf = Path { leaf in
                    leaf.move(to: CGPoint(x: 0, y: -length / 2))
                    leaf.addQuadCurve(to: CGPoint(x: 0, y: length / 2), control: CGPoint(x: length * 0.45, y: 0))
                    leaf.addQuadCurve(to: CGPoint(x: 0, y: -length / 2), control: CGPoint(x: -length * 0.45, y: 0))
                    leaf.move(to: CGPoint(x: 0, y: -length / 2)); leaf.addLine(to: CGPoint(x: 0, y: length / 2 + 4))
                }
                path.addPath(leaf, transform: CGAffineTransform(translationX: cell.x, y: cell.y).rotated(by: random.next(0...(.pi * 2))))
            }

        case .coffee:
            // Cup rings, a few doubled.
            for cell in cells(spacing: 92, random: &random) {
                let radius = random.next(10...24)
                path.addEllipse(in: CGRect(x: cell.x - radius, y: cell.y - radius, width: radius * 2, height: radius * 2))
                if random.next() < 0.35 {
                    let inner = radius - 3
                    path.addEllipse(in: CGRect(x: cell.x - inner, y: cell.y - inner, width: inner * 2, height: inner * 2))
                }
            }

        case .water:
            // Gentle swells, each row a little out of phase.
            for (row, y) in stride(from: CGFloat(18), to: size.height, by: 34).enumerated() {
                let phase = CGFloat(row) * 0.9 + random.next(0...1)
                path.move(to: CGPoint(x: 0, y: y + 5 * sin(phase)))
                for x in stride(from: CGFloat(6), through: size.width + 6, by: 6) {
                    path.addLine(to: CGPoint(x: x, y: y + 5 * sin(x / 60 * .pi * 2 + phase)))
                }
            }

        case .night:
            // Stars: small dots and a few four-point sparkles.
            let count = Int(size.width * size.height / 2600)
            var dots = Path()
            for _ in 0..<count {
                let r = random.next(0.6...1.6)
                dots.addEllipse(in: CGRect(x: random.next(0...size.width), y: random.next(0...size.height), width: r * 2, height: r * 2))
            }
            context.fill(dots, with: .color(ink.opacity(0.14)))
            for _ in 0..<(count / 14) {
                let center = CGPoint(x: random.next(0...size.width), y: random.next(0...size.height))
                let arm = random.next(4...7)
                path.move(to: CGPoint(x: center.x - arm, y: center.y)); path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - arm)); path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            }

        case .campus:
            // A ruled notebook page with its margin.
            for y in stride(from: CGFloat(30), to: size.height, by: 30) {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            var margin = Path()
            margin.move(to: CGPoint(x: 44, y: 0)); margin.addLine(to: CGPoint(x: 44, y: size.height))
            context.stroke(margin, with: .color(ink.opacity(0.16)), style: stroke)

        case .contours:
            // Topographic swirls around a few summits.
            for _ in 0..<3 {
                let center = CGPoint(x: random.next(0...size.width), y: random.next(0...size.height))
                let lobes = CGFloat(Int(random.next(2...5)))
                let phase = random.next(0...(.pi * 2))
                for ring in 1...9 {
                    let base = CGFloat(ring) * 22
                    for step in 0...72 {
                        let angle = CGFloat(step) / 72 * .pi * 2
                        let radius = base * (1 + 0.14 * sin(angle * lobes + phase + CGFloat(ring) * 0.35))
                        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
            }
        }
        context.stroke(path, with: line, style: stroke)
    }

    /// A jittered grid of points (even coverage without looking tiled).
    private func cells(spacing: CGFloat, random: inout Generator) -> [CGPoint] {
        var points: [CGPoint] = []
        for y in stride(from: spacing / 2, to: size.height + spacing, by: spacing) {
            for x in stride(from: spacing / 2, to: size.width + spacing, by: spacing) {
                points.append(CGPoint(x: x + random.next(-spacing * 0.3...spacing * 0.3), y: y + random.next(-spacing * 0.3...spacing * 0.3)))
            }
        }
        return points
    }
}

/// Picks a conversation's backdrop: Automatic (from where you met) or a fixed style.
struct ChatBackdropPicker: View {
    let key: String
    let seed: String
    /// The automatic style, when the encounter is known.
    let automatic: ChatBackdropStyle?

    private var backdrops: ChatBackdrops { .shared }

    var body: some View {
        let chosen = backdrops.choice(for: key)
        let auto = backdrops.automaticStyle(for: key, resolved: automatic)
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                tile("Automatic", subtitle: auto.title, style: auto, selected: chosen == nil) { backdrops.choose(nil, for: key) }
                ForEach(ChatBackdropStyle.allCases) { style in
                    tile(style.title, subtitle: nil, style: style, selected: chosen == style) { backdrops.choose(style, for: key) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func tile(_ title: String, subtitle: String?, style: ChatBackdropStyle, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ClickHaptics.selection()
            withAnimation(ClickMotion.selection) { action() }
        } label: {
            VStack(spacing: 6) {
                ChatBackground(seed: seed, style: style)
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
