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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 4)
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
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ClickColors.textTertiary)
                TextField("Search nearby", text: $model.query)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                    .accessibilityLabel("Clear search")
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 36, height: 36)
                        .background(ClickColors.fillSubtle, in: Circle())
                }
                .accessibilityLabel("Refresh nearby")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.searchMinHeight)
            .background(ClickColors.fillSubtle, in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 16)

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
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)

            list
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { model.nearbyDetent = .large }
        }
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
        let sections = model.sections(pins: pins)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if sections.isEmpty {
                    emptyState
                        .padding(.top, 30)
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
                        .groupedSurface()
                    }
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
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
                ProgressView()
            } else {
                Text(model.query.isEmpty ? "Nothing nearby" : "No matches for “\(model.query)”")
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
            visual
                .frame(width: 48, height: 48)
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
                Text(subtitle)
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

    @ViewBuilder
    private var visual: some View {
        switch item.kind {
        case .beacon(let beacon):
            EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage)
        case .hub(let hub):
            EventVisual(seed: hub.id, symbol: MapLayer.hubs.systemImage)
        case .person(let pin):
            AvatarView(imageURL: pin.avatarURL, seed: pin.userID, initials: pin.initials, size: 48)
        }
    }

    private var subtitle: String {
        switch item.kind {
        case .beacon(let beacon):
            if let schedule = beacon.schedule, beacon.isEvent {
                return EventFormatting.whenAndWhere(schedule, place: beacon.locationName)
            }
            return [beacon.kind.label, beacon.locationName].compactMap { $0 }.joined(separator: " · ")
        case .hub(let hub):
            return hub.participantCount == 1 ? "Hub · 1 here" : "Hub · \(hub.participantCount) here"
        case .person(let pin):
            return pin.locationName ?? "Your Click"
        }
    }

    private var distance: String? {
        guard let userCoordinate else { return nil }
        let meters = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            .distance(from: CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude))
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
