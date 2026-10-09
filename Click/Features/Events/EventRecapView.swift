import SwiftUI

/// The next-morning recap of an event's Click Drops (spec F1): a grid of every drop as it was
/// taken, and their story, the same one Home's drops play (person by person, yours first; tap to
/// develop, tap on, hold, swipe to the next person, down to close). It opens on the story while
/// you have drops still to develop, else on the grid; a tile opens the story there, and closing
/// it lands back on that tile. "Natural" shows every photo untouched in both. Bounded: the story
/// ends when the drops do.
struct EventRecapView: View {
    @Environment(AppEnvironment.self) private var env

    let beaconID: String

    @State private var model: EventRecapModel?
    @State private var viewing: RecapStory?
    @State private var tileFrames = DropTileFrames()
    /// Opened once, on arrival, when there's something new to see.
    @State private var startedStory = false

    struct RecapStory: Identifiable {
        let id: String
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ClickLoadingView()
            }
        }
        .navigationTitle(model?.state.value.map { $0.access == .absentee ? "What you missed" : $0.eventTitle } ?? "Recap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let model { toolbar(model) } }
        // Made on appear, so drops already cached paint on the first frame.
        .onAppear { if model == nil { model = EventRecapModel(beaconID: beaconID, env: env) } }
        .task(id: model == nil) { await model?.load() }
        .dropStory($viewing) { story in
            if let model { DropStoryViewer(source: model, startID: story.id, sources: tileFrames) }
        }
    }

    @ViewBuilder
    private func content(_ model: EventRecapModel) -> some View {
        if let current = model.state.value {
            if current.phase != .revealed {
                developing(current, model: model)
            } else if current.drops.isEmpty {
                ContentUnavailableView("No drops from this one", systemImage: "camera",
                                       description: Text("Nobody added photos to this event."))
            } else {
                grid(model)
                    .task { await openStoryOnArrival(model) }
            }
        } else if let error = model.state.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load the recap", systemImage: "exclamationmark.arrow.circlepath")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        } else {
            ClickLoadingView()
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: EventRecapModel) -> some ToolbarContent {
        if model.state.value?.phase == .revealed, !model.drops.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: Binding(get: { model.natural }, set: { model.natural = $0 })) {
                    Label("Natural", systemImage: "camera.filters")
                }
                .toggleStyle(.button)
                .accessibilityHint("Shows every photo without its look.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Play", systemImage: "play.fill") { play(model) }
                    .accessibilityLabel("Play the story")
            }
        }
    }

    private func developing(_ current: EventDropsState, model: EventRecapModel) -> some View {
        ContentUnavailableView {
            Label("Still developing", systemImage: "hourglass")
        } description: {
            if let reveal = current.revealAt {
                Text("Everyone's drops develop together \(EventDropsState.revealPhrase(reveal)).")
            } else {
                Text("Everyone's drops develop together tomorrow morning.")
            }
        }
        // Left open, it turns into the recap the moment the drops develop.
        .task(id: current.revealAt) {
            guard let reveal = current.revealAt else { return }
            try? await Task.sleep(for: .seconds(max(0, reveal.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }

    // MARK: - Grid

    private static let spacing: CGFloat = 4
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    private func grid(_ model: EventRecapModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(model.timeline) { drop in
                        RecapTile(model: model, drop: drop, frames: tileFrames) { viewing = RecapStory(id: drop.id) }
                            .id(drop.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Button("See who was there") { model.showPeople() }
                    .font(ClickTypography.supportingEmphasized)
                    .padding(.vertical, 20)
            }
            // The story's current drop stays in view underneath, so closing lands on its tile.
            .onChange(of: model.selectedID) { _, id in
                if let id, viewing != nil { proxy.scrollTo(id) }
            }
        }
        .background(ClickColors.background)
        .refreshable { await model.load() }
    }

    /// From the drop last shown, else where the first person's story starts.
    private func play(_ model: EventRecapModel) {
        let start = model.selectedID.flatMap { id in model.drops.contains { $0.id == id } ? id : nil }
            ?? model.chapterKeys.first.flatMap(model.chapterStart)
        if let start { viewing = RecapStory(id: start) }
    }

    /// With drops still to develop, the recap opens on its story, out of the first one's tile
    /// once the pushed screen has come to rest there.
    private func openStoryOnArrival(_ model: EventRecapModel) async {
        guard !startedStory, model.hasUndeveloped,
              let start = model.chapterKeys.first.flatMap(model.chapterStart) else { return }
        startedStory = true
        var last: CGRect?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            let frame = tileFrames.byID[start]
            if frame != nil, frame == last { break }
            last = frame
        }
        viewing = RecapStory(id: start)
    }
}

/// One drop in the grid: its photo once you've developed it (in its look, or natural), else
/// its pixels.
private struct RecapTile: View {
    let model: EventRecapModel
    let drop: EventDrop
    let frames: DropTileFrames
    let open: () -> Void

    var body: some View {
        let developed = model.isDeveloped(drop.id)
        let photo = model.thumb(drop.id)
        Button(action: open) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let photo {
                        Image(uiImage: model.image(photo)).resizable().scaledToFill().transition(.opacity)
                    } else {
                        PixelatedPreview(url: drop.previewURL)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !developed {
                        Image(systemName: "sparkles")
                            .font(ClickTypography.badge)
                            .foregroundStyle(.white)
                            .padding(5)
                            .glassCircleBackground(tint: ClickColors.primaryActionFill)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    AvatarView(imageURL: drop.avatarURL, seed: drop.userID, initials: Phase3Repository.initials(from: drop.userName), size: 22)
                        .padding(2)
                        .glassCircleBackground()
                        .padding(5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environment(\.colorScheme, .dark)
                .animation(ClickMotion.reveal, value: photo != nil)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .dropTileSource(drop.id, in: frames)
        }
        .buttonStyle(.plain)
        .task(id: developed) { if developed { await model.loadThumb(drop.id) } }
        .accessibilityLabel(drop.isMine ? "Your drop" : "Drop from \(drop.userName)")
        .accessibilityValue(developed ? "" : "Not developed")
    }
}
