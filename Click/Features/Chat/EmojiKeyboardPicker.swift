import SwiftUI
import UIKit

/// Presents the system emoji keyboard; the first emoji typed becomes the reaction.
/// If the user has disabled the system emoji keyboard, falls back to a Unicode-generated emoji grid.
public struct EmojiKeyboardPicker: UIViewRepresentable {
    public let onPick: (String) -> Void

    public init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
    }

    public func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.tintColor = .clear
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    public func updateUIView(_ uiView: EmojiTextField, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    public final class Coordinator: NSObject, UITextFieldDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let emoji = string.first, emoji.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                onPick(String(emoji))
            }
            return false
        }
    }

    public static var hasSystemEmojiKeyboard: Bool {
        UITextInputMode.activeInputModes.contains { $0.primaryLanguage == "emoji" }
    }

    private static let cachedAllEmoji: [(emoji: String, name: String)] = {
        var results: [(emoji: String, name: String)] = []
        let ranges = [
            0x1F300...0x1FAFF,
            0x2600...0x27BF,
            0x1F000...0x1F2FF
        ]
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                if scalar.properties.isEmojiPresentation {
                    let character = Character(scalar)
                    let name = scalar.properties.name ?? ""
                    results.append((String(character), name))
                }
            }
        }
        return results
    }()

    public nonisolated static func allEmoji() -> [(emoji: String, name: String)] {
        cachedAllEmoji
    }
}

public final class EmojiTextField: UITextField {
    // Opens straight to the emoji keyboard.
    override public var textInputContextIdentifier: String? { "click.emoji" }
    override public var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

/// Fallback full emoji picker when the system emoji keyboard is not active in user settings.
public struct EmojiFallbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let onPick: (String) -> Void
    @State private var query = ""

    public init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
    }

    private var filtered: [(emoji: String, name: String)] {
        let all = EmojiKeyboardPicker.allEmoji()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let lower = trimmed.lowercased()
        return all.filter { $0.name.lowercased().contains(lower) }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 12) {
                    ForEach(filtered, id: \.emoji) { item in
                        Button {
                            ClickHaptics.impact(.light)
                            onPick(item.emoji)
                            dismiss()
                        } label: {
                            Text(item.emoji).font(.system(size: 30))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .searchable(text: $query, prompt: "Search emoji")
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
