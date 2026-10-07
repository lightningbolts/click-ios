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
    /// The tab bar's inset, held while a screen is pushed: a pushed screen hides the tab bar and
    /// the map root's safe area briefly loses it (during the back-swipe too), and holding it
    /// keeps the lip and buttons from dropping and jumping back. Otherwise it follows the real
    /// inset, so it fits every device rather than latching a stale maximum.
    @State private var stableBottomInset: CGFloat = 0
    /// The map's on-screen width (it ignores the safe area): stacking works in screen points.
    @State private var mapWidth: CGFloat = 0
    /// A stack tapped while Nearby was up: its list opens once Nearby has closed.
    @State private var queuedStack: MapCluster?
    /// A row picked in a stack's list: opened once the list has closed.
    @State private var pendingStackItem: MapItem?

    public init() {}

    private var pins: [ConnectionPin] { conversations.snapshot?.pins ?? [] }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                map
                    .ignoresSafeArea()

                // One column, so the buttons always sit above the lip whatever its height (device,
                // Display Zoom, Dynamic Type) and the lip sits right on the tab bar.
                VStack(spacing: 12) {
                    Spacer()
                    VStack(spacing: 12) {
                        Button {
                            Task { await model.requestLocation() }
                        } label: {
                            Image(systemName: model.origin == nil ? "location" : "location.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ClickColors.accentForeground)
                                .frame(width: ClickMetrics.minimumHitTarget, height: ClickMetrics.minimumHitTarget)
                                .glassCircleBackground()
                        }
                        .accessibilityLabel("Center on my location")
                        // Create a beacon or event here (prototype map "+").
                        Button { creating = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(ClickColors.primaryActionForeground)
                                .frame(width: 56, height: 56)
                                .glassCircleBackground(tint: ClickColors.primaryActionFill)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Create beacon or event")
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, ClickSpacing.screenGutter)

                    NearbyLip(model: model, pins: pins)
                }
                .padding(.bottom, stableBottomInset)
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .onChange(of: proxy.safeAreaInsets.bottom, initial: true) { _, inset in
                if env.router.mapPath.isEmpty { stableBottomInset = inset }
            }
            .onChange(of: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing, initial: true) { _, width in
                mapWidth = width
            }
        }
        // The Nearby sheet's search keyboard must not count as bottom inset: it would lift the
        // lip and buttons mid-screen behind the sheet.
        .ignoresSafeArea(.keyboard)
        // The map is full-bleed under a transparent bar: the menu and layers buttons are the same
        // toolbar glass buttons, in the same spots, as every other tab root.
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // No visible title over the map; the navigation title still names the screen.
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ToolbarItem(placement: .topBarLeading) {
                RootMenu {
                    Button("Center on me", systemImage: "location") { Task { await model.requestLocation() } }
                    Button("Refresh nearby", systemImage: "arrow.clockwise") { model.refresh() }
                    Button("Open Nearby list", systemImage: "list.bullet") { model.isNearbyPresented = true }
                    if model.filter != nil || model.layers.count != MapLayer.allCases.count {
                        Button("Show everything", systemImage: "square.3.layers.3d") {
                            model.filter = nil
                            model.layers = Set(MapLayer.allCases)
                        }
                    }
                    Section {
                        EventHistoryMenuItem()
                        if env.features.isEnabled(.clickPlaces) {
                            Button("My places", systemImage: "mappin.and.ellipse") { env.router.navigate(to: .myPlaces) }
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                layersMenu
            }
        }
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
        .overlay(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if env.friction.showsGrassNudge(now: context.date) {
                    grassNudge
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .onChange(of: env.live.beaconChange) { _, change in
            if let change { model.beaconsChanged(change) }
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
        .sheet(isPresented: $model.isNearbyPresented, onDismiss: {
            if let queuedStack {
                self.queuedStack = nil
                model.openStack = queuedStack
            }
        }) {
            // Rows open inside the sheet, over the feed: back returns to the same scroll spot.
            RoutedSheetStack(path: nearbyPath, detent: $model.nearbyDetent) {
                NearbyListView(model: model, pins: pins, onOpen: open)
            }
            .presentationContentInteraction(.scrolls)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: model.isNearbyPresented) { _, open in
            if !open { model.nearbyDetent = .medium }
        }
        .sheet(item: $model.openStack, onDismiss: {
            guard let item = pendingStackItem else { return }
            pendingStackItem = nil
            model.selection = nil
            env.router.navigate(to: item.route)
        }) { cluster in
            MapStackSheet(
                cluster: cluster,
                origin: model.origin,
                onOpen: { item in
                    pendingStackItem = item
                    model.openStack = nil
                },
                onZoom: MapFeatureModel.canSeparate(cluster) ? { zoom(into: cluster) } : nil
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $creating) {
            CreateBeaconSheet(fallback: model.visibleCenter) { beacon in
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
            ForEach(model.clusters(pins: pins)) { cluster in
                if cluster.items.count == 1 {
                    let item = cluster.lead
                    Annotation(item.title, coordinate: item.coordinate, anchor: .bottom) {
                        MapPinView(item: item, isSelected: model.selection == item.id) {
                            openProfile(for: item)
                        }
                    }
                    .tag(item.id)
                    .annotationTitles(.hidden)
                } else {
                    Annotation(cluster.lead.title, coordinate: cluster.coordinate, anchor: .bottom) {
                        MapStackPin(cluster: cluster) { openStack(cluster) }
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
            model.cameraSettled(center: context.region.center, latitudeDelta: context.region.span.latitudeDelta,
                                visibleRect: context.rect, viewWidth: mapWidth)
            env.friction.recordPan()
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
            Label("Map layers", systemImage: "square.3.layers.3d")
        }
    }

    // MARK: - Routing

    private func consumeFocus() async {
        guard let focus = env.router.mapFocus else { return }
        env.router.mapFocus = nil
        await model.consume(focus)
    }

    /// The Nearby sheet's own stack, owned by the router so anything opened from it lands here.
    private var nearbyPath: Binding<[AppRoute]> {
        Binding(
            get: { env.router.nearbyPath ?? [] },
            // A closing sheet writes back an empty path; that must not reopen it.
            set: { path in if env.router.nearbyPath != nil { env.router.nearbyPath = path } }
        )
    }

    /// Opens a Nearby row inside the sheet and brings its spot into view on the map behind.
    private func open(_ item: MapItem) {
        model.focusCamera(on: item.coordinate)
        env.router.navigate(to: item.route)
    }

    private func openProfile(for item: MapItem) {
        guard case .person = item.kind else { return }
        model.selection = nil
        env.router.navigate(to: item.route)
    }

    /// A stack's list (Luma's cluster sheet). Over Nearby, Nearby closes first.
    private func openStack(_ cluster: MapCluster) {
        ClickHaptics.selection()
        env.friction.recordMeaningfulAction()
        if model.isNearbyPresented {
            queuedStack = cluster
            model.isNearbyPresented = false
        } else {
            model.openStack = cluster
        }
    }

    /// Closes the list and zooms until the stack's members draw apart.
    private func zoom(into cluster: MapCluster) {
        model.openStack = nil
        withAnimation(ClickMotion.content) {
            model.camera = .region(MapFeatureModel.region(fitting: cluster))
        }
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
        switch selection {
        case .person, nil:
            // First tap on a person shows the callout ("Priya Raman · first met here"); tapping
            // it opens the profile.
            break
        case .beacon, .hub, .hangout, .place:
            guard let item = model.items(pins: pins, applyingFilter: false).first(where: { $0.id == selection }) else { return }
            // Detail sheets keep the pin selected until they close; pushed screens don't.
            if !item.route.presentsAsSheet { model.selection = nil }
            env.router.navigate(to: item.route)
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
                MapPinTile(item: item)
            case .beacon(let beacon):
                MapPinTile(item: item)
                if beacon.schedule?.isLive() == true {
                    StatusPill("LIVE", style: .live)
                        .scaleEffect(0.8)
                        .offset(y: -8)
                }
            case .hub, .hangout:
                MapPinTile(item: item)
            case .place(let place):
                PlacePinView(place: place)
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

/// A pin's picture with its white edge; a Core Click's gold ring stands in for the edge.
private struct MapPinTile: View {
    let item: MapItem
    var size: CGFloat = MapStackPin.tileSize

    var body: some View {
        MapItemThumbnail(item: item, size: size, cornerRadius: 12)
            .overlay {
                if !item.isCoreConnection { edge.stroke(.white, lineWidth: 3) }
            }
    }

    private var edge: AnyShape {
        switch item.kind {
        case .person, .hub: AnyShape(Circle())
        default: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Pins that would overlap, as one stack (Luma's map): the first three fanned with the most
/// important on top, its name and how many more underneath. Tapping lists them all.
private struct MapStackPin: View {
    let cluster: MapCluster
    let action: () -> Void

    static let tileSize: CGFloat = 40
    /// Behind the lead: one tucked left and one right, turned slightly.
    private static let fan: [(x: CGFloat, degrees: Double)] = [(0, 0), (-13, -9), (13, 9)]

    var body: some View {
        let shown = Array(cluster.items.prefix(Self.fan.count).enumerated())
        Button(action: action) {
            ZStack {
                ForEach(shown.reversed(), id: \.element.id) { index, item in
                    MapPinTile(item: item)
                        .scaleEffect(index == 0 ? 1 : 0.88)
                        .rotationEffect(.degrees(Self.fan[index].degrees))
                        .offset(x: Self.fan[index].x)
                }
            }
            .frame(width: Self.tileSize + 26, height: Self.tileSize)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hangs under the pin without changing its size, so the stack sits on its spot.
        .overlay(alignment: .top) { caption.offset(y: Self.tileSize + 4) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cluster.lead.title) and \(cluster.items.count - 1) more")
        .accessibilityHint("Shows everything here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private var caption: some View {
        VStack(spacing: 1) {
            if case .beacon(let beacon) = cluster.lead.kind, beacon.schedule?.isLive() == true {
                StatusPill("LIVE", style: .live).scaleEffect(0.8)
            }
            Text(cluster.lead.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClickColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("+\(cluster.items.count - 1) more")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ClickColors.textSecondary)
                .monospacedDigit()
        }
        .frame(maxWidth: 140)
        .fixedSize(horizontal: false, vertical: true)
        // A halo in the map's own background keeps the label readable over streets and water.
        .shadow(color: ClickColors.plainBackground, radius: 1)
        .shadow(color: ClickColors.plainBackground, radius: 2)
        .allowsHitTesting(false)
    }
}

/// Everything in a stack, most important first, in Nearby's rows (Luma's cluster sheet). Zoom in
/// is offered when the members can actually be drawn apart.
private struct MapStackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cluster: MapCluster
    let origin: CLLocationCoordinate2D?
    let onOpen: (MapItem) -> Void
    let onZoom: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(cluster.items) { item in
                        let isLast = item.id == cluster.items.last?.id
                        Button {
                            ClickHaptics.selection()
                            onOpen(item)
                        } label: {
                            NearbyRow(item: item, origin: origin)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            if !isLast { Divider().padding(.leading, NearbyRow.thumbnailSize + 28) }
                        }
                        .groupedRowSlice(isFirst: item.id == cluster.lead.id, isLast: isLast)
                    }
                }
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.bottom, 24)
            }
            .navigationTitle(Self.title(cluster.items))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onZoom {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Zoom In", systemImage: "plus.magnifyingglass", action: onZoom)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    /// "5 Events", "3 Clicks", or "4 Here" when they're of different kinds.
    static func title(_ items: [MapItem]) -> String {
        let nouns = Set(items.map(\.pluralNoun))
        return "\(items.count) \(nouns.count == 1 ? nouns.first ?? "Here" : "Here")"
    }
}

private extension MapItem {
    var pluralNoun: String {
        switch kind {
        case .beacon(let beacon): beacon.isEvent ? "Events" : "Beacons"
        case .person: "Clicks"
        case .place: "Places"
        case .hub: "Hubs"
        case .hangout: "Plans"
        }
    }
}
