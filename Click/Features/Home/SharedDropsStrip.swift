import SwiftUI

/// Shared Click Drops on Home (spec F3): one bounded strip — your recent drops and the ones your
/// connections shared with you — never a feed. No likes, views or counts. Ready and developed
/// drops open in the story viewer, where replies and reactions go to your chat with the poster.
struct SharedDropsStrip: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showingCamera = false
    @State private var captured: CapturedPhoto?
    @State private var viewing: ViewerStart?
    /// The story opens out of (and closes back into) the tapped tile.
    @State private var tileFrames = DropTileFrames()
    private var store: SharedDropsStore { env.sharedDropsStore }

    struct CapturedPhoto: Identifiable {
        let id = UUID()
        let jpeg: Data
    }

    struct ViewerStart: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionTitle("Click Drops").padding(.horizontal, 4)
            // Its own grouped card, like every other Home section; tiles scroll inside it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    shareTile
                    ForEach(store.uploads) { upload in
                        UploadingDropTile(jpeg: upload.jpeg, failed: upload.failed, size: Self.tileSize, cornerRadius: 16) {
                            Task { await store.retry(upload, env: env) }
                        }
                    }
                    ForEach(store.drops.value ?? []) { tile($0) }
                }
                .animation(ClickMotion.subtleFade, value: store.drops.value?.map(\.id))
                .padding(12)
            }
            .groupedSurface()
            if let message = store.message {
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary).padding(.horizontal, 4)
            }
        }
        .task {
            openRequestedCamera()
            await store.load(env: env)
            openPendingDrop()
        }
        .onChange(of: store.cameraRequested) { _, _ in openRequestedCamera() }
        // A "just developed" push opens that drop's story once it's in the strip.
        .onChange(of: env.pendingSharedDropID) { _, _ in openPendingDrop() }
        .onChange(of: store.drops.value?.map(\.id)) { _, _ in openPendingDrop() }
        // Live develop: a drop that reaches zero while the strip is on screen develops by itself.
        .task(id: nextReveal) {
            guard let next = nextReveal else { return }
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            let justReady = (store.drops.value ?? []).filter { $0.state() == .ready && ($0.revealAt.map { Date().timeIntervalSince($0) < 5 } ?? false) }
            await store.develop(justReady, env: env)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            ClickDropCameraView { draft in captured = CapturedPhoto(jpeg: draft.data) }
        }
        .sheet(item: $captured) { photo in
            SharedDropAudienceSheet(jpeg: photo.jpeg) { audience, caption in
                let upload = SharedDropsStore.PendingShare(jpeg: photo.jpeg, audience: audience, caption: caption)
                store.uploads.append(upload)
                Task { await store.share(upload, env: env) }
            }
            .presentationDetents([.large])
        }
        .dropViewer($viewing, sources: tileFrames)
    }

    private func openRequestedCamera() {
        guard store.cameraRequested else { return }
        store.cameraRequested = false
        showingCamera = true
    }

    private func openPendingDrop() {
        guard let id = env.pendingSharedDropID, viewing == nil, store.drop(id).map({ !$0.state().isPending }) == true else { return }
        env.pendingSharedDropID = nil
        ViewerStart.open(id, in: $viewing)
    }

    private var nextReveal: Date? {
        (store.drops.value ?? []).compactMap { drop in drop.state().isPending ? drop.revealAt : nil }.min()
    }

    // MARK: - Tiles

    private var shareTile: some View {
        Button {
            showingCamera = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClickColors.primaryActionForeground)
                    .frame(width: 40, height: 40)
                    .glassCircleBackground(tint: ClickColors.primaryActionFill)
                Text("Share a drop").font(ClickTypography.supportingEmphasized)
            }
            .foregroundStyle(ClickColors.textPrimary)
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .glassPanelBackground(cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Takes a photo that develops for your connections in an hour.")
    }

    private static let tileSize = CGSize(width: 104, height: 140)

    private func tile(_ drop: SharedDrop) -> some View {
        let state = drop.state()
        let developing = store.developing.contains(drop.id)
        return Button {
            if !state.isPending { ViewerStart.open(drop.id, in: $viewing) }
        } label: {
            // A fixed frame with overlays: a filling photo never pushes the labels out of the tile.
            Group {
                if state == .developed, let image = store.originals[drop.id] {
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
                        .transition(.opacity)
                } else {
                    PixelatedPreview(url: drop.previewURL).shimmering(developing)
                }
            }
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .overlay(alignment: .topTrailing) { badge(state: state).padding(6) }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 18)
                    Text(drop.isMine ? "You" : drop.userName.split(separator: " ").first.map(String.init) ?? drop.userName)
                        .font(ClickTypography.metadataEmphasized)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.leading, 3)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .glassCircleBackground()
                .padding(6)
            }
            .overlay {
                if state == .ready {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ClickColors.accentForeground, lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Glass over a photo reads as dark glass, so the white labels always hold.
            .environment(\.colorScheme, .dark)
            .animation(ClickMotion.reveal, value: store.originals[drop.id] != nil)
            .dropTileSource(drop.id, in: tileFrames)
        }
        .buttonStyle(.plain)
        .disabled(state.isPending)
        .accessibilityLabel(accessibility(drop, state: state))
    }

    /// Pending: a short countdown ("45m"). Ready: a sparkle to tap. Developed: nothing.
    @ViewBuilder
    private func badge(state: ClickDropDevelopState) -> some View {
        let content: (String?, String)? = switch state {
        case .pending(let reveal): (Self.shortCountdown(to: reveal), "hourglass")
        case .ready: (nil, "sparkles")
        case .developed: nil
        }
        if let content {
            HStack(spacing: 3) {
                Image(systemName: content.1)
                if let text = content.0 { Text(text).monospacedDigit() }
            }
            .font(ClickTypography.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassCircleBackground(tint: state == .ready ? ClickColors.primaryActionFill : nil)
        }
    }

    /// "5h", "20m", "<1m".
    static func shortCountdown(to date: Date, now: Date = .now) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes >= 60 { return "\(minutes / 60)h" }
        return minutes >= 1 ? "\(minutes)m" : "<1m"
    }

    private func accessibility(_ drop: SharedDrop, state: ClickDropDevelopState) -> String {
        let who = drop.isMine ? "Your drop" : "Drop from \(drop.userName)"
        switch state {
        case .pending(let reveal): return "\(who), develops \(reveal.formatted(.relative(presentation: .named)))"
        case .ready: return "\(who), ready to develop. Opens it."
        case .developed: return "\(who). Opens it."
        }
    }
}

/// A caption over a drop's photo, Locket-style: a glass pill at the bottom of the frame.
struct DropCaptionPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(ClickTypography.supportingEmphasized)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCircleBackground()
            .environment(\.colorScheme, .dark)
            .padding(12)
    }
}

/// Who a shared drop goes to (with the privacy difference from chat drops said plainly), and an
/// optional caption typed right on the photo.
struct SharedDropAudienceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let jpeg: Data
    let onShare: (SharedDrop.Audience, String?) -> Void
    @State private var audience: SharedDrop.Audience = .all
    @State private var caption = ""
    @State private var photo: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Color.clear
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay { if let photo { Image(uiImage: photo).resizable().scaledToFill() } }
                        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
                        .overlay(alignment: .bottom) {
                            DropCaptionPill {
                                // One line (Return ends editing), capped at the limit, cleaned once as it's set.
                                TextField("Add a caption", text: Binding(
                                    get: { caption },
                                    set: { caption = String($0.replacingOccurrences(of: "\n", with: "").prefix(SharedDrop.captionLimit)) }
                                ), axis: .vertical)
                                    .lineLimit(1...3)
                                    .submitLabel(.done)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if caption.count > SharedDrop.captionLimit - 20 {
                                Text("\(SharedDrop.captionLimit - caption.count)")
                                    .font(ClickTypography.caption.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .accessibilityLabel("\(SharedDrop.captionLimit - caption.count) characters left")
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Picker("Share with", selection: $audience) {
                    Text("All connections").tag(SharedDrop.Audience.all)
                    Text("Core connections").tag(SharedDrop.Audience.core)
                }
                .pickerStyle(.inline)
                Section {
                    Text("It develops for them in an hour, like a story. Shared drops aren't end-to-end encrypted like chats: only the people you pick can see them, and you can delete it anytime.")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
            .navigationTitle("Share drop")
            .navigationBarTitleDisplayMode(.inline)
            .task { photo = ClickDropService.thumbnail(jpeg, maxPixels: 1200) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") {
                        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                        onShare(audience, trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
        }
    }
}
