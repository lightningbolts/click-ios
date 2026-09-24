import SwiftUI

/// The Map root's Nearby discovery surface: collapsed lip → medium → expanded (spec §49, §63).
///
/// A narrowly scoped container rather than a system `.sheet`: a presented sheet would cover the
/// native tab bar on the Map root. Only the header drags or taps between detents, so the list
/// scrolls with native physics and never competes with the sheet gesture, and the map stays
/// pannable everywhere outside the surface.
struct NearbySheet: View {
    @Bindable var model: MapFeatureModel
    let pins: [ConnectionPin]
    let availableHeight: CGFloat
    let onOpen: (MapItem) -> Void

    @GestureState private var dragOffset: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let lipHeight: CGFloat = 84

    static func height(for detent: MapFeatureModel.SheetDetent, available: CGFloat) -> CGFloat {
        switch detent {
        case .lip: lipHeight
        case .medium: max(lipHeight, available * 0.46)
        case .expanded: max(lipHeight, available - 8)
        }
    }

    private var cornerRadius: CGFloat { model.sheetDetent == .lip ? 30 : 38 }

    private var baseHeight: CGFloat { Self.height(for: model.sheetDetent, available: availableHeight) }

    var body: some View {
        let height = min(max(baseHeight - dragOffset, Self.lipHeight), Self.height(for: .expanded, available: availableHeight))
        VStack(spacing: 0) {
            header
            if model.sheetDetent != .lip {
                content
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        // Every detent is a floating, fully rounded card (visual system: 38 pt sheet radius,
        // inset from the edges) so the expanded state never ends in a hard straight edge.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 4)
        .padding(.horizontal, model.sheetDetent == .lip ? ClickSpacing.screenGutter : 8)
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86), value: model.sheetDetent)
    }

    // MARK: - Header (the only drag target)

    private var header: some View {
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
                } else if model.sheetDetent != .lip {
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 36, height: 36)
                            .background(ClickColors.fillSubtle, in: Circle())
                    }
                    .accessibilityLabel("Refresh nearby")
                } else {
                    previewVisuals
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, model.sheetDetent == .lip ? 12 : 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.sheetDetent = model.sheetDetent == .lip ? .medium : .lip
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    settle(predictedTranslation: value.predictedEndTranslation.height)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: model.sheetDetent == .lip ? "Expand Nearby" : "Collapse Nearby") {
            model.sheetDetent = model.sheetDetent == .lip ? .medium : .lip
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

    private func settle(predictedTranslation: CGFloat) {
        let target = baseHeight - predictedTranslation
        let detents = MapFeatureModel.SheetDetent.allCases
        let nearest = detents.min { abs(Self.height(for: $0, available: availableHeight) - target) < abs(Self.height(for: $1, available: availableHeight) - target) }
        model.sheetDetent = nearest ?? .lip
        if model.sheetDetent == .lip { isSearchFocused = false }
    }

    // MARK: - Content

    private var content: some View {
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
            }
            .padding(.horizontal, 14)
            .frame(minHeight: ClickMetrics.searchMinHeight)
            .background(ClickColors.fillSubtle, in: Capsule())
            .padding(.horizontal, 20)
            .onChange(of: isSearchFocused) { _, focused in
                if focused { model.sheetDetent = .expanded }
            }

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
