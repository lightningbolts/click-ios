import CoreLocation
import SwiftUI

/// Picks up to ten events and beacons to share into a chat. It looks and reads like Nearby
/// (same rows, grouped cards and in-place search), lists saved events first, and shows the
/// cards exactly as they will be sent before anything goes out.
struct BeaconSharePicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSend: ([MapBeacon]) -> Void

    static let maxSelection = 10

    @State private var sections: [ShareSection] = []
    @State private var origin: CLLocationCoordinate2D?
    @State private var loaded = false
    @State private var query = ""
    @FocusState private var isSearching: Bool
    /// In the order picked, which is the order they're sent in.
    @State private var selection: [MapBeacon] = []
    @State private var detent: PresentationDetent = .medium
    @State private var showingPreview = false

    struct ShareSection: Identifiable, Equatable {
        let id: String
        let title: String
        let beacons: [MapBeacon]
    }

    var body: some View {
        NavigationStack {
            list
                .safeAreaInset(edge: .bottom) { if !selection.isEmpty { previewBar } }
                .animation(ClickMotion.content, value: selection.isEmpty)
                .navigationTitle("Share Events")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
                .navigationDestination(isPresented: $showingPreview) {
                    BeaconSharePreview(selection: $selection) { beacons in
                        onSend(beacons)
                        dismiss()
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .task { await load() }
    }

    // MARK: List

    private var list: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = sections.compactMap { section -> ShareSection? in
            guard !search.isEmpty else { return section }
            let beacons = section.beacons.filter { Self.matches($0, search) }
            return beacons.isEmpty ? nil : ShareSection(id: section.id, title: section.title, beacons: beacons)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FilterSearchField(prompt: "Search events and beacons", text: $query, isFocused: $isSearching)
                    .padding(.bottom, 16)
                if !loaded {
                    placeholderRows
                } else if visible.isEmpty {
                    emptyState(search: search)
                        .padding(.top, 24)
                        .transition(.opacity)
                }
                ForEach(visible) { section in
                    Section {
                        ForEach(section.beacons) { beacon in
                            row(beacon, isFirst: beacon.id == section.beacons.first?.id, isLast: beacon.id == section.beacons.last?.id)
                        }
                    } header: {
                        Text(section.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ClickColors.textPrimary)
                            .padding(.horizontal, 4)
                            .padding(.top, section.id == visible.first?.id ? 0 : 20)
                            .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(ClickMotion.content, value: visible)
        }
        .scrollDismissesKeyboard(.interactively)
        .edgeFadeTop()
        .onChange(of: isSearching) { _, searching in
            // Room for results above the keyboard.
            if searching { detent = .large }
        }
    }

    private func row(_ beacon: MapBeacon, isFirst: Bool, isLast: Bool) -> some View {
        let isSelected = selection.contains { $0.id == beacon.id }
        let isFull = selection.count >= Self.maxSelection
        return Button { toggle(beacon) } label: {
            HStack(spacing: 0) {
                NearbyRow(item: MapItem(kind: .beacon(beacon)), origin: origin)
                SelectionMark(isSelected: isSelected)
                    .padding(.trailing, 16)
            }
            .opacity(isFull && !isSelected ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().padding(.leading, NearbyRow.thumbnailSize + 28) }
        }
        .groupedRowSlice(isFirst: isFirst, isLast: isLast)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Rows in the shape of what's coming, so the list settles in place instead of popping in.
    private var placeholderRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 14) {
                    ShimmerPlaceholder(cornerRadius: 14, width: NearbyRow.thumbnailSize, height: NearbyRow.thumbnailSize)
                    VStack(alignment: .leading, spacing: 8) {
                        ShimmerPlaceholder(cornerRadius: 4, width: 90, height: 10, animated: false)
                        ShimmerPlaceholder(cornerRadius: 5, width: 170, height: 14, animated: false)
                        ShimmerPlaceholder(cornerRadius: 4, width: 120, height: 10, animated: false)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .groupedRowSlice(isFirst: index == 0, isLast: index == 3)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    @ViewBuilder
    private func emptyState(search: String) -> some View {
        VStack(spacing: 6) {
            if search.isEmpty {
                Text("Nothing to share yet").font(ClickTypography.bodyEmphasized)
                Text("Events and beacons near you, and events you save, show up here.")
            } else {
                Text("No results for “\(search)”").font(ClickTypography.bodyEmphasized)
                Text("Try another name or place.")
            }
        }
        .font(ClickTypography.supporting)
        .foregroundStyle(ClickColors.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var previewBar: some View {
        Button {
            isSearching = false
            showingPreview = true
        } label: {
            Text("Preview · \(selection.count) of \(Self.maxSelection)")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .buttonStyle(.clickPrimary)
        .animation(ClickMotion.selection, value: selection.count)
        .padding(.horizontal, ClickSpacing.screenGutter)
        .padding(.vertical, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toggle(_ beacon: MapBeacon) {
        if let index = selection.firstIndex(where: { $0.id == beacon.id }) {
            ClickHaptics.selection()
            selection.remove(at: index)
        } else if selection.count < Self.maxSelection {
            ClickHaptics.selection()
            selection.append(beacon)
        } else {
            ClickHaptics.warning()
        }
    }

    static func matches(_ beacon: MapBeacon, _ query: String) -> Bool {
        [beacon.title, beacon.kind.label, beacon.locationName, beacon.formattedAddress, beacon.description]
            .compactMap { $0 }
            .contains { $0.localizedStandardContains(query) }
    }

    // MARK: Loading

    /// Everything on disk shows at once; saved events missing from it are fetched together and
    /// slot in when they arrive.
    private func load() async {
        guard let userID = env.session.currentSession?.userId else {
            loaded = true
            return
        }
        let beacons = env.beacons
        async let cachedDiscovery = beacons.cachedDiscovery(userID: userID)
        async let cachedSaved = beacons.cachedBookmarks(userID: userID)
        let discovery = await cachedDiscovery
        origin = discovery.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let nearby = discovery?.beacons.filter { $0.isActive() } ?? []
        var saved = Self.resolve(await cachedSaved ?? [], beacons: beacons)
        apply(nearby: nearby, saved: saved.found)

        // Fresh bookmarks, then any saved event not already in hand, fetched in parallel. Offline,
        // the cached Saved section stays.
        guard let bookmarks = try? await beacons.bookmarks(userID: userID) else { return }
        saved = Self.resolve(bookmarks, beacons: beacons)
        let fetched = await withTaskGroup(of: MapBeacon?.self) { group in
            for id in saved.missing.prefix(20) {
                group.addTask { try? await beacons.beacon(id: id).beacon }
            }
            var fetched: [String: MapBeacon] = [:]
            for await beacon in group {
                if let beacon { fetched[beacon.id] = beacon }
            }
            return fetched
        }
        let ordered = bookmarks.compactMap { event in
            saved.found.first { $0.id == event.beaconID } ?? fetched[event.beaconID]
        }
        apply(nearby: nearby, saved: ordered.filter { $0.isActive() })
    }

    /// Saved events whose full beacon is already cached, and the IDs of the rest.
    private static func resolve(_ events: [SavedEvent], beacons: BeaconRepository) -> (found: [MapBeacon], missing: [String]) {
        var found: [MapBeacon] = []
        var missing: [String] = []
        for event in events where event.isAvailable {
            if let cached = beacons.cachedBeacon(id: event.beaconID)?.beacon {
                if cached.isActive() { found.append(cached) }
            } else {
                missing.append(event.beaconID)
            }
        }
        return (found, missing)
    }

    private func apply(nearby: [MapBeacon], saved: [MapBeacon]) {
        let savedIDs = Set(saved.map(\.id))
        let rest = nearby.filter { !savedIDs.contains($0.id) }
        let events = rest.filter(\.isEvent)
            .sorted { ($0.schedule?.start ?? .distantFuture, $0.title) < ($1.schedule?.start ?? .distantFuture, $1.title) }
        let others = rest.filter { !$0.isEvent }
            .sorted { distance(to: $0) < distance(to: $1) }
        let next = [
            ShareSection(id: "saved", title: "Saved", beacons: saved),
            ShareSection(id: "events", title: "Events nearby", beacons: events),
            ShareSection(id: "beacons", title: "Beacons nearby", beacons: others)
        ].filter { !$0.beacons.isEmpty }
        withAnimation(ClickMotion.content) {
            sections = next
            loaded = true
        }
    }

    private func distance(to beacon: MapBeacon) -> Double {
        origin.map { MapFeatureModel.distanceMeters($0, beacon.coordinate) } ?? 0
    }
}

/// The picked cards as they'll appear in the chat, in send order; any can be dropped before
/// sending.
private struct BeaconSharePreview: View {
    @Binding var selection: [MapBeacon]
    let onSend: ([MapBeacon]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(selection) { beacon in
                    if let card = ConversationModel.beaconCard(beacon) {
                        BeaconMessageCard(beacon: card, time: nil, isOutgoing: true, onOpen: {})
                            .allowsHitTesting(false)
                            .overlay(alignment: .topTrailing) { removeButton(beacon) }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .animation(ClickMotion.content, value: selection.map(\.id))
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                ClickHaptics.success()
                onSend(selection)
            } label: {
                Text(selection.count == 1 ? "Send" : "Send \(selection.count)")
                    .monospacedDigit()
            }
            .buttonStyle(.clickPrimary)
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.vertical, 8)
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    private func removeButton(_ beacon: MapBeacon) -> some View {
        Button {
            ClickHaptics.selection()
            selection.removeAll { $0.id == beacon.id }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.55), in: Circle())
                .frame(width: ClickMetrics.minimumHitTarget, height: ClickMetrics.minimumHitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Remove \(beacon.title)")
    }
}

/// A row's selected state: an accent check, or an empty ring.
private struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ClickColors.textTertiary.opacity(0.6), lineWidth: 1.5)
                .opacity(isSelected ? 0 : 1)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(ClickColors.primaryActionForeground, ClickColors.accentForeground)
                .scaleEffect(isSelected ? 1 : 0.5)
                .opacity(isSelected ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .animation(ClickMotion.selection, value: isSelected)
        .accessibilityHidden(true)
    }
}
