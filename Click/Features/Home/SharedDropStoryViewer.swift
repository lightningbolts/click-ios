import SwiftUI

/// Shared Click Drops, Instagram-story style: full screen, one drop after another with progress
/// segments, tap the sides to move, hold to pause, swipe down to close. A ready drop develops right
/// here, unveiling from its pixels. Replies and reactions go to your chat with the poster and
/// carry the drop with them; your own drops show who reacted instead.
struct SharedDropStoryViewer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentID: String
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var pressStart: Date?
    @State private var reply = ""
    @FocusState private var replyFocused: Bool
    /// Full-size photos for this viewing (tiles keep small copies).
    @State private var full: [String: UIImage] = [:]
    @State private var unveiled: Set<String> = []
    @State private var dragY: CGFloat = 0
    @State private var toast: String?
    @State private var confirmDelete = false
    @State private var reporting = false

    private static let secondsPerDrop: Double = 6

    init(startID: String) {
        _currentID = State(initialValue: startID)
    }

    private var store: SharedDropsStore { env.sharedDropsStore }
    private var sequence: [SharedDrop] { store.viewable }
    private var current: SharedDrop? { store.drop(currentID) }
    private func photo(_ id: String) -> UIImage? { full[id] ?? store.originals[id] }
    private var isPaused: Bool {
        holding || replyFocused || confirmDelete || reporting || !unveiled.contains(currentID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let drop = current {
                photoLayer(drop)
                    .padding(.top, 4)
                    .ignoresSafeArea(.keyboard)
                VStack(spacing: 0) {
                    header(drop)
                    Spacer(minLength: 0)
                    footer(drop)
                }
            }
        }
        .offset(y: dragY)
        .scaleEffect(1 - min(dragY, 400) / 2400)
        .simultaneousGesture(dismissDrag)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .clickToast($toast)
        .task(id: currentID) { await open(currentID) }
        .task(id: "\(currentID)|\(isPaused)") { await runTimer() }
        .onChange(of: current == nil) { _, gone in if gone { dismiss() } }
        .confirmation("Delete this drop?", isPresented: $confirmDelete, keep: "Keep It",
                      message: "It's removed for everyone it was shared with.") {
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
        .confirmationDialog("Report this photo?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Inappropriate", "Harassment", "Spam"], id: \.self) { reason in
                Button(reason) { Task { await report(reason) } }
            }
        } message: {
            Text("Reports go quietly to the Click team. Nobody else sees them.")
        }
    }

    // MARK: - Photo

    private func photoLayer(_ drop: SharedDrop) -> some View {
        let image = photo(drop.id)
        let shown = unveiled.contains(drop.id)
        return Color.clear
            .overlay {
                // Pixels underneath until the photo unveils over them.
                PixelatedPreview(url: drop.previewURL).opacity(shown ? 0 : 1)
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: shown ? 0 : 28)
                        .scaleEffect(shown ? 1 : 1.08)
                        .opacity(shown ? 1 : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottom) {
                if shown, let caption = drop.caption {
                    DropCaptionPill { Text(caption) }.padding(.bottom, 120)
                }
            }
            .overlay { if !shown { developingLabel(drop) } }
            .overlay { tapZones }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
            .accessibilityAction(named: "Next") { advance(1) }
            .accessibilityAction(named: "Previous") { advance(-1) }
    }

    private func developingLabel(_ drop: SharedDrop) -> some View {
        Label(store.developing.contains(drop.id) || drop.state() == .ready ? "Developing…" : "Opening…", systemImage: "sparkles")
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCircleBackground()
            .transition(.opacity)
    }

    /// A quick tap on the left third goes back, anywhere else forward; holding pauses.
    private var tapZones: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if pressStart == nil { pressStart = .now; holding = true }
                        }
                        .onEnded { value in
                            holding = false
                            let quick = Date().timeIntervalSince(pressStart ?? .now) < 0.25
                            pressStart = nil
                            guard quick, abs(value.translation.width) < 16, abs(value.translation.height) < 16 else { return }
                            if replyFocused { replyFocused = false; return }
                            advance(value.location.x < proxy.size.width / 3 ? -1 : 1)
                        }
                )
        }
    }

    // MARK: - Chrome

    private func header(_ drop: SharedDrop) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(sequence) { item in
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(.white).frame(width: proxy.size.width * fill(for: item))
                            }
                        }
                        .frame(height: 2.5)
                }
            }
            HStack(spacing: 10) {
                AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drop.isMine ? "Your drop" : drop.userName)
                        .font(ClickTypography.supportingEmphasized)
                    if let subtitle = subtitle(drop) {
                        Text(subtitle).font(ClickTypography.metadata).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if drop.isMine {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } else {
                        Button("Report", systemImage: "flag") { reporting = true }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("More")
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .shadow(color: .black.opacity(0.35), radius: 6)
    }

    private func fill(for item: SharedDrop) -> CGFloat {
        guard let mine = sequence.firstIndex(where: { $0.id == currentID }),
              let index = sequence.firstIndex(where: { $0.id == item.id }) else { return 0 }
        return index < mine ? 1 : (index == mine ? progress : 0)
    }

    private func subtitle(_ drop: SharedDrop) -> String? {
        guard let created = drop.createdAt else { return nil }
        let when = created.formatted(.relative(presentation: .named))
        guard drop.isMine, let audience = drop.audience else { return when }
        return when + (audience == .core ? " · Core connections" : " · All connections")
    }

    @ViewBuilder
    private func footer(_ drop: SharedDrop) -> some View {
        VStack(spacing: 14) {
            if unveiled.contains(drop.id) && !replyFocused {
                ReactionBar(target: .sharedDrop, id: drop.id, isOwner: drop.isMine) { emoji in
                    send(emoji, about: drop, reaction: true)
                }
                .id(drop.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !drop.isMine, drop.connectionID != nil {
                replyField(drop)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .animation(ClickMotion.content, value: replyFocused)
        .animation(ClickMotion.content, value: unveiled.contains(drop.id))
    }

    private func replyField(_ drop: SharedDrop) -> some View {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName
        return HStack(spacing: 10) {
            TextField("Reply to \(first)…", text: $reply, axis: .vertical)
                .lineLimit(1...4)
                .focused($replyFocused)
                .submitLabel(.send)
                .onSubmit { sendReply(drop) }
                .font(ClickTypography.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            if !trimmed.isEmpty {
                Button { sendReply(drop) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(ClickColors.primaryActionForeground)
                        .frame(width: 44, height: 44)
                        .glassCircleBackground(tint: ClickColors.primaryActionFill)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send reply")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .animation(ClickMotion.press, value: trimmed.isEmpty)
    }

    // MARK: - Flow

    private func open(_ id: String) async {
        progress = 0
        guard let drop = store.drop(id) else { return }
        if photo(id) != nil, !store.freshlyDeveloped.contains(id) { unveiled.insert(id) }
        if drop.state() == .ready { await store.develop([drop], fresh: true, env: env) }
        guard let latest = store.drop(id), latest.state() == .developed else { return }
        if full[id] == nil, let image = await store.fullImage(for: latest, env: env) { full[id] = image }
        reveal(id)
        prefetchNext(after: id)
    }

    /// The photo unveils from its pixels: a soft blur clearing as it settles (a cross-fade under
    /// Reduce Motion), with a haptic the first time a drop develops.
    private func reveal(_ id: String) {
        guard !unveiled.contains(id), photo(id) != nil else { return }
        let fresh = store.freshlyDeveloped.remove(id) != nil
        if fresh { ClickHaptics.impact(.medium) }
        withAnimation(fresh && !reduceMotion ? .easeOut(duration: 1.1) : ClickMotion.subtleFade) {
            _ = unveiled.insert(id)
        }
    }

    /// The next developed drop's photo is decoded before it's shown.
    private func prefetchNext(after id: String) {
        guard let index = sequence.firstIndex(where: { $0.id == id }), index + 1 < sequence.count else { return }
        let next = sequence[index + 1]
        guard next.state() == .developed, full[next.id] == nil else { return }
        Task {
            if let image = await store.fullImage(for: next, env: env) { full[next.id] = image }
        }
    }

    private func runTimer() async {
        guard !isPaused else { return }
        while !Task.isCancelled && progress < 1 {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            progress = min(1, progress + 0.05 / Self.secondsPerDrop)
        }
        if progress >= 1 { advance(1) }
    }

    private func advance(_ step: Int) {
        guard let index = sequence.firstIndex(where: { $0.id == currentID }) else { return dismiss() }
        let next = index + step
        if next >= sequence.count { return dismiss() }
        guard next >= 0 else { progress = 0; return }
        ClickHaptics.selection()
        currentID = sequence[next].id
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !replyFocused, value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = value.translation.height
                holding = true
            }
            .onEnded { value in
                holding = false
                if value.translation.height > 140 || value.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(ClickMotion.content) { dragY = 0 }
                }
            }
    }

    // MARK: - Replies

    private func sendReply(_ drop: SharedDrop) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        replyFocused = false
        send(text, about: drop, reaction: false)
    }

    /// Into the 1-1 chat with the poster, through the same optimistic pipeline as any message, so
    /// it's already there when that chat opens.
    private func send(_ text: String, about drop: SharedDrop, reaction: Bool) {
        guard let connectionID = drop.connectionID else { return }
        let route = DirectChatRoute(connectionID: connectionID, peerUserID: drop.userID,
                                    peerDisplayName: drop.userName, peerAvatarURL: drop.avatarURL)
        let model = env.conversationModel(for: route.conversationIdentity)
        Task { await model.sendDropReply(text, to: ChatDropReply(dropID: drop.id, isReaction: reaction)) }
        ClickHaptics.success()
        let first = drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName
        toast = reaction ? "Reaction sent to \(first)" : "Sent to \(first)"
    }

    private func delete() async {
        guard let drop = current else { return }
        do {
            try await env.drops.deleteSharedDrop(id: drop.id)
            store.remove(drop.id, env: env)
        } catch {
            if !error.isCancellation { toast = "Couldn't delete it. \(error.userFacingMessage)" }
        }
    }

    private func report(_ reason: String) async {
        guard let drop = current else { return }
        do {
            try await env.beacons.reportDrop(ClickDropRef(kind: .shared, id: drop.id), reason: reason)
            toast = "Thanks. The Click team will take a look."
        } catch {
            if !error.isCancellation { toast = "Couldn't send the report. \(error.userFacingMessage)" }
        }
    }
}
