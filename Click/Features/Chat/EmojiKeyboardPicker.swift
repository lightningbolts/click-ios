import SwiftUI

/// The emoji catalog behind the "+" reaction picker.
///
/// Built once, off the main actor (`warmUp()` runs at launch), and shared: the picker sheet only
/// ever filters a prebuilt array, so opening it and typing a search never block the main thread.
/// (The old hidden-`UITextField` emoji-keyboard trick raced first-responder inside a transition
/// and could leave the screen frozen with no keyboard.)
public enum EmojiKeyboardPicker {
    public struct Entry: Hashable, Sendable {
        public let emoji: String
        public let name: String
        /// Lowercased once so search doesn't re-lowercase on every keystroke.
        let searchKey: String
    }

    /// Any emoji the keyboard can produce: single emoji, flags, keycaps, ZWJ sequences, skin tones.
    public nonisolated static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || character.unicodeScalars.contains { $0.value == 0xFE0F }
    }

    /// Code point blocks in roughly the system keyboard's order (smileys, people, nature, food,
    /// activities, travel, objects, symbols).
    private nonisolated static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F, 0x1FAE0...0x1FAFF,
        0x1F930...0x1F96F, 0x1F9B0...0x1F9FF, 0x1F440...0x1F4FF, 0x1FAC0...0x1FADF,
        0x1F300...0x1F43F, 0x1F980...0x1F9AF, 0x1FA70...0x1FABF,
        0x1F500...0x1F5FF, 0x1F680...0x1F6FF, 0x2600...0x27BF, 0x1F000...0x1F2FF, 0x2B00...0x2BFF
    ]

    private nonisolated static let catalog: [Entry] = {
        var seen = Set<String>()
        var results: [Entry] = []
        results.reserveCapacity(1_600)
        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                guard properties.isEmoji, !properties.isEmojiModifier,
                      !(0x1F1E6...0x1F1FF).contains(value) else { continue }
                // Text-default emoji (❤, ☺, ✈) need the variation selector to render as emoji.
                let emoji: String
                if properties.isEmojiPresentation {
                    emoji = String(Character(scalar))
                } else if value >= 0x2600 {
                    emoji = String(String.UnicodeScalarView([scalar, Unicode.Scalar(0xFE0F)!]))
                } else {
                    continue
                }
                guard seen.insert(emoji).inserted else { continue }
                let name = properties.name ?? ""
                results.append(Entry(emoji: emoji, name: name, searchKey: name.lowercased()))
            }
        }
        return results
    }()

    public nonisolated static func allEmoji() -> [Entry] { catalog }

    /// Builds the catalog in the background so the first "+" tap is instant.
    public static func warmUp() {
        Task.detached(priority: .utility) { _ = catalog.count }
    }

    nonisolated static func search(_ query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return catalog }
        return catalog.filter { $0.searchKey.contains(needle) }
    }
}

/// Recently used reactions, most recent first (per device).
enum RecentEmoji {
    private static let key = "click.emoji.recent"

    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ emoji: String) {
        var list = all.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(24)), forKey: key)
    }
}

/// Full emoji picker for reactions, presented as a native sheet.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [EmojiKeyboardPicker.Entry] = []
    @State private var recents: [String] = RecentEmoji.all

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    if query.isEmpty, !recents.isEmpty {
                        Section {
                            ForEach(recents, id: \.self) { cell($0) }
                        } header: { header("Recently used") }
                    }
                    Section {
                        ForEach(results, id: \.emoji) { cell($0.emoji) }
                    } header: {
                        if query.isEmpty { header("All emoji") }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .overlay {
                if results.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let current = query
            let found = await Task.detached(priority: .userInitiated) { EmojiKeyboardPicker.search(current) }.value
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(ClickTypography.metadataEmphasized)
            .foregroundStyle(ClickColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func cell(_ emoji: String) -> some View {
        Button {
            ClickHaptics.impact(.light)
            RecentEmoji.record(emoji)
            onPick(emoji)
            dismiss()
        } label: {
            Text(emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(emoji)
    }
}
