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

    public init() {}

    private var pins: [ConnectionPin] { conversations.snapshot?.pins ?? [] }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                map
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    Spacer()
                    HStack {
                        Spacer()
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
                    }
                    .opacity(model.sheetDetent == .expanded ? 0 : 1)
                }
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.bottom, NearbySheet.height(for: model.sheetDetent, available: proxy.size.height) + 12)

                NearbySheet(model: model, pins: pins, availableHeight: proxy.size.height) { item in
                    open(item)
                }
            }
        }
        // The map is full-bleed: no title bar, just floating glass controls (prototype Map root).
        .overlay(alignment: .top) {
            HStack {
                RootMenu(floating: true)
                Spacer()
                layersMenu
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 4)
            .opacity(model.sheetDetent == .expanded ? 0 : 1)
        }
        .navigationTitle("Map")
        .toolbar(.hidden, for: .navigationBar)
        .task {
            model.attach(env)
            await model.loadCached()
            model.startLocationIfAllowed()
            await consumeFocus()
        }
        .onDisappear { model.stopLocation() }
        .onChange(of: env.router.mapFocus) { _, _ in
            Task { await consumeFocus() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.startLocationIfAllowed() } else if phase == .background { model.stopLocation() }
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
            ForEach(model.items(pins: pins)) { item in
                Annotation(item.title, coordinate: item.coordinate, anchor: .bottom) {
                    MapPinView(item: item, isSelected: model.selection == item.id)
                }
                .tag(item.id)
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            model.cameraSettled(center: context.region.center)
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

    private func handleSelection(_ selection: MapSelection?) {
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
        case .person(let userID):
            model.selection = nil
            let pin = pins.first { $0.userID == userID }
            env.router.navigate(to: .userProfile(userID: userID, connectionID: pin?.connectionID))
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

    var body: some View {
        VStack(spacing: 2) {
            switch item.kind {
            case .person(let pin):
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
    }
}
