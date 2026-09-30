import SwiftUI

/// Shared Click Drops on Home (spec F3): one bounded strip — your recent drops and the ones your
/// connections shared with you — never a feed. No likes, views or counts; replying opens the chat.
struct SharedDropsStrip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drops = ModuleState<[SharedDrop]>()
    /// Developed originals, by drop ID (loaded through develop-issued signed URLs).
    @State private var originals: [String: UIImage] = [:]
    @State private var developing: Set<String> = []
    @State private var showingCamera = false
    @State private var captured: CapturedPhoto?
    @State private var uploads: [PendingShare] = []
    @State private var viewing: SharedDrop?
    @State private var message: String?

    struct CapturedPhoto: Identifiable {
        let id = UUID()
        let jpeg: Data
    }

    struct PendingShare: Identifiable, Equatable {
        let id = UUID()
        let jpeg: Data
        let audience: SharedDrop.Audience
        let caption: String?
        var failed = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionTitle("Click Drops").padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    shareTile
                    ForEach(uploads) { uploadTile($0) }
                    ForEach(drops.value ?? []) { tile($0) }
                }
                .animation(ClickMotion.subtleFade, value: drops.value?.map(\.id))
                .padding(.horizontal, ClickSpacing.screenGutter)
            }
            .padding(.horizontal, -ClickSpacing.screenGutter)
            if let message {
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary).padding(.horizontal, 4)
            }
        }
        .task { await load() }
        // Every change to the strip is the next launch's first paint.
        .onChange(of: drops.value) { _, list in
            guard let list, let userID else { return }
            Task { await CacheStore.shared.save(list, key: Self.cacheKey, userID: userID) }
        }
        // Live develop: a drop that reaches zero while the strip is on screen develops by itself.
        .task(id: nextReveal) {
            guard let next = nextReveal else { return }
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            let justReady = (drops.value ?? []).filter { $0.state() == .ready && ($0.revealAt.map { Date().timeIntervalSince($0) < 5 } ?? false) }
            await develop(justReady)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            ClickDropCameraView { draft in captured = CapturedPhoto(jpeg: draft.data) }
        }
        .sheet(item: $captured) { photo in
            SharedDropAudienceSheet(jpeg: photo.jpeg) { audience, caption in
                let upload = PendingShare(jpeg: photo.jpeg, audience: audience, caption: caption)
                uploads.append(upload)
                Task { await share(upload) }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $viewing) { drop in
            SharedDropViewer(drop: drop, image: originals[drop.id], onDeleted: {
                drops.succeed((drops.value ?? []).filter { $0.id != drop.id })
            })
        }
    }

    private var nextReveal: Date? {
        (drops.value ?? []).compactMap { drop in drop.state().isPending ? drop.revealAt : nil }.min()
    }

    // MARK: - Tiles

    private var shareTile: some View {
        Button {
            showingCamera = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "camera").font(.system(size: 22))
                Text("Share a drop").font(ClickTypography.caption)
            }
            .foregroundStyle(ClickColors.textPrimary)
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ClickColors.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Takes a photo that develops for your connections in 24 hours.")
    }

    private static let tileSize = CGSize(width: 104, height: 140)

    private func tile(_ drop: SharedDrop) -> some View {
        let state = drop.state()
        return Button {
            switch state {
            case .ready: Task { await develop([drop]) }
            case .developed: viewing = drop
            case .pending: break
            }
        } label: {
            // A fixed frame with overlays: a filling photo never pushes the labels out of the tile.
            Group {
                if state == .developed, let image = originals[drop.id] {
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
                } else {
                    PixelatedPreview(url: drop.previewURL)
                }
            }
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .overlay(alignment: .topTrailing) { badge(for: drop, state: state).padding(6) }
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
                .background(.black.opacity(0.45), in: Capsule())
                .padding(6)
            }
            .overlay {
                if state == .ready {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ClickColors.accentForeground, lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.isPending || developing.contains(drop.id))
        .accessibilityLabel(accessibility(drop, state: state))
    }

    /// Pending: a short countdown ("5h"). Ready: a sparkle to tap. Developed: nothing.
    @ViewBuilder
    private func badge(for drop: SharedDrop, state: ClickDropDevelopState) -> some View {
        let content: (String?, String)? = switch state {
        case .pending(let reveal): (Self.shortCountdown(to: reveal), "hourglass")
        case .ready: (nil, "sparkles")
        case .developed: nil
        }
        if let content {
            HStack(spacing: 3) {
                if developing.contains(drop.id) {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: content.1)
                }
                if let text = content.0 { Text(text).monospacedDigit() }
            }
            .font(ClickTypography.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(state == .ready ? ClickColors.primaryActionFill : .black.opacity(0.45), in: Capsule())
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
        case .ready: return "\(who), ready to develop"
        case .developed: return "\(who). Opens the photo."
        }
    }

    private func uploadTile(_ upload: PendingShare) -> some View {
        ZStack {
            ClickColors.fillSubtle
            if upload.failed {
                Button {
                    Task { await retry(upload) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry").font(ClickTypography.caption)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sharing failed. Retry.")
            } else {
                ProgressView()
            }
        }
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Loading & writes

    private static let cacheKey = "shared-drops"
    private var userID: String? { env.session.currentSession?.userId }

    /// Paints the last strip (and its developed photos) from disk at once, then refreshes.
    private func load() async {
        if drops.value == nil, let userID, let cached = await CacheStore.shared.load([SharedDrop].self, key: Self.cacheKey, userID: userID) {
            drops.seed(cached)
            for drop in cached where drop.state() == .developed && originals[drop.id] == nil {
                originals[drop.id] = SharedDropPhotoCache.load(drop.id, userID: userID)
            }
        }
        drops.begin()
        do {
            let loaded = try await env.drops.sharedDrops()
            drops.succeed(loaded)
            if let userID { SharedDropPhotoCache.prune(keeping: Set(loaded.map(\.id)), userID: userID) }
            await loadOriginals(loaded.filter { $0.state() == .developed && originals[$0.id] == nil })
        } catch {
            if !error.isCancellation { drops.fail(error.userFacingMessage) }
        }
    }

    /// Developed drops need a fresh signed URL each visit; developing again is idempotent.
    private func loadOriginals(_ targets: [SharedDrop]) async {
        guard !targets.isEmpty, let results = try? await env.drops.develop(targets.map { ClickDropRef(kind: .shared, id: $0.id) })
        else { return }
        for result in results {
            guard let url = result.originalURL, let image = try? await ClickDropService.loadOriginal(url, maxPixels: 720) else { continue }
            keepOriginal(image, for: result.ref.id)
        }
    }

    private func keepOriginal(_ image: UIImage, for dropID: String) {
        originals[dropID] = image
        if let userID { SharedDropPhotoCache.save(image, dropID: dropID, userID: userID) }
    }

    private func develop(_ targets: [SharedDrop]) async {
        let ready = targets.filter { $0.state() == .ready && !developing.contains($0.id) }
        guard !ready.isEmpty else { return }
        developing.formUnion(ready.map(\.id))
        defer { developing.subtract(ready.map(\.id)) }
        do {
            let results = try await env.drops.develop(ready.map { ClickDropRef(kind: .shared, id: $0.id) })
            var updated = drops.value ?? []
            for result in results where result.status == .developed {
                if let url = result.originalURL, let image = try? await ClickDropService.loadOriginal(url, maxPixels: 720) {
                    if !reduceMotion { ClickHaptics.impact(.light) }
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ClickMotion.reveal) { keepOriginal(image, for: result.ref.id) }
                }
                if let index = updated.firstIndex(where: { $0.id == result.ref.id }) {
                    updated[index].developedAt = result.developedAt ?? .now
                }
            }
            withAnimation(ClickMotion.subtleFade) { drops.succeed(updated) }
        } catch {
            if !error.isCancellation { message = "Couldn't develop right now. Try again in a moment." }
        }
    }

    private func share(_ upload: PendingShare) async {
        do {
            let drop = try await env.drops.shareDrop(upload.jpeg, audience: upload.audience, caption: upload.caption, clientDropID: upload.id)
            uploads.removeAll { $0.id == upload.id }
            drops.succeed([drop] + (drops.value ?? []).filter { $0.id != drop.id })
            message = nil
            ClickHaptics.success()
        } catch let refusal as SharedDropPostError {
            uploads.removeAll { $0.id == upload.id }
            message = refusal.errorDescription
        } catch {
            guard !error.isCancellation else { return }
            if let index = uploads.firstIndex(where: { $0.id == upload.id }) { uploads[index].failed = true }
            message = "Couldn't share your drop. Tap Retry — it won't be shared twice."
        }
    }

    private func retry(_ upload: PendingShare) async {
        guard let index = uploads.firstIndex(where: { $0.id == upload.id }) else { return }
        uploads[index].failed = false
        await share(uploads[index])
    }
}

/// A caption over a drop's photo, Locket-style: a glass pill at the bottom of the frame.
private struct DropCaptionPill<Content: View>: View {
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
                    Text("It develops for them in 24 hours. Shared drops aren't end-to-end encrypted like chats: only the people you pick can see them, and you can delete it anytime.")
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

/// A developed shared drop: the photo, who shared it, and a reply that opens your chat with them.
struct SharedDropViewer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let drop: SharedDrop
    let image: UIImage?
    let onDeleted: () -> Void
    @State private var confirmDelete = false
    @State private var reporting = false
    @State private var notice: String?
    @State private var sharp: UIImage?

    private func caption(_ shared: Date) -> String {
        let when = "Shared \(shared.formatted(.relative(presentation: .named)))"
        guard let audience = drop.audience else { return when }
        return when + (audience == .core ? " · Core connections" : " · All connections")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = sharp ?? image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
                        .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
                        .overlay(alignment: .bottom) {
                            if let caption = drop.caption { DropCaptionPill { Text(caption) } }
                        }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                }
                if let shared = drop.createdAt {
                    Text(caption(shared))
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if image != nil { ReactionBar(target: .sharedDrop, id: drop.id, isOwner: drop.isMine) }
                if !drop.isMine, let connectionID = drop.connectionID {
                    Button {
                        dismiss()
                        env.router.navigate(to: .chat(DirectChatRoute(connectionID: connectionID, peerUserID: drop.userID,
                                                                     peerDisplayName: drop.userName, peerAvatarURL: drop.avatarURL)))
                    } label: {
                        Label("Reply to \(drop.userName)", systemImage: "bubble.left")
                            .font(ClickTypography.button)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClickColors.primaryActionFill)
                }
                if let notice { Text(notice).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary) }
                Spacer(minLength: 0)
            }
            .padding(16)
            // The strip holds a small thumbnail; the viewer shows the original at full size.
            .task(id: drop.id) {
                guard let url = try? await env.drops.develop([ClickDropRef(kind: .shared, id: drop.id)]).first?.originalURL else { return }
                sharp = try? await ClickDropService.loadOriginal(url)
            }
            .navigationTitle(drop.isMine ? "Your drop" : drop.userName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if drop.isMine {
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        } else {
                            Button("Report", systemImage: "flag") { reporting = true }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
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
    }

    private func delete() async {
        do {
            try await env.drops.deleteSharedDrop(id: drop.id)
            onDeleted()
            dismiss()
        } catch {
            if !error.isCancellation { notice = "Couldn't delete it. \(error.userFacingMessage)" }
        }
    }

    private func report(_ reason: String) async {
        do {
            try await env.beacons.reportDrop(ClickDropRef(kind: .shared, id: drop.id), reason: reason)
            notice = "Thanks. The Click team will take a look."
        } catch {
            if !error.isCancellation { notice = "Couldn't send the report. \(error.userFacingMessage)" }
        }
    }
}
