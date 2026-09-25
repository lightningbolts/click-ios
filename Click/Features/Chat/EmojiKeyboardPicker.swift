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

    /// Any emoji the keyboard can produce: single emoji, flags, keycaps, ZWJ sequences, skin tones.
    public nonisolated static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || character.unicodeScalars.contains { $0.value == 0xFE0F }
    }

    public final class Coordinator: NSObject, UITextFieldDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let first = string.first, EmojiKeyboardPicker.isEmoji(first) {
                onPick(String(first))
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

/// Fallback full emoji picker panel when the system emoji keyboard is not active in user settings.
public struct EmojiFallbackPanel: View {
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
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ClickColors.textSecondary)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 12) {
                    ForEach(filtered, id: \.emoji) { item in
                        Button {
                            ClickHaptics.impact(.light)
                            onPick(item.emoji)
                        } label: {
                            Text(item.emoji).font(.system(size: 30))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(.regularMaterial)
        )
    }
}
