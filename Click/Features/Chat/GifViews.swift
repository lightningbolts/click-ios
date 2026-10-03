import SwiftUI

// MARK: - Bubble

/// A GIF message: KLIPY media loaded straight from its URL, in a box sized from the sender's
/// `metadata.gif` dimensions so the timeline doesn't jump when it loads.
struct GifMessageView: View {
    let gif: ChatGif

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    private static let maxSize = CGSize(width: 240, height: 320)

    private var size: CGSize {
        let scale = min(Self.maxSize.width / CGFloat(gif.width), Self.maxSize.height / CGFloat(gif.height))
        let fitted = CGSize(width: CGFloat(gif.width) * scale, height: CGFloat(gif.height) * scale)
        // Never a sliver: very wide or tall GIFs keep a usable minimum side.
        return CGSize(width: max(120, fitted.width), height: max(90, fitted.height))
    }

    var body: some View {
        ZStack {
            if let image {
                AnimatedImageView(image: image)
            } else if failed {
                Button {
                    failed = false
                    Task { await load() }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Couldn't load GIF. Tap to retry.")
                            .font(ClickTypography.metadata)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                    .padding(8)
                }
                .buttonStyle(.plain)
            } else {
                ShimmerPlaceholder()
            }
        }
        .frame(width: size.width, height: size.height)
        .background(ClickColors.fillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GIF")
        .task(id: gif.url) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        let loaded = await RemoteAnimatedImageLoader.shared.image(
            for: gif.url, maxPixelSize: max(size.width, size.height) * displayScale
        )
        if let loaded { image = loaded } else { failed = true }
    }
}

// MARK: - Picker

/// KLIPY GIF search. A blank query shows trending; results keep KLIPY's order (a KLIPY
/// integration requirement), and the search prompt reads "Search KLIPY" (required attribution).
struct GifPickerSheet: View {
    let onPick: (ChatGif) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [KlipyClient.Item] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var error: String?

    private let client = KlipyClient()
    private let customerID: String

    init(userID: String, onPick: @escaping (ChatGif) -> Void) {
        self.customerID = KlipyClient.customerID(userID: userID)
        self.onPick = onPick
    }

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error, items.isEmpty {
                    ContentUnavailableView {
                        Label("No GIFs", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load(reset: true) } }
                    }
                    .padding(.top, 40)
                } else if items.isEmpty && !isLoading {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(items) { item in
                            Button { pick(item) } label: { GifPickerCell(item: item) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.title)
                                .onAppear {
                                    if item.id == items.last?.id, hasNext, !isLoading {
                                        Task { await load(reset: false) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                if isLoading {
                    ClickLoadingView(size: 28, fillsSpace: false)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search KLIPY")
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text("Powered by KLIPY")
                    .font(ClickTypography.caption)
                    .foregroundStyle(ClickColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .task(id: query) {
                // Debounce typing; the first (trending) load starts at once.
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }
                await load(reset: true)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func load(reset: Bool) async {
        let nextPage = reset ? 1 : page + 1
        let requestedQuery = query
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.gifs(query: requestedQuery, page: nextPage, customerID: customerID)
            guard requestedQuery == query else { return }
            // Pages can repeat an item; keep the first so grid identities stay unique.
            let known = reset ? Set<String>() : Set(items.map(\.id))
            let fresh = result.items.filter { !known.contains($0.id) }
            items = reset ? result.items : items + fresh
            page = result.page
            hasNext = result.hasNext
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            if reset { items = [] }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't load GIFs. Try again."
        }
    }

    private func pick(_ item: KlipyClient.Item) {
        ClickHaptics.selection()
        client.triggerShare(slug: item.slug, customerID: customerID, query: query)
        onPick(ChatGif(url: item.send.url, width: item.send.width, height: item.send.height))
        dismiss()
    }
}

private struct GifPickerCell: View {
    let item: KlipyClient.Item

    @State private var image: UIImage?

    /// Grid previews decode fewer, smaller frames than bubbles (a screen holds many at once).
    private static let maxPixelSize: CGFloat = 240
    private static let maxFrames = 40

    var body: some View {
        Color.clear
            .aspectRatio(CGFloat(item.preview.width) / CGFloat(item.preview.height), contentMode: .fit)
            .overlay {
                if let image {
                    AnimatedImageView(image: image)
                } else {
                    ClickColors.fillSubtle
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
            .contentShape(Rectangle())
            .task(id: item.preview.url) {
                image = await RemoteAnimatedImageLoader.shared.image(
                    for: item.preview.url, maxPixelSize: Self.maxPixelSize, maxFrames: Self.maxFrames
                )
            }
    }
}
