import CoreLocation
import MapKit
import Observation
import SwiftUI

/// What is selected on the map / in Nearby. Both views bind to this one value.
enum MapSelection: Hashable {
    case beacon(String)
    case hub(String)
    case person(String)
}

/// One annotation on the map. Identity is the underlying entity ID, so refreshes update pins
/// in place instead of removing and re-inserting them (spec §49.2).
struct MapItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case beacon(MapBeacon)
        case hub(NearbyHub)
        case person(ConnectionPin)
    }

    let kind: Kind

    var id: MapSelection {
        switch kind {
        case .beacon(let beacon): .beacon(beacon.id)
        case .hub(let hub): .hub(hub.id)
        case .person(let pin): .person(pin.userID)
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch kind {
        case .beacon(let beacon): beacon.coordinate
        case .hub(let hub): hub.coordinate
        case .person(let pin): CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        }
    }

    var layer: MapLayer {
        switch kind {
        case .beacon(let beacon): MapLayer(kind: beacon.kind)
        case .hub: .hubs
        case .person: .people
        }
    }

    var title: String {
        switch kind {
        case .beacon(let beacon): beacon.title
        case .hub(let hub): hub.name
        case .person(let pin): pin.displayName
        }
    }
}

/// A Nearby list section.
struct NearbySection: Identifiable {
    let id: String
    let title: String
    let items: [MapItem]
}

/// Owns the Map root and its Nearby discovery sheet: viewport, location state, layers,
/// pins, discovery data, selection, and focus intents (spec §49.2).
@Observable
@MainActor
final class MapFeatureModel {
    enum LocationState: Equatable {
        case notDetermined
        case denied
        case approximate
        case precise
    }

    enum SheetDetent: CaseIterable {
        case lip
        case medium
        case expanded
    }

    var camera: MapCameraPosition = .automatic
    private(set) var userCoordinate: CLLocationCoordinate2D?
    private(set) var locationState: LocationState = .notDetermined
    private(set) var discovery = ModuleState<NearbyDiscovery>()
    /// Beacons fetched individually for a focus intent (e.g. an event outside the fetched radius).
    private(set) var focusedBeacons: [MapBeacon] = []

    var layers: Set<MapLayer> = Set(MapLayer.allCases)
    /// Single-layer filter chosen from Nearby chips; applies to the map too.
    var filter: MapLayer?
    var query = ""
    var selection: MapSelection?
    var sheetDetent: SheetDetent = .lip

    private var environment: AppEnvironment?
    private var locationTask: Task<Void, Never>?
    private var lastFetchCenter: CLLocationCoordinate2D?
    private var hasCenteredOnUser = false
    private var fetchTask: Task<Void, Never>?

    func attach(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
    }

    // MARK: - Derived data (map and list read the same items)

    func items(pins: [ConnectionPin], applyingFilter: Bool = true, now: Date = .now) -> [MapItem] {
        var beacons = (discovery.value?.beacons ?? []).filter { $0.isActive(at: now) }
        for focused in focusedBeacons where !beacons.contains(where: { $0.id == focused.id }) {
            beacons.append(focused)
        }
        let all = beacons.map { MapItem(kind: .beacon($0)) }
            + (discovery.value?.hubs ?? []).map { MapItem(kind: .hub($0)) }
            + pins.map { MapItem(kind: .person($0)) }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.filter { item in
            layers.contains(item.layer)
                && (!applyingFilter || filter == nil || filter == item.layer)
                && (clean.isEmpty || item.title.localizedCaseInsensitiveContains(clean) || placeText(item).localizedCaseInsensitiveContains(clean))
        }
    }

    /// Discovery list: live events first, then by layer. People appear on the map only.
    func sections(pins: [ConnectionPin], now: Date = .now) -> [NearbySection] {
        let visible = items(pins: [], now: now)
        func beaconItems(_ predicate: (MapBeacon) -> Bool) -> [MapItem] {
            visible.filter { if case .beacon(let beacon) = $0.kind { return predicate(beacon) }; return false }
        }
        let live = beaconItems { $0.schedule?.isLive(at: now) == true }
        let upcoming = beaconItems { $0.isEvent && $0.schedule?.isLive(at: now) != true }
            .sorted { lhs, rhs in startDate(lhs) < startDate(rhs) }
        let hubs = visible.filter { if case .hub = $0.kind { return true }; return false }
        var sections = [
            NearbySection(id: "live", title: "Happening now", items: live),
            NearbySection(id: "events", title: "Events", items: upcoming),
            NearbySection(id: "hubs", title: "Hubs", items: hubs)
        ]
        for layer in [MapLayer.social, .soundtracks, .alerts, .other] {
            let items = beaconItems { !$0.isEvent && MapLayer(kind: $0.kind) == layer }
            sections.append(NearbySection(id: layer.rawValue, title: layer.label, items: items))
        }
        return sections.filter { !$0.items.isEmpty }
    }

    /// Real counts per layer for the filter chips (before the chip filter is applied).
    func layerCounts(pins: [ConnectionPin]) -> [(layer: MapLayer, count: Int)] {
        let all = items(pins: pins, applyingFilter: false)
        return MapLayer.allCases.compactMap { layer in
            let count = all.filter { $0.layer == layer }.count
            return count > 0 ? (layer, count) : nil
        }
    }

    func summary(pins: [ConnectionPin]) -> String {
        if locationState == .notDetermined || (locationState == .denied && discovery.value == nil) {
            return "Turn on location to see what's around you"
        }
        if discovery.value == nil {
            return discovery.errorMessage != nil ? "Couldn't load what's nearby" : "Looking around you…"
        }
        let count = items(pins: []).count
        let live = sections(pins: []).first { $0.id == "live" }?.items.count ?? 0
        if count == 0 { return "Nothing nearby right now" }
        return live > 0 ? "\(count) nearby · \(live) live now" : "\(count) nearby"
    }

    // MARK: - Location

    func refreshLocationState() {
        guard let environment else { return }
        switch environment.permissions.status(for: .locationWhenInUse) {
        case .notDetermined: locationState = .notDetermined
        case .denied, .restricted: locationState = .denied
        case .authorized: locationState = environment.location.isPrecise ? .precise : .approximate
        }
    }

    /// Starts live location while the Map is visible.
    func startLocationIfAllowed() {
        refreshLocationState()
        guard locationState == .precise || locationState == .approximate, locationTask == nil else { return }
        locationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self, !Task.isCancelled else { return }
                    guard let location = update.location else { continue }
                    self.handleFix(location)
                }
            } catch {
                return
            }
        }
    }

    func stopLocation() {
        locationTask?.cancel()
        locationTask = nil
    }

    /// Explicit user intent (recenter / "Turn on location").
    func requestLocation() async {
        guard let environment else { return }
        if environment.permissions.status(for: .locationWhenInUse) == .notDetermined {
            _ = await environment.permissions.requestPermission(for: .locationWhenInUse)
        }
        refreshLocationState()
        if locationState == .denied {
            environment.permissions.openSystemSettings()
            return
        }
        startLocationIfAllowed()
        if let userCoordinate {
            withAnimation { camera = .region(MKCoordinateRegion(center: userCoordinate, latitudinalMeters: 2500, longitudinalMeters: 2500)) }
        }
    }

    private func handleFix(_ location: CLLocation) {
        let firstFix = userCoordinate == nil
        userCoordinate = location.coordinate
        environment?.location.record(location)
        if firstFix, !hasCenteredOnUser, selection == nil {
            hasCenteredOnUser = true
            camera = .region(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000))
        }
        fetchIfMoved(to: location.coordinate)
    }

    // MARK: - Discovery

    func loadCached() async {
        guard let environment, let userID = environment.session.currentSession?.userId else { return }
        discovery.seed(await environment.beacons.cachedDiscovery(userID: userID))
    }

    /// Coalesces viewport changes: refetches only when the center moved ~1 km from the last fetch.
    func cameraSettled(center: CLLocationCoordinate2D) {
        guard userCoordinate == nil || locationState == .denied else { return }
        fetchIfMoved(to: center)
    }

    private func fetchIfMoved(to center: CLLocationCoordinate2D) {
        if let last = lastFetchCenter {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            guard moved > 1_000 else { return }
        }
        refresh(around: center)
    }

    func refresh() {
        if let center = userCoordinate ?? lastFetchCenter {
            refresh(around: center)
        }
    }

    private func refresh(around center: CLLocationCoordinate2D) {
        guard let environment, let userID = environment.session.currentSession?.userId else { return }
        lastFetchCenter = center
        fetchTask?.cancel()
        fetchTask = Task {
            discovery.begin()
            do {
                let fresh = try await environment.beacons.discovery(around: center, userID: userID)
                guard !Task.isCancelled else { return }
                discovery.succeed(fresh)
            } catch {
                guard !Task.isCancelled else { return }
                discovery.fail(error.userFacingMessage)
            }
        }
    }

    // MARK: - Focus & selection

    /// Consumes a "show on map" intent from Home, Saved Events, notifications, or deep links.
    func consume(_ focus: MapFocus) async {
        switch focus {
        case .layer(let layer):
            filter = layer
            layers.insert(layer)
            sheetDetent = .medium
        case .hub(let id):
            if let hub = discovery.value?.hubs.first(where: { $0.id == id }) {
                select(.hub(id), at: hub.coordinate)
            }
        case .place(let id):
            let known = (discovery.value?.beacons ?? []).first(where: { $0.id == id })
            let beacon: MapBeacon? = if let known { known } else { try? await environment?.beacons.beacon(id: id).beacon }
            guard let beacon else { return }
            if known == nil {
                focusedBeacons.removeAll { $0.id == id }
                focusedBeacons.append(beacon)
            }
            layers.insert(MapLayer(kind: beacon.kind))
            sheetDetent = .lip
            withAnimation {
                camera = .region(MKCoordinateRegion(center: beacon.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        case .beacon(let id):
            if let beacon = (discovery.value?.beacons ?? []).first(where: { $0.id == id }) {
                select(.beacon(id), at: beacon.coordinate)
            } else if let environment, let found = try? await environment.beacons.beacon(id: id) {
                focusedBeacons.removeAll { $0.id == id }
                focusedBeacons.append(found.beacon)
                layers.insert(MapLayer(kind: found.beacon.kind))
                select(.beacon(id), at: found.beacon.coordinate)
            }
        }
    }

    func select(_ selection: MapSelection, at coordinate: CLLocationCoordinate2D) {
        self.selection = selection
        sheetDetent = .lip
        withAnimation {
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    func beacon(for selection: MapSelection?) -> MapBeacon? {
        guard case .beacon(let id) = selection else { return nil }
        return (discovery.value?.beacons ?? []).first { $0.id == id } ?? focusedBeacons.first { $0.id == id }
    }

    // MARK: - Private

    private func placeText(_ item: MapItem) -> String {
        switch item.kind {
        case .beacon(let beacon): beacon.locationName ?? beacon.formattedAddress ?? ""
        case .hub(let hub): hub.category
        case .person(let pin): pin.locationName ?? ""
        }
    }

    private func startDate(_ item: MapItem) -> Date {
        if case .beacon(let beacon) = item.kind { return beacon.schedule?.start ?? .distantFuture }
        return .distantFuture
    }
}
