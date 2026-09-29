import SwiftUI

/// Event Click Drops on an event's detail (spec F1): during the event, checked-in people add up to
/// ten photos that all develop together the next morning; afterwards, the recap. Everything shown
/// here is what the server says this viewer may see.
struct EventDropsSection: View {
    @Environment(AppEnvironment.self) private var env

    let beacon: MapBeacon

    @State private var state = ModuleState<EventDropsState>()
    @State private var showingCamera = false
    /// Uploads in flight or failed, newest last. A failed one keeps its photo and ID for a safe retry.
    @State private var uploads: [PendingUpload] = []
    @State private var confirmDelete: EventDrop?
    @State private var message: String?

    struct PendingUpload: Identifiable, Equatable {
        let id = UUID()
        let jpeg: Data
        var failed = false
    }

    var body: some View {
        Group {
            if let current = state.value, isRelevant(current) {
                content(current)
            } else if state.errorMessage != nil, state.value == nil {
                EmptyView()
            }
        }
        .task(id: beacon.id) { await load() }
        .fullScreenCover(isPresented: $showingCamera) {
            ClickDropCameraView(
                endsAt: state.value?.closesAt,
                subtitle: developsCaption(state.value?.revealAt),
                showsLooks: false
            ) { draft in
                let upload = PendingUpload(jpeg: draft.data)
                uploads.append(upload)
                Task { await send(upload) }
            }
        }
        .confirmation("Delete this drop?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                      keep: "Keep It") {
            Button("Delete", role: .destructive) {
                if let drop = confirmDelete { Task { await delete(drop) } }
            }
        }
    }

    /// Hidden entirely for people who weren't there and can't post (nothing to show them).
    private func isRelevant(_ current: EventDropsState) -> Bool {
        current.canPost || !current.drops.isEmpty || !uploads.isEmpty
            || (current.access != .none && current.phase == .revealed)
    }

    private func content(_ current: EventDropsState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(current.access == .absentee && current.phase == .revealed ? "What you missed" : "Click Drops")
                    .font(ClickTypography.sectionTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(caption(current))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            if current.phase == .revealed, !current.drops.isEmpty {
                Button {
                    env.router.navigate(to: .eventRecap(beaconID: beacon.id))
                } label: {
                    Label("Open the recap", systemImage: "sparkles")
                        .font(ClickTypography.button)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
            }

            if current.phase != .revealed, !current.myDrops.isEmpty || !uploads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(current.myDrops) { drop in
                            thumbnail(drop)
                        }
                        ForEach(uploads) { upload in
                            uploadTile(upload)
                        }
                    }
                }
            }

            if current.canPost {
                Button {
                    showingCamera = true
                } label: {
                    Label("Add a drop · \(current.remaining) left", systemImage: "camera")
                        .font(ClickTypography.supportingEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(ClickColors.separator, lineWidth: 1.5)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if !current.myDrops.isEmpty {
                Toggle("Show to people who RSVP'd but couldn't make it", isOn: Binding(
                    get: { state.value?.showToAbsentees ?? true },
                    set: { shown in Task { await setShownToAbsentees(shown) } }
                ))
                .font(ClickTypography.supporting)
                .tint(ClickColors.primaryActionFill)
            }

            if let message {
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
            }
        }
    }

    private func caption(_ current: EventDropsState) -> String {
        switch current.phase {
        case .before:
            return "Check in when it starts to add photos. They develop together the next morning."
        case .open:
            return developsCaption(current.revealAt) + (current.canPost ? "" : ". Check in to add yours.")
        case .developing:
            return developsCaption(current.revealAt)
        case .revealed:
            if current.access == .absentee { return "A few moments from the people who were there." }
            return current.drops.isEmpty ? "No drops from this one." : "Everyone's drops, developed."
        }
    }

    private func developsCaption(_ revealAt: Date?) -> String {
        guard let revealAt else { return "Develops tomorrow morning" }
        return "Develops \(revealAt.formatted(.relative(presentation: .named))) · \(revealAt.formatted(date: .omitted, time: .shortened))"
    }

    private func thumbnail(_ drop: EventDrop) -> some View {
        PixelatedPreview(url: drop.previewURL)
            .frame(width: 72, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = drop }
            }
            .accessibilityLabel("Your drop, developing")
            .accessibilityAction(named: "Delete") { confirmDelete = drop }
    }

    private func uploadTile(_ upload: PendingUpload) -> some View {
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
                .accessibilityLabel("Upload failed. Retry.")
            } else {
                ProgressView()
            }
        }
        .frame(width: 72, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Loading & writes

    private func load() async {
        state.begin()
        do {
            state.succeed(try await env.beacons.eventDrops(beaconID: beacon.id))
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    private func send(_ upload: PendingUpload) async {
        do {
            _ = try await env.beacons.postEventDrop(beaconID: beacon.id, clientDropID: upload.id, jpeg: upload.jpeg,
                                                    showToAbsentees: nil)
            uploads.removeAll { $0.id == upload.id }
            message = nil
            ClickHaptics.success()
            await load()
        } catch let refusal as EventDropPostError {
            uploads.removeAll { $0.id == upload.id }
            message = refusal.errorDescription
            await load()
        } catch {
            guard !error.isCancellation else { return }
            if let index = uploads.firstIndex(where: { $0.id == upload.id }) { uploads[index].failed = true }
            message = "Couldn't upload your drop. Tap Retry — it won't be added twice."
        }
    }

    private func retry(_ upload: PendingUpload) async {
        guard let index = uploads.firstIndex(where: { $0.id == upload.id }) else { return }
        uploads[index].failed = false
        await send(uploads[index])
    }

    private func delete(_ drop: EventDrop) async {
        do {
            try await env.beacons.deleteEventDrop(beaconID: beacon.id, dropID: drop.id)
            await load()
        } catch {
            if !error.isCancellation { message = "Couldn't delete the drop. \(error.userFacingMessage)" }
        }
    }

    private func setShownToAbsentees(_ shown: Bool) async {
        do {
            try await env.beacons.setEventDropsShownToAbsentees(beaconID: beacon.id, shown)
            await load()
        } catch {
            if !error.isCancellation { message = error.userFacingMessage }
        }
    }
}

/// A drop's server-pixelated preview (never the original), drawn with hard pixel edges.
struct PixelatedPreview: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            ClickColors.fillSubtle
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFill()
            } else if url != nil {
                ProgressView()
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            image = await ImagePipeline.shared.image(for: url, maxPixelSize: 480)
        }
    }
}
