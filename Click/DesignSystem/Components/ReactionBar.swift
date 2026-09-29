import SwiftUI

/// Tap an emoji to react, tap it again to take it back (Locket-style). Owners see who reacted
/// instead of the palette. Shared by soundtracks and shared drops.
struct ReactionBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let target: ReactionTarget
    let id: String

    @State private var state: ReactionsState?
    @State private var popped: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state {
                if !state.isOwner { palette(state) }
                if !state.reactions.isEmpty { reactors(state.reactions) }
                else if state.isOwner {
                    Text("No reactions yet").font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
                }
            }
        }
        .task(id: id) { state = try? await env.drops.reactions(target, id: id) }
    }

    private func palette(_ state: ReactionsState) -> some View {
        HStack(spacing: 6) {
            ForEach(ReactionsState.palette, id: \.self) { emoji in
                let chosen = state.mine == emoji
                Button {
                    Task { await react(chosen ? nil : emoji) }
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(chosen ? ClickColors.accentForeground.opacity(0.16) : ClickColors.fillSubtle,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .scaleEffect(popped == emoji ? 1.25 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React \(emoji)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    private func reactors(_ reactions: [ReactionsState.Reaction]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(reactions) { r in
                    HStack(spacing: 6) {
                        AvatarView(imageURL: r.avatarURL, seed: r.id, initials: Phase3Repository.initials(from: r.name), size: 24)
                        Text(r.name.split(separator: " ").first.map(String.init) ?? r.name)
                            .font(ClickTypography.metadataEmphasized).foregroundStyle(ClickColors.textSecondary)
                        Text(r.emoji)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func react(_ emoji: String?) async {
        let previous = state
        state?.mine = emoji
        ClickHaptics.selection()
        if let emoji, !reduceMotion {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { popped = emoji }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(ClickMotion.press) { popped = nil }
        }
        do {
            state = try await env.drops.react(target, id: id, emoji: emoji)
        } catch {
            if !error.isCancellation { state = previous }
        }
    }
}
