import SwiftUI
import CoreLocation

/// The Map root's floating collapsed lip: tapping or dragging up presents the native Nearby sheet.
struct NearbyLip: View {
    @Bindable var model: MapFeatureModel
    let pins: [ConnectionPin]

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(ClickColors.textTertiary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nearby")
                        .font(ClickTypography.sectionTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text(model.summary(pins: pins))
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.locationState == .notDetermined {
                    Button("Turn on") { Task { await model.requestLocation() } }
                        .font(ClickTypography.supportingEmphasized)
                        .foregroundStyle(ClickColors.accentForeground)
                } else {
                    previewVisuals
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        // Same Liquid Glass as the tab bar and toolbar buttons it sits between.
        .glassPanelBackground(cornerRadius: 30)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onTapGesture {
            model.isNearbyPresented = true
        }
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onEnded { value in
                    if value.translation.height < -30 {
                        model.isNearbyPresented = true
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the Nearby list")
        .accessibilityAction(named: "Open Nearby list") {
            model.isNearbyPresented = true
        }
    }

    private var previewVisuals: some View {
        HStack(spacing: -8) {
            ForEach(model.items(pins: []).prefix(3)) { item in
                if case .beacon(let beacon) = item.kind {
                    EventVisual(seed: beacon.id, imageURL: beacon.imageURL, cornerRadius: 17)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(ClickColors.surface, lineWidth: 2))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Nearby sheet content shown inside the native sheet modal (medium and large detents).
struct NearbyListView: View {
    @Bindable var model: MapFeatureModel
    let pins: [ConnectionPin]
    let onOpen: (MapItem) -> Void
    /// Filters this list in place (Apple Maps style) rather than opening another sheet.
    @State private var query = ""
    @FocusState private var isSearching: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("All", count: nil, isOn: model.filter == nil) { model.filter = nil }
                    ForEach(model.layerCounts(pins: pins), id: \.layer) { entry in
                        chip(entry.layer.label, count: entry.count, isOn: model.filter == entry.layer) {
                            model.filter = model.filter == entry.layer ? nil : entry.layer
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .scrollIndicators(.hidden)
            // The chips sit under the bar but never scroll under it: no scroll-edge hairline.
            .scrollEdgeEffectHiddenIfAvailable(for: .top)

            list
        }
        // Search and refresh live in a real (transparent) navigation bar rather than a hidden
        // one: every screen opened from here has a bar, so a hidden one popped in on each push
        // and shifted everything.
        .navigationTitle("Nearby")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField.frame(maxWidth: .infinity)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh nearby", systemImage: "arrow.clockwise") { model.refresh() }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ClickColors.textTertiary)
            TextField("Search places, events, people", text: $query)
                .focused($isSearching)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .foregroundStyle(ClickColors.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ClickColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(ClickTypography.body)
        .padding(.horizontal, 14)
        .frame(minHeight: ClickMetrics.searchMinHeight)
        .background(ClickColors.fillSubtle, in: Capsule())
        .onChange(of: isSearching) { _, searching in
            // Room for results above the keyboard.
            if searching { model.nearbyDetent = .large }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matches(_ item: MapItem, _ query: String) -> Bool {
        var fields = [item.title]
        switch item.kind {
        case .beacon(let beacon):
            fields += [beacon.kind.label, beacon.locationName, beacon.description].compactMap { $0 }
        case .hub:
            fields.append("Hub")
        case .person(let pin):
            fields += [pin.locationName].compactMap { $0 }
        case .hangout(let hangout):
            fields += [MapLayer.hangouts.label, hangout.plan.placeName].compactMap { $0 }
        }
        return fields.contains { $0.localizedStandardContains(query) }
    }

    private func chip(_ title: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ClickHaptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text(count, format: .number).opacity(0.7).monospacedDigit()
                }
            }
            .font(ClickTypography.supporting.weight(isOn ? .semibold : .medium))
            .foregroundStyle(isOn ? ClickColors.accentForeground : ClickColors.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.chipHeight)
            .background(isOn ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private var list: some View {
        let search = trimmedQuery
        let sections = model.sections(pins: pins).compactMap { section -> NearbySection? in
            guard !search.isEmpty else { return section }
            let items = section.items.filter { matches($0, search) }
            return items.isEmpty ? nil : NearbySection(id: section.id, title: section.title, items: items)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if sections.isEmpty {
                    if search.isEmpty {
                        emptyState
                            .padding(.top, 30)
                    } else {
                        VStack(spacing: 6) {
                            Text("No results for “\(search)”").font(ClickTypography.bodyEmphasized)
                            Text("Try another name, place or filter.")
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textTertiary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                    }
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ClickColors.textPrimary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(section.items) { item in
                                Button { onOpen(item) } label: {
                                    NearbyRow(item: item, userCoordinate: model.userCoordinate)
                                }
                                .buttonStyle(.plain)
                                if item.id != section.items.last?.id {
                                    Divider().padding(.leading, 76)
                                }
                            }
                        }
                        // A translucent fill, not an opaque surface: it reads the same over the
                        // sheet's glass at the medium height as over its solid full height.
                        .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .edgeFadeTop()
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if model.discovery.value == nil, let message = model.discovery.errorMessage {
                Text("Couldn't load what's nearby").font(ClickTypography.bodyEmphasized)
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textTertiary)
                Button("Try again") { model.refresh() }
                    .font(ClickTypography.supportingEmphasized)
                    .padding(.top, 4)
            } else if model.discovery.value == nil {
                ClickLoadingView(size: 30, fillsSpace: false)
            } else {
                Text(model.filter == .people ? "No one from your network on the map yet" : "Nothing nearby")
                    .font(ClickTypography.bodyEmphasized)
                Text("Try another filter or check back later.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NearbyRow: View {
    let item: MapItem
    let userCoordinate: CLLocationCoordinate2D?

    var body: some View {
        HStack(spacing: 14) {
            MapItemThumbnail(item: item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)
                    if case .beacon(let beacon) = item.kind, beacon.schedule?.isLive() == true {
                        StatusPill("LIVE", style: .live)
                    }
                }
                Text(item.subtitle)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let distance {
                Text(distance)
                    .font(ClickTypography.metadataEmphasized)
                    .foregroundStyle(ClickColors.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var distance: String? {
        guard let userCoordinate else { return nil }
        let meters = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            .distance(from: CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude))
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}

/// An item's square/round thumbnail: avatar for people, deterministic visual otherwise.
struct MapItemThumbnail: View {
    let item: MapItem
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 12

    var body: some View {
        switch item.kind {
        case .person(let pin):
            AvatarView(imageURL: pin.avatarURL, seed: pin.userID, initials: pin.initials, size: size)
        case .beacon(let beacon):
            EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: cornerRadius)
                .frame(width: size, height: size)
        case .hub(let hub):
            EventVisual(seed: hub.id, symbol: MapLayer.hubs.systemImage, cornerRadius: size / 2)
                .frame(width: size, height: size)
        case .hangout(let hangout):
            EventVisual(seed: hangout.message.id, symbol: MapLayer.hangouts.systemImage, cornerRadius: cornerRadius)
                .frame(width: size, height: size)
        }
    }
}
