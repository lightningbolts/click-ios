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
            ForEach(model.items(pins: pins).prefix(3)) { item in
                if case .beacon(let beacon) = item.kind {
                    EventVisual(seed: beacon.id, imageURL: beacon.imageURL, cornerRadius: 17, maxPixelSize: EventVisual.thumbnailPixelSize)
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

            if model.placesEnabled && model.filter == .places {
                PlaceFilterChips(model: model)
            }

            list
        }
        // Search, sort and refresh live in a real (transparent) navigation bar rather than a
        // hidden one: every screen opened from here has a bar, so a hidden one popped in on each
        // push and shifted everything. Sort and refresh share one group (one glass capsule).
        .navigationTitle("Nearby")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField.frame(maxWidth: .infinity)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                Button("Refresh nearby", systemImage: "arrow.clockwise") { model.refresh() }
            }
        }
    }

    private var searchField: some View {
        FilterSearchField(prompt: "Search places, events, people", text: $query, isFocused: $isSearching)
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
        case .place(let place):
            fields += [place.category.label, place.addressLine, place.city, place.nextEvent?.title].compactMap { $0 }
        }
        return fields.contains { $0.localizedStandardContains(query) }
    }

    private func chip(_ title: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ClickHaptics.selection()
            withAnimation(.snappy) { action() }
        } label: {
            // One weight for both states, so selecting never changes a chip's width.
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text(count, format: .number).opacity(0.7).monospacedDigit()
                }
            }
            .font(ClickTypography.supporting.weight(.medium))
            .foregroundStyle(isOn ? ClickColors.accentForeground : ClickColors.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.chipHeight)
            .background(isOn ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Row order. The button wears the current order's icon, morphing between them in a
    /// fixed frame so the capsule never resizes; rows animate to their new places.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sort.animation(.snappy)) {
                ForEach(NearbySort.allCases) { sort in
                    Label(sort.label, systemImage: sort.systemImage).tag(sort)
                }
            }
        } label: {
            Image(systemName: model.sort.systemImage)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel("Sort by \(model.sort.label)")
        .onChange(of: model.sort) { ClickHaptics.selection() }
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
            // Rows are direct children of the lazy stack (a section is not one eager VStack), so
            // only what's on screen is built, even with thousands of beacons in an area.
            LazyVStack(alignment: .leading, spacing: 0) {
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
                    Section {
                        ForEach(section.items) { item in
                            let isFirst = item.id == section.items.first?.id
                            let isLast = item.id == section.items.last?.id
                            Button { onOpen(item) } label: {
                                NearbyRow(item: item, origin: model.origin)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if !isLast { Divider().padding(.leading, NearbyRow.thumbnailSize + 28) }
                            }
                            // Each row draws its slice of the section's card.
                            .groupedRowSlice(isFirst: isFirst, isLast: isLast)
                        }
                    } header: {
                        Text(section.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(ClickColors.textPrimary)
                            .padding(.horizontal, 4)
                            .padding(.top, section.id == sections.first?.id ? 0 : 20)
                            .padding(.bottom, 8)
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

/// One place, event or person: a large thumbnail, then when (in the accent while it's live or
/// today), the title, and where, how far and how many are going.
struct NearbyRow: View {
    let item: MapItem
    let origin: CLLocationCoordinate2D?

    static let thumbnailSize: CGFloat = 64

    var body: some View {
        let eyebrow = Self.eyebrow(item)
        HStack(spacing: 14) {
            MapItemThumbnail(item: item, size: Self.thumbnailSize, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if eyebrow.tone == .live {
                        Circle().fill(ClickColors.destructive).frame(width: 6, height: 6)
                    }
                    Text(eyebrow.text).lineLimit(1)
                }
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(eyebrow.tone.color)
                Text(item.title)
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                detailLine
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Where (truncating first), then how far and how many, which always show whole.
    private var detailLine: some View {
        let place = Self.place(item)
        let rest = [distance, item.peopleLabel].compactMap { $0 }
        return HStack(spacing: 0) {
            if let place {
                Text(place).lineLimit(1).truncationMode(.tail)
            }
            if !rest.isEmpty {
                Text((place == nil ? "" : " · ") + rest.joined(separator: " · "))
                    .monospacedDigit()
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .font(ClickTypography.supporting)
        .foregroundStyle(ClickColors.textSecondary)
    }

    private var distance: String? {
        guard let origin else { return nil }
        let meters = MapFeatureModel.distanceMeters(origin, item.coordinate)
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// The line over the title and how loud it is.
    struct Eyebrow: Equatable {
        enum Tone: Equatable {
            /// Happening now (a live event or Place, an SOS): red, with a dot.
            case live
            /// Needs a look (a hazard): the warning color.
            case alert
            /// Later today: the accent.
            case soon
            case plain

            var color: Color {
                switch self {
                case .live: ClickColors.destructive
                case .alert: ClickColors.warning
                case .soon: ClickColors.accentForeground
                case .plain: ClickColors.textTertiary
                }
            }
        }

        let text: String
        let tone: Tone
    }

    /// When an event is ("Live · until 10 PM", "Tomorrow · 12:00 – 1:30 PM"); for any other beacon,
    /// what it is and how fresh ("Hazard · ends in 40 min", "Soundtrack · 2 hr. ago"); else what
    /// the item is.
    static func eyebrow(_ item: MapItem, now: Date = .now) -> Eyebrow {
        switch item.kind {
        case .beacon(let beacon):
            if beacon.isEvent, let schedule = beacon.schedule {
                if schedule.isLive(at: now) {
                    return Eyebrow(text: "Live · until \(schedule.end.formatted(date: .omitted, time: .shortened))", tone: .live)
                }
                return Eyebrow(text: EventFormatting.when(schedule, now: now), tone: schedule.startsToday(at: now) ? .soon : .plain)
            }
            let tone: Eyebrow.Tone = switch beacon.kind {
            case .sos: .live
            case .hazard: .alert
            default: .plain
            }
            return Eyebrow(text: ([beacon.kind.label] + [freshness(beacon, now: now)].compactMap { $0 }).joined(separator: " · "), tone: tone)
        case .hub:
            return Eyebrow(text: "Hub", tone: .plain)
        case .person:
            return Eyebrow(text: "Your Click", tone: .plain)
        case .hangout(let hangout):
            return Eyebrow(text: "Plan · " + PlanCardView.whenText(hangout.plan.startsAt, until: hangout.plan.endsAt), tone: .plain)
        case .place(let place):
            let live = place.pulse.state == .live || place.nextEvent?.isLive == true
            return Eyebrow(text: PlaceCopy.mapSubtitle(place, now: now), tone: live ? .live : .plain)
        }
    }

    /// A short-lived beacon's ending within the day ("ends in 40 min"), else when it was posted.
    static func freshness(_ beacon: MapBeacon, now: Date = .now) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let expiresAt = beacon.expiresAt, expiresAt > now, expiresAt.timeIntervalSince(now) < 24 * 3600 {
            return "ends " + formatter.localizedString(for: expiresAt, relativeTo: now)
        }
        return beacon.createdAt.flatMap { $0 > now ? nil : formatter.localizedString(for: $0, relativeTo: now) }
    }

    /// Where it is, in words.
    static func place(_ item: MapItem) -> String? {
        switch item.kind {
        case .beacon(let beacon):
            // Legacy beacons were saved with the label "Current location": show the address instead.
            let place = BeaconDetailView.needsReverseGeocode(beacon) ? beacon.formattedAddress : beacon.locationName
            // A soundtrack leads with who's playing.
            let artist = beacon.kind == .soundtrack ? beacon.artistName?.nonEmptyTrimmed : nil
            return [artist, place].compactMap { $0 }.joined(separator: " · ").nonEmptyTrimmed
        case .hub:
            return nil
        case .person(let pin):
            return pin.locationName.map { "Met at \($0)" }
        case .hangout(let hangout):
            return hangout.plan.placeName
        case .place(let place):
            return place.addressLine ?? place.city
        }
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
            EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: cornerRadius,
                        maxPixelSize: EventVisual.thumbnailPixelSize)
                .frame(width: size, height: size)
        case .hub(let hub):
            EventVisual(seed: hub.id, symbol: MapLayer.hubs.systemImage, cornerRadius: size / 2)
                .frame(width: size, height: size)
        case .hangout(let hangout):
            EventVisual(seed: hangout.message.id, symbol: MapLayer.hangouts.systemImage, cornerRadius: cornerRadius)
                .frame(width: size, height: size)
        case .place(let place):
            EventVisual(seed: place.id, imageURL: place.photoURL?.absoluteString, symbol: place.category.symbol, cornerRadius: cornerRadius,
                        maxPixelSize: EventVisual.thumbnailPixelSize)
                .frame(width: size, height: size)
        }
    }
}
