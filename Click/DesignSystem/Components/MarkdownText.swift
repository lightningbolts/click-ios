import SwiftUI

/// Markdown as the web renders it (`EventMarkdownContent`): paragraphs, `#`–`###` headings,
/// bulleted and numbered lists and quotes, with inline bold, italics, code, strikethrough and
/// links. Body text takes the caller's font and color; headings stand out in the primary color.
struct MarkdownText: View {
    /// Only the source is stored, so the parse reruns only when the text itself changes.
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { index, block in
                view(for: block)
                    // Headings sit closer to what they introduce than to what came before.
                    .padding(.top, block.isHeading && index > 0 ? 6 : 0)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level))
                .foregroundStyle(ClickColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
        case .list(let items):
            // A grid keeps every item's text on one edge, however wide its marker ("9." vs "10.").
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(item.marker.map { "\($0)." } ?? "•")
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(item.marker == nil)
                        Text(item.text)
                    }
                }
            }
        case .quote(let text):
            Text(text)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(ClickColors.separator).frame(width: 3)
                }
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

/// One block of a markdown description. Blocks are split by blank lines, and again wherever a
/// list starts or stops ("**What to bring**" straight above its bullets).
enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        /// The number shown before a numbered item; nil for a bullet.
        let marker: Int?
        let text: AttributedString
    }

    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case list([ListItem])
    case quote(AttributedString)

    var isHeading: Bool {
        if case .heading = self { true } else { false }
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        // Paragraphs: lines between blank ones, however many blank lines there are.
        var paragraphs: [[Substring]] = [[]]
        for line in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.allSatisfy(\.isWhitespace) {
                paragraphs[paragraphs.count - 1].append(line)
            } else if !paragraphs[paragraphs.count - 1].isEmpty {
                paragraphs.append([])
            }
        }
        return paragraphs.filter { !$0.isEmpty }.flatMap(listRuns).flatMap(blocks)
    }

    // MARK: - Blocks

    private enum LineKind { case bullet, numbered, text }

    private static func kind(_ line: Substring) -> LineKind {
        if bulletItem(line) != nil { return .bullet }
        if numberedItem(line) != nil { return .numbered }
        return .text
    }

    /// Consecutive lines of the same kind (bullets, numbers, anything else).
    private static func listRuns(_ lines: [Substring]) -> [[Substring]] {
        var runs: [[Substring]] = []
        var previous: LineKind?
        for line in lines {
            let kind = kind(line)
            if kind != previous { runs.append([]) }
            runs[runs.count - 1].append(line)
            previous = kind
        }
        return runs
    }

    private static func blocks(_ lines: [Substring]) -> [MarkdownBlock] {
        let bullets = lines.compactMap(bulletItem)
        if bullets.count == lines.count {
            return [.list(bullets.map { ListItem(marker: nil, text: inline($0)) })]
        }
        let numbered = lines.compactMap(numberedItem)
        if numbered.count == lines.count {
            return [.list(numbered.map { ListItem(marker: $0.number, text: inline($0.text)) })]
        }
        let quoted = lines.compactMap(quotedLine)
        if quoted.count == lines.count {
            return [.quote(inline(quoted.joined(separator: "\n")))]
        }
        if let first = lines.first, let title = headingLine(first) {
            let heading = MarkdownBlock.heading(level: title.level, inline(title.text))
            let rest = lines.dropFirst()
            return rest.isEmpty ? [heading] : [heading, .paragraph(inline(rest.joined(separator: "\n")))]
        }
        return [.paragraph(inline(lines.joined(separator: "\n")))]
    }

    /// "- item", "* item" or "+ item".
    private static func bulletItem(_ line: Substring) -> Substring? {
        let line = line.drop(while: \.isWhitespace)
        guard let mark = line.first, "-+*".contains(mark) else { return nil }
        return afterSpace(line.dropFirst())
    }

    /// "3. item": the number stays, so a list can start anywhere.
    private static func numberedItem(_ line: Substring) -> (number: Int, text: Substring)? {
        let line = line.drop(while: \.isWhitespace)
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard let number = Int(digits), line.dropFirst(digits.count).first == ".",
              let text = afterSpace(line.dropFirst(digits.count + 1)) else { return nil }
        return (number, text)
    }

    /// "> quote", the space after the mark optional.
    private static func quotedLine(_ line: Substring) -> Substring? {
        let line = line.drop(while: \.isWhitespace)
        guard line.first == ">" else { return nil }
        let text = line.dropFirst()
        return text.first?.isWhitespace == true ? text.dropFirst() : text
    }

    /// "# Title" to "### Title".
    private static func headingLine(_ line: Substring) -> (level: Int, text: Substring)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level), let text = afterSpace(line.dropFirst(level)), !text.isEmpty else { return nil }
        return (level, text)
    }

    /// What follows a marker, which must be followed by at least one space.
    private static func afterSpace(_ text: Substring) -> Substring? {
        guard text.first?.isWhitespace == true else { return nil }
        return text.drop(while: \.isWhitespace)
    }

    // MARK: - Inline

    /// Links that leave the app go only to the web or mail, as on the web.
    private static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Inline formatting (emphasis, code, strikethrough, links), line breaks kept.
    static func inline<S: StringProtocol>(_ text: S) -> AttributedString {
        let source = String(text)
        guard var parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(source)
        }
        let unsafeLinks = parsed.runs.filter { run in
            run.link.map { !linkSchemes.contains($0.scheme?.lowercased() ?? "") } ?? false
        }
        for run in unsafeLinks { parsed[run.range].link = nil }
        return parsed
    }
}
