import MapKit
import SwiftUI

/// The Map root: native MapKit with stable connection/beacon/hub annotations, floating
/// controls, and the Nearby discovery lip/sheet — all reading `MapFeatureModel`
/// and the shell-owned inbox (for connection pins) (spec §49–§51, §63).
public struct ClickMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MapFeatureModel()
    @State private var creating = false
    @State private var mapCenter: CLLocationCoordinate2D?

    public init() {}

    private var pins: [ConnectionPin] { conversations.snapshot?.pins ?? [] }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                map
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Spacer()
                        VStack(spacing: 12) {
                        Button {
                            Task { await model.requestLocation() }
                        } label: {
                            Image(systemName: model.userCoordinate == nil ? "location" : "location.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ClickColors.accentForeground)
                                .frame(width: ClickMetrics.minimumHitTarget, height: ClickMetrics.minimumHitTarget)
                                .background(.regularMaterial, in: Circle())
                        }
                        .accessibilityLabel("Center on my location")
                        // Create a beacon or event here (prototype map "+").
                        Button { creating = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(ClickColors.primaryActionForeground)
                                .frame(width: 56, height: 56)
                                .background(ClickColors.primaryActionFill, in: Circle())
                                .shadow(color: ClickColors.primaryActionFill.opacity(0.4), radius: 10, y: 4)
                        }
                        .accessibilityLabel("Create beacon or event")
                        }
                    }
                }
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.bottom, 84 + 12)

                NearbyLip(model: model, pins: pins)
            }
        }
        // The map is full-bleed: no title bar, just floating glass controls (prototype Map root).
        .overlay(alignment: .top) {
            HStack {
                RootMenu(floating: true, includesAccountItems: false) {
                    Button("Center on me", systemImage: "location") { Task { await model.requestLocation() } }
                    Button("Refresh nearby", systemImage: "arrow.clockwise") { model.refresh() }
                    Button("Open Nearby list", systemImage: "list.bullet") { model.isNearbyPresented = true }
                    Button("Saved events", systemImage: "bookmark") { env.router.navigate(to: .savedEvents) }
                    if model.filter != nil || model.layers.count != MapLayer.allCases.count {
                        Button("Show everything", systemImage: "square.3.layers.3d") {
                            model.filter = nil
                            model.layers = Set(MapLayer.allCases)
                        }
                    }
                }
                Spacer()
                layersMenu
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 4)
        }
        .navigationTitle("Map")
        .toolbar(.hidden, for: .navigationBar)
        // Fully expanded, Nearby takes over the screen including the tab bar area.
        // The tab bar stays put: hiding it resizes the map area mid-snap and made the sheet flicker.
        .task {
            model.attach(env)
            await model.loadCached()
            model.startLocationIfAllowed()
            await consumeFocus()
        }
        .onAppear { env.friction.beginSession() }
        .onDisappear {
            model.isNearbyPresented = false
            model.stopLocation()
            Task { await env.friction.endSession() }
        }
        .onChange(of: env.router.selectedTab) { _, tab in
            if tab != .map { model.isNearbyPresented = false }
        }
        .onChange(of: model.userCoordinate?.latitude) { _, _ in
            if let coordinate = model.userCoordinate {
                env.friction.updateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        }
        .overlay(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if env.friction.showsGrassNudge(now: context.date) {
                    grassNudge
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .onChange(of: env.router.mapFocus) { _, _ in
            Task { await consumeFocus() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.startLocationIfAllowed()
                env.friction.beginSession()
            } else if phase == .background {
                model.stopLocation()
                Task { await env.friction.endSession() }
            }
        }
        .sheet(isPresented: $model.isNearbyPresented) {
            NearbyListView(model: model, pins: pins) { item in
                model.isNearbyPresented = false
                Task { try? await Task.sleep(for: .milliseconds(350)); open(item) }
            }
            .presentationDetents([.medium, .large], selection: $model.nearbyDetent)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(38)
        }
        .onChange(of: model.isNearbyPresented) { _, open in
            if !open { model.nearbyDetent = .medium }
        }
        .sheet(isPresented: Binding(get: { !model.overlapChoices.isEmpty }, set: { if !$0 { model.overlapChoices = [] } })) {
            OverlappingPinsChooser(items: model.overlapChoices) { item in
                model.overlapChoices = []
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if case .person = item.kind {
                        openProfile(for: item)
                    } else {
                        model.chosenFromStack = item.id
                        model.selection = item.id
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $creating) {
            CreateBeaconSheet(fallback: mapCenter) { beacon in
                model.refresh()
                env.router.navigate(to: beacon.isEvent ? .event(beaconID: beacon.id) : .beacon(beaconID: beacon.id))
            }
        }
        .onChange(of: model.selection) { _, selection in
            handleSelection(selection)
        }
        // The shell owns the detail sheet; clear the pin selection once it closes.
        .onChange(of: env.router.presentedSheet) { _, sheet in
            if sheet == nil, case .beacon? = model.selection { model.selection = nil }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $model.camera, selection: $model.selection) {
            UserAnnotation()
            ForEach(MapFeatureModel.clusters(model.items(pins: pins), zoom: model.renderZoom)) { cluster in
                if cluster.items.count == 1, let item = cluster.items.first {
                    Annotation(item.title, coordinate: item.coordinate, anchor: .bottom) {
                        MapPinView(item: item, isSelected: model.selection == item.id) {
                            openProfile(for: item)
                        }
                    }
                    .tag(item.id)
                    .annotationTitles(.hidden)
                } else {
                    Annotation("\(cluster.items.count) places", coordinate: cluster.coordinate) {
                        Button {
                            zoom(into: cluster)
                        } label: {
                            Text("\(cluster.items.count)")
                                .font(ClickTypography.supportingEmphasized)
                                .monospacedDigit()
                                .foregroundStyle(ClickColors.primaryActionForeground)
                                .frame(minWidth: 40, minHeight: 40)
                                .padding(.horizontal, 4)
                                .background(ClickColors.primaryActionFill, in: Capsule())
                                .overlay(Capsule().stroke(.white, lineWidth: 3))
                                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cluster.items.count) places. Zoom in.")
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            model.cameraSettled(center: context.region.center, latitudeDelta: context.region.span.latitudeDelta)
            env.friction.recordPan()
            mapCenter = context.region.center
        }
    }

    private var layersMenu: some View {
        Menu {
            Section("Show on map") {
                ForEach(MapLayer.allCases, id: \.self) { layer in
                    Toggle(isOn: Binding(
                        get: { model.layers.contains(layer) },
                        set: { isOn in
                            if isOn { model.layers.insert(layer) } else { model.layers.remove(layer) }
                        }
                    )) {
                        Label(layer.label, systemImage: layer.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ClickColors.accentForeground)
                .frame(width: ClickMetrics.minimumHitTarget, height: ClickMetrics.minimumHitTarget)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Map layers")
    }

    // MARK: - Routing

    private func consumeFocus() async {
        guard let focus = env.router.mapFocus else { return }
        env.router.mapFocus = nil
        await model.consume(focus)
    }

    private func open(_ item: MapItem) {
        model.select(item.id, at: item.coordinate)
    }

    private func openProfile(for item: MapItem) {
        guard case .person(let pin) = item.kind else { return }
        model.selection = nil
        env.router.navigate(to: .userProfile(userID: pin.userID, connectionID: pin.connectionID))
    }

    /// Zooms into a cluster far enough that its members draw as pins (KMP cluster tap).
    private func zoom(into cluster: MapCluster) {
        let target = MapFeatureModel.zoomToFit(cluster)
        model.noteClusterTap(targetZoom: target)
        let delta = MapFeatureModel.latitudeDelta(forZoom: target)
        withAnimation(ClickMotion.content) {
            model.camera = .region(MKCoordinateRegion(center: cluster.coordinate,
                                                      span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)))
        }
    }

    /// Pins stacked under the tap: more than one opens the "Which pin?" chooser instead of
    /// guessing (KMP `onMapPinTapped`).
    private func stackedChoices(for selection: MapSelection) -> [MapItem]? {
        let drawn = MapFeatureModel.clusters(model.items(pins: pins), zoom: model.renderZoom)
            .filter { $0.items.count == 1 }
            .compactMap(\.items.first)
        guard let tapped = drawn.first(where: { $0.id == selection }) else { return nil }
        let stack = MapFeatureModel.overlapping(tapped, in: drawn, zoom: model.renderZoom)
        return stack.count > 1 ? stack : nil
    }

    /// Spec §71.1 "grass nudge": a long, aimless map session gets a gentle prompt.
    private var grassNudge: some View {
        HStack(spacing: 10) {
            Text("🌱")
            VStack(alignment: .leading, spacing: 1) {
                Text("Still looking?").font(ClickTypography.supportingEmphasized)
                Text("The best Clicks happen in person. Try an event nearby.").font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            Spacer(minLength: 4)
            Button {
                env.friction.dismissGrassNudge()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, ClickSpacing.screenGutter)
    }

    private func handleSelection(_ selection: MapSelection?) {
        if selection != nil { env.friction.recordMeaningfulAction() }
        if let selection, selection == model.chosenFromStack {
            model.chosenFromStack = nil
        } else if let selection, model.overlapChoices.isEmpty, let stack = stackedChoices(for: selection) {
            model.selection = nil
            model.overlapChoices = stack
            return
        }
        switch selection {
        case .beacon(let id):
            let isEvent = model.items(pins: pins, applyingFilter: false).contains {
                if case .beacon(let beacon) = $0.kind { return beacon.id == id && beacon.isEvent }
                return false
            }
            env.router.navigate(to: isEvent ? .event(beaconID: id) : .beacon(beaconID: id))
        case .hub(let id):
            model.selection = nil
            env.router.navigate(to: .hub(hubID: id))
        case .person:
            // First tap shows the callout ("Priya Raman · first met here"); tapping it opens
            // the profile.
            break
        case nil:
            break
        }
    }
}

/// Annotation content: people use the shared avatar; beacons and hubs use their deterministic
/// visual. Static views only — nothing animates while the map pans.
private struct MapPinView: View {
    let item: MapItem
    let isSelected: Bool
    var onOpenCallout: () -> Void = {}

    var body: some View {
        VStack(spacing: 2) {
            switch item.kind {
            case .person(let pin):
                if isSelected {
                    Button(action: onOpenCallout) {
                        // Compact two-line bubble with a hard width cap: long names and venue
                        // names truncate instead of stretching across the map.
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(pin.displayName)
                                    .font(ClickTypography.supportingEmphasized)
                                    .foregroundStyle(ClickColors.textPrimary)
                                Text(pin.locationName.map { "Met at \($0)" } ?? "First met here")
                                    .font(ClickTypography.caption)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                            .lineLimit(1)
                            .truncationMode(.tail)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ClickColors.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 180)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                    .accessibilityLabel("\(pin.displayName), first met here. Open profile.")
                }
                AvatarView(imageURL: pin.avatarURL, seed: pin.userID, initials: pin.initials, size: 40)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
            case .beacon(let beacon):
                EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: 12)
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 3))
                if beacon.schedule?.isLive() == true {
                    StatusPill("LIVE", style: .live)
                        .scaleEffect(0.8)
                        .offset(y: -8)
                }
            case .hub(let hub):
                EventVisual(seed: hub.id, symbol: MapLayer.hubs.systemImage, cornerRadius: 20)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .scaleEffect(isSelected ? 1.18 : 1)
        .animation(ClickMotion.selection, value: isSelected)
        .accessibilityElement(children: isSelected ? .contain : .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// "Which pin?": pins stacked at one spot (people met at the same venue), so the viewer picks
/// instead of the map guessing (KMP `OverlappingMapPinsChooser`).
private struct OverlappingPinsChooser: View {
    let items: [MapItem]
    let onPick: (MapItem) -> Void

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button {
                    ClickHaptics.selection()
                    onPick(item)
                } label: {
                    HStack(spacing: 12) {
                        switch item.kind {
                        case .person(let pin):
                            AvatarView(imageURL: pin.avatarURL, seed: pin.userID, initials: pin.initials, size: 44)
                        case .beacon(let beacon):
                            EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: 10)
                                .frame(width: 44, height: 44)
                        case .hub(let hub):
                            EventVisual(seed: hub.id, symbol: MapLayer.hubs.systemImage, cornerRadius: 22)
                                .frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(ClickTypography.bodyEmphasized)
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(2)
                            Text(subtitle(item))
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Which pin?")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Text("A few pins are stacked here — pick the one you meant.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ClickSpacing.screenGutter)
                    .padding(.bottom, 4)
            }
        }
    }

    private func subtitle(_ item: MapItem) -> String {
        switch item.kind {
        case .person(let pin): pin.locationName.map { "Met at \($0)" } ?? "My network"
        case .beacon(let beacon): beacon.kind.label
        case .hub: "Hub"
        }
    }
}
