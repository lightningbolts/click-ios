import SwiftUI

/// Tap an emoji to react, tap it again to take it back (Locket-style); "+" picks any other emoji.
/// Owners see who reacted instead of the palette. Shared by soundtracks and shared drops.
///
/// Reactions paint from the session cache on the first frame (shared drops arrive inline with the
/// strip), and a value that's under a minute old isn't fetched again.
struct ReactionBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let target: ReactionTarget
    let id: String
    /// What the caller already knows, so the palette is in place before reactions load (no pop-in).
    let isOwner: Bool
    /// After a reaction is added (not taken back): a shared drop also answers in chat.
    var onReacted: ((String) -> Void)? = nil

    @State private var state: ReactionsState?
    @State private var popped: String?
    @State private var pickingEmoji = false

    private static let freshFor: TimeInterval = 60

    var body: some View {
        let shown = state ?? env.beaconExtras.cached(cacheKey)
        VStack(alignment: .leading, spacing: 12) {
            if !(shown?.isOwner ?? isOwner) { palette(shown ?? .empty) }
            if let shown, !shown.reactions.isEmpty {
                reactors(shown.reactions)
            } else if shown?.isOwner ?? isOwner {
                Label("No reactions yet", systemImage: "heart")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .opacity(shown == nil ? 0 : 1)
            }
        }
        .animation(ClickMotion.content, value: shown?.reactions)
        .sheet(isPresented: $pickingEmoji) {
            EmojiPickerSheet { emoji in Task { await react(emoji) } }
        }
        .task(id: id) {
            if state == nil { state = env.beaconExtras.cached(cacheKey) }
            guard !env.beaconExtras.isFresh(cacheKey, within: Self.freshFor) else { return }
            if let fresh = try? await env.beaconExtras.load(cacheKey, { try await env.drops.reactions(target, id: id) }) { state = fresh }
        }
    }

    private var cacheKey: String { BeaconExtrasCache.reactions(target, id) }

    private func palette(_ state: ReactionsState) -> some View {
        // A reaction picked from "+" takes the last slot (tap it to take it back).
        let custom = state.mine.flatMap { ReactionsState.palette.contains($0) ? nil : $0 }
        return HStack(spacing: 0) {
            ForEach(ReactionsState.palette, id: \.self) { emoji in
                let chosen = state.mine == emoji
                emojiButton(Text(emoji), chosen: chosen, popped: popped == emoji, label: "React \(emoji)") {
                    Task { await react(chosen ? nil : emoji) }
                }
            }
            if let custom {
                emojiButton(Text(custom), chosen: true, popped: popped == custom, label: "React \(custom)") {
                    Task { await react(nil) }
                }
            } else {
                emojiButton(Image(systemName: "plus").font(.system(size: 20, weight: .semibold)), chosen: false, popped: false,
                            label: "More emoji") { pickingEmoji = true }
            }
        }
        .animation(ClickMotion.selection, value: state.mine)
    }

    private func emojiButton(_ face: some View, chosen: Bool, popped: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            face
                .font(.system(size: 26))
                .frame(width: 46, height: 46)
                .glassCircleBackground(tint: chosen ? ClickColors.accentForeground.opacity(0.35) : nil)
                .overlay { if chosen { Circle().strokeBorder(ClickColors.accentForeground, lineWidth: 2) } }
                .scaleEffect(popped ? 1.3 : (chosen ? 1.08 : 1))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Who reacted: each face with their emoji pinned to it, like a story's viewer list.
    private func reactors(_ reactions: [ReactionsState.Reaction]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(reactions) { r in
                    VStack(spacing: 5) {
                        AvatarView(imageURL: r.avatarURL, seed: r.id, initials: Phase3Repository.initials(from: r.name), size: 44)
                            .overlay(alignment: .bottomTrailing) {
                                Text(r.emoji)
                                    .font(.system(size: 17))
                                    .offset(x: 5, y: 4)
                            }
                        Text(r.name.split(separator: " ").first.map(String.init) ?? r.name)
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(width: 56)
                    .accessibilityElement(children: .combine)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func react(_ emoji: String?) async {
        let previous = state ?? env.beaconExtras.cached(cacheKey)
        var next = previous ?? .empty
        next.mine = emoji
        state = next
        ClickHaptics.selection()
        if let emoji, !reduceMotion {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { popped = emoji }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(ClickMotion.press) { popped = nil }
        }
        do {
            let saved = try await env.drops.react(target, id: id, emoji: emoji)
            state = saved
            env.beaconExtras.store(saved, for: cacheKey)
            if let emoji { onReacted?(emoji) }
        } catch {
            if !error.isCancellation { state = previous }
        }
    }
}
