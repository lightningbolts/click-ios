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

    /// The sheet's height while a finger is on it (nil when resting on a detent). One value
    /// drives the frame; there is no second implicit animation fighting the finger.
    @State private var liveHeight: CGFloat?
    @State private var dragStartHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let lipHeight: CGFloat = 84

    nonisolated static func height(for detent: MapFeatureModel.SheetDetent, available: CGFloat) -> CGFloat {
        switch detent {
        case .lip: lipHeight
        case .medium: max(lipHeight, available * 0.46)
        case .expanded: max(lipHeight, available - 8)
        }
    }

    private var baseHeight: CGFloat { Self.height(for: model.sheetDetent, available: availableHeight) }

    /// Content fades in over the first 60 pt above the lip instead of mounting mid-drag.
    nonisolated static func contentOpacity(height: CGFloat) -> Double {
        Double(min(1, max(0, (height - lipHeight) / 60)))
    }

    /// Nearest detent to where the gesture would come to rest (uses fling velocity).
    nonisolated static func settledDetent(projectedHeight: CGFloat, available: CGFloat) -> MapFeatureModel.SheetDetent {
        MapFeatureModel.SheetDetent.allCases.min {
            abs(height(for: $0, available: available) - projectedHeight) < abs(height(for: $1, available: available) - projectedHeight)
        } ?? .lip
    }

    var body: some View {
        let maxHeight = Self.height(for: .expanded, available: availableHeight)
        let height = min(max(liveHeight ?? baseHeight, Self.lipHeight), maxHeight)
        // The card is always laid out at full height and only *moved* (offset) — a transform,
        // not a relayout — so dragging and snapping never re-measure the list, material or
        // shadow. The host clips it at the map's bottom edge.
        VStack(spacing: 0) {
            header
            content
                .opacity(Self.contentOpacity(height: height))
                .allowsHitTesting(model.sheetDetent != .lip && liveHeight == nil)
                .accessibilityHidden(model.sheetDetent == .lip)
        }
        .frame(maxWidth: .infinity)
        .frame(height: maxHeight, alignment: .top)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 4)
        .padding(.horizontal, 8)
        .offset(y: maxHeight - height)
        .animation(liveHeight == nil && !reduceMotion ? .spring(response: 0.45, dampingFraction: 0.86) : nil, value: model.sheetDetent)
        .onChange(of: model.sheetDetent) { _, detent in
            // Tab bar and floating map controls change only once the snap has finished.
            Task {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 420))
                if model.sheetDetent == detent { model.settledDetent = detent }
            }
        }
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
            // Global space: the header moves with the card, so local translation would feed back.
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if liveHeight == nil { dragStartHeight = baseHeight }
                        liveHeight = dragStartHeight - value.translation.height
                    }
                }
                .onEnded { value in
                    settle(projectedHeight: dragStartHeight - value.predictedEndTranslation.height)
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

    private func settle(projectedHeight: CGFloat) {
        let target = Self.settledDetent(projectedHeight: projectedHeight, available: availableHeight)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .interpolatingSpring(mass: 1, stiffness: 260, damping: 30)) {
            model.sheetDetent = target
            liveHeight = nil
        }
        if target == .lip { isSearchFocused = false }
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
        // The part of the full-height card hidden below the edge at the current detent.
        let hidden = Self.height(for: .expanded, available: availableHeight) - baseHeight
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
        .contentMargins(.bottom, max(0, hidden), for: .scrollContent)
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
