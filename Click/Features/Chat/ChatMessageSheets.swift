import SwiftUI

/// In-chat search over the decrypted, loaded timeline (spec §34). Stepping past the oldest match
/// loads the previous page and searches again.
struct ChatSearchBar: View {
    @Binding var query: String
    let matchCount: Int
    let position: Int?
    let canSearchOlder: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(ClickColors.textSecondary)
            TextField("Search this chat", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(onPrevious)
                .autocorrectionDisabled()
            Text(counter)
                .font(ClickTypography.caption)
                .foregroundStyle(ClickColors.textSecondary)
                .monospacedDigit()
                .fixedSize()
            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0 && !canSearchOlder)
                .accessibilityLabel("Older match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .disabled(position.map { $0 >= matchCount - 1 } ?? true)
                .accessibilityLabel("Newer match")
            Button("Done", action: onDone).font(ClickTypography.supportingEmphasized)
        }
        .font(ClickTypography.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ClickColors.surfaceElevated, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
        .onAppear { focused = true }
    }

    private var counter: String {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return "" }
        if matchCount == 0 { return canSearchOlder ? "Not loaded" : "No results" }
        return position.map { "\(matchCount - $0) of \(matchCount)" } ?? "\(matchCount)"
    }
}

/// "Who reacted": every reaction on a message with the people behind it.
struct ReactorsSheet: View {
    @Environment(AppEnvironment.self) private var env
    let reactions: [ReactionSummary]
    let initial: String
    let currentUserID: String
    @State private var people: [String: UserIdentity] = [:]
    @State private var selected: String

    init(reactions: [ReactionSummary], initial: String, currentUserID: String) {
        self.reactions = reactions
        self.initial = initial
        self.currentUserID = currentUserID
        _selected = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            List {
                if reactions.count > 1 {
                    Picker("Reaction", selection: $selected) {
                        ForEach(reactions) { Text("\($0.reactionType) \($0.count)").tag($0.reactionType) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                let ids = reactions.first { $0.reactionType == selected }?.userIDs ?? []
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 12) {
                        AvatarView(imageURL: people[id]?.avatarURL, seed: id, initials: String((people[id]?.name ?? "?").prefix(1)), size: 32)
                        Text(id == currentUserID ? "You" : people[id]?.name ?? "Click user")
                            .foregroundStyle(ClickColors.textPrimary)
                        Spacer()
                        Text(selected)
                    }
                }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            people = await env.identities.resolve(reactions.flatMap(\.userIDs))
        }
    }
}

/// "New messages" divider above the first message that was unread when the chat opened.
struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(ClickColors.accentForeground.opacity(0.4)).frame(height: 1)
            Text("New messages")
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .fixedSize()
            Rectangle().fill(ClickColors.accentForeground.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// New-Click panel: the 48-hour "say hi" warning (server deadline, never a local expiry) plus
/// icebreakers that send as ordinary messages (spec §42–43).
struct SayHiPanel: View {
    let deadline: Date?
    let context: String?
    let seed: String
    let onSend: (String) -> Void
    @State private var shuffle = 0
    @State private var cooldownUntil: Date?
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if let deadline, let remaining = InboxFormatting.sayHiRemaining(until: deadline) {
                        Label("Say hi · \(remaining) before this Click moves to Archived", systemImage: "hourglass")
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.warning)
                    } else {
                        Label("Break the ice", systemImage: "sparkles")
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    Spacer()
                    Button { withAnimation(ClickMotion.subtleFade) { dismissed = true } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ClickColors.textSecondary)
                    .accessibilityLabel("Hide icebreakers")
                }
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        ClickHaptics.impact(.light)
                        cooldownUntil = .now.addingTimeInterval(Icebreakers.cooldown)
                        onSend(prompt)
                    } label: {
                        Text(prompt)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends this message")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = cooldownUntil.map { Int($0.timeIntervalSince(context.date).rounded(.up)) } ?? 0
                    Button(wait > 0 ? "New ideas in \(wait)s" : "New ideas", systemImage: "arrow.triangle.2.circlepath") {
                        shuffle += 1
                        cooldownUntil = .now.addingTimeInterval(Icebreakers.cooldown)
                    }
                    .font(ClickTypography.supportingEmphasized)
                    .disabled(wait > 0)
                }
            }
            .padding(14)
            .background(ClickColors.surfaceElevated, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
            .transition(.opacity)
        }
    }

    private var prompts: [String] {
        Icebreakers.prompts(context: context, seed: "\(seed)#\(shuffle)")
    }
}

/// Small visual for the message a reply quotes: the photo itself, the event image, or a kind
/// icon for voice notes and files. Shared by bubble quotes and the composer's reply strip.
struct ReplyThumbnail: View {
    let target: ChatMessageItem
    var load: ((ChatMessageItem) async throws -> URL)?
    var size: CGFloat = 36
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let beacon = target.beacon {
                EventVisual(seed: beacon.beaconID, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: 6)
            } else if let media = target.media {
                switch media.kind {
                case .image:
                    if let image, !media.isLocked() {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        icon(media.isLocked() ? "hourglass" : "photo")
                    }
                case .audio: icon("mic.fill")
                case .file: icon("doc.fill")
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
        .task(id: target.id) {
            guard target.media?.kind == .image, target.media?.isLocked() == false, image == nil else { return }
            let url = target.localMediaURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            var file = url
            if file == nil, let load { file = try? await load(target) }
            guard let file else { return }
            let side = size * 3
            image = await Task.detached { UIImage(contentsOfFile: file.path)?.preparingThumbnail(of: CGSize(width: side, height: side)) }.value
        }
    }

    /// Whether the quoted message has anything visual to show.
    static func applies(to target: ChatMessageItem?) -> Bool {
        target?.beacon != nil || target?.media != nil
    }

    private func icon(_ name: String) -> some View {
        ZStack {
            ClickColors.fillSubtle
            Image(systemName: name).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(ClickColors.textSecondary)
        }
    }
}

/// Horizontal-only pan for swipe-to-reply. It begins only when the finger moves clearly
/// sideways, so vertical drags fall through to the timeline's scroll view; once it begins it
/// cancels touches underneath, so a swipe never also opens an attachment.
struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    var isEnabled = true
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .changed: onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed: onEnded()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}

/// "More reactions": a larger emoji set in a grid.
struct EmojiPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    static let emojis = [
        "👍", "❤️", "😂", "😮", "😢", "😡", "🔥", "🎉", "👏", "🙏", "😍", "🥰", "😎", "🤔", "😅", "🤣",
        "😭", "😬", "🙌", "💯", "✨", "👀", "🤝", "💪", "🥳", "😴", "🤯", "😇", "🫶", "👋", "✅", "❌",
        "☕️", "🍕", "🍻", "🎶", "⚽️", "🏀", "📍", "🌅", "💜", "💀", "🤷", "🙃", "😏", "🤩", "😳", "🫡"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 12) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button {
                            ClickHaptics.impact(.light)
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji).font(.system(size: 30))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
