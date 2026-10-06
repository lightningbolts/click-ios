import SwiftUI

/// Tap an emoji to react, tap it again to take it back (Locket-style); "+" picks any other emoji.
/// Owners see who reacted instead of the palette. Shared by soundtracks and shared drops.
///
/// The palette is one tray of plain emoji (only your pick is marked), and who else reacted is a
/// small stack of faces beside `accessory` (a drop's reply field) that opens the full list, so the
/// bar is the same height with or without reactions. Owners see the list itself, names included.
///
/// Reactions paint from the session cache on the first frame (shared drops arrive inline with the
/// strip), and a value that's under a minute old isn't fetched again.
struct ReactionBar<Accessory: View>: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let target: ReactionTarget
    let id: String
    /// What the caller already knows, so the palette is in place before reactions load (no pop-in).
    let isOwner: Bool
    /// True while the emoji picker or the list of who reacted is up, so a story can hold still.
    @Binding var presenting: Bool
    /// False until there's something to react to (a drop still developing): shown, not tappable.
    var reactable = true
    /// While a reply is typed, the palette and faces step aside so only `accessory` shows.
    var composing = false
    /// After a reaction is added (not taken back): a shared drop also answers in chat.
    var onReacted: ((String) -> Void)?
    /// Shown to non-owners under the palette, before the faces of who reacted.
    @ViewBuilder let accessory: Accessory

    @State private var state: ReactionsState?
    @State private var popped: String?
    @State private var pickingEmoji = false
    @State private var showingReactors = false

    private static var freshFor: TimeInterval { 60 }
    /// The palette tray's height: callers reserve it so nothing moves while reactions load.
    static var trayHeight: CGFloat { ReactionTray.height }

    init(target: ReactionTarget, id: String, isOwner: Bool, presenting: Binding<Bool> = .constant(false),
         reactable: Bool = true, composing: Bool = false,
         onReacted: ((String) -> Void)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.target = target
        self.id = id
        self.isOwner = isOwner
        self._presenting = presenting
        self.reactable = reactable
        self.composing = composing
        self.onReacted = onReacted
        self.accessory = accessory()
    }

    var body: some View {
        let shown = state ?? env.beaconExtras.cached(cacheKey)
        let reactions = shown?.reactions ?? []
        VStack(alignment: .leading, spacing: 12) {
            if shown?.isOwner ?? isOwner {
                if reactions.isEmpty {
                    Label("No reactions yet", systemImage: "heart")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .opacity(shown == nil ? 0 : 1)
                } else {
                    ReactorList(reactions: reactions)
                }
            } else {
                ReactionTray(mine: shown?.mine, popped: popped, onPick: { emoji in Task { await react(emoji) } },
                             onMore: { pickingEmoji = true })
                    .stepsAside(composing, interactive: reactable)
                if Accessory.self != EmptyView.self || !reactions.isEmpty {
                    HStack(spacing: 10) {
                        accessory
                        // Out of the way while typing, so the reply gets the whole row.
                        if !reactions.isEmpty, !composing {
                            ReactorFaces(reactions: reactions) { showingReactors = true }
                                .stepsAside(false, interactive: reactable)
                                .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .animation(ClickMotion.content, value: reactions)
        .animation(ClickMotion.subtleFade, value: composing)
        .sheet(isPresented: $pickingEmoji) {
            EmojiPickerSheet { emoji in Task { await react(emoji) } }
        }
        .sheet(isPresented: $showingReactors) {
            ReactorsListSheet(reactions: reactions)
        }
        .onChange(of: pickingEmoji || showingReactors) { _, up in presenting = up }
        .onDisappear { if pickingEmoji || showingReactors { presenting = false } }
        .task(id: id) {
            if state == nil { state = env.beaconExtras.cached(cacheKey) }
            guard !env.beaconExtras.isFresh(cacheKey, within: Self.freshFor) else { return }
            if let fresh = try? await env.beaconExtras.load(cacheKey, { try await env.drops.reactions(target, id: id) }) { state = fresh }
        }
    }

    private var cacheKey: String { BeaconExtrasCache.reactions(target, id) }

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

extension ReactionBar where Accessory == EmptyView {
    init(target: ReactionTarget, id: String, isOwner: Bool, onReacted: ((String) -> Void)? = nil) {
        self.init(target: target, id: id, isOwner: isOwner, onReacted: onReacted) { EmptyView() }
    }
}

private extension View {
    /// Hidden while a reply is typed; shown but untappable while not `interactive`.
    func stepsAside(_ hidden: Bool, interactive: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(interactive && !hidden)
            .accessibilityHidden(!interactive || hidden)
    }
}

/// The quick palette as one glass tray of plain emoji. Your reaction sits on a tinted disc; a
/// reaction picked from "+" takes the last slot (tap it to take it back).
private struct ReactionTray: View {
    static let height: CGFloat = 50

    let mine: String?
    let popped: String?
    let onPick: (String?) -> Void
    let onMore: () -> Void

    var body: some View {
        let custom = mine.flatMap { ReactionsState.palette.contains($0) ? nil : $0 }
        HStack(spacing: 0) {
            ForEach(ReactionsState.palette, id: \.self) { emoji in
                let chosen = mine == emoji
                slot(Text(emoji), chosen: chosen, popped: popped == emoji, label: "React \(emoji)") {
                    onPick(chosen ? nil : emoji)
                }
            }
            if let custom {
                slot(Text(custom), chosen: true, popped: popped == custom, label: "React \(custom)") { onPick(nil) }
            } else {
                slot(Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary),
                     chosen: false, popped: false, label: "More emoji", action: onMore)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Self.height)
        .glassCircleBackground()
        .animation(ClickMotion.selection, value: mine)
    }

    private func slot(_ face: some View, chosen: Bool, popped: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            face
                .font(.system(size: 26))
                .scaleEffect(popped ? 1.35 : (chosen ? 1.1 : 1))
                .frame(width: 40, height: 40)
                .background {
                    if chosen {
                        Circle()
                            .fill(ClickColors.accentForeground.opacity(0.3))
                            .overlay { Circle().strokeBorder(ClickColors.accentForeground.opacity(0.8), lineWidth: 1.5) }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Who else reacted, as a few overlapping faces with their emoji; tapping opens the full list.
private struct ReactorFaces: View {
    let reactions: [ReactionsState.Reaction]
    let action: () -> Void

    private static let size: CGFloat = 30

    var body: some View {
        let faces = Array(reactions.prefix(3))
        let emoji = reactions.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Button(action: action) {
            HStack(spacing: 6) {
                HStack(spacing: -Self.size / 3) {
                    ForEach(faces) { r in
                        AvatarView(imageURL: r.avatarURL, seed: r.id, initials: Phase3Repository.initials(from: r.name), size: Self.size)
                            .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1) }
                    }
                }
                Text(emoji.prefix(3).joined())
                    .font(.system(size: 15))
                    .fixedSize()
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: Self.size + 8)
            .glassCircleBackground()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reactions: " + reactions.map { "\($0.name) \($0.emoji)" }.joined(separator: ", "))
        .accessibilityHint("Shows who reacted.")
    }
}

/// Each person who reacted: a face with their emoji pinned to it and a first name, like a story's
/// viewer list.
private struct ReactorList: View {
    let reactions: [ReactionsState.Reaction]

    var body: some View {
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
}

/// Everyone who reacted, newest first.
private struct ReactorsListSheet: View {
    let reactions: [ReactionsState.Reaction]

    var body: some View {
        NavigationStack {
            List(reactions) { r in
                HStack(spacing: 12) {
                    AvatarView(imageURL: r.avatarURL, seed: r.id, initials: Phase3Repository.initials(from: r.name), size: 40)
                    Text(r.name)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(r.emoji).font(.system(size: 24))
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
