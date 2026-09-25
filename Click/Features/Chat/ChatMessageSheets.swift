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
