import CoreLocation
import MapKit
import Observation
import SwiftUI

/// What is selected on the map / in Nearby. Both views bind to this one value.
enum MapSelection: Hashable {
    case beacon(String)
    case hub(String)
    case person(String)
    case hangout(String)
    case place(String)
}

/// A plan made in a chat with a place set: on the map and in Nearby until it ends.
struct PlannedHangout: Equatable {
    let message: ChatMessageItem
    let plan: HangoutPlan
    let latitude: Double
    let longitude: Double

    init?(_ message: ChatMessageItem) {
        guard !message.isDeleted, let plan = message.plan, let latitude = plan.latitude, let longitude = plan.longitude else { return nil }
        self.message = message
        self.plan = plan
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One annotation on the map. Identity is the underlying entity ID, so refreshes update pins
/// in place instead of removing and re-inserting them (spec §49.2).
struct MapItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case beacon(MapBeacon)
        case hub(NearbyHub)
        case person(ConnectionPin)
        case hangout(PlannedHangout)
        case place(PlaceSummary)
    }

    let kind: Kind

    var id: MapSelection {
        switch kind {
        case .beacon(let beacon): .beacon(beacon.id)
        case .hub(let hub): .hub(hub.id)
        case .person(let pin): .person(pin.userID)
        case .hangout(let hangout): .hangout(hangout.message.id)
        case .place(let place): .place(place.id)
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch kind {
        case .beacon(let beacon): beacon.coordinate
        case .hub(let hub): hub.coordinate
        case .person(let pin): CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        case .hangout(let hangout): CLLocationCoordinate2D(latitude: hangout.latitude, longitude: hangout.longitude)
        case .place(let place): place.coordinate
        }
    }

    var layer: MapLayer {
        switch kind {
        case .beacon(let beacon): MapLayer(kind: beacon.kind)
        case .hub: .hubs
        case .person: .people
        case .hangout: .hangouts
        case .place: .places
        }
    }

    var title: String {
        switch kind {
        case .beacon(let beacon): beacon.title
        case .hub(let hub): hub.name
        case .person(let pin): pin.displayName
        case .hangout(let hangout): hangout.plan.title
        case .place(let place): place.name
        }
    }

    /// Where opening this item goes (map pin, Nearby row, "Which pin?" chooser).
    var route: AppRoute {
        switch kind {
        case .beacon(let beacon): beacon.isEvent ? .event(beaconID: beacon.id) : .beacon(beaconID: beacon.id)
        case .hub(let hub): .hub(hubID: hub.id)
        case .person(let pin): .userProfile(userID: pin.userID, connectionID: pin.connectionID)
        case .hangout(let hangout): hangout.message.route
        case .place(let place): .place(idOrSlug: place.id, anchorToken: nil)
        }
    }

    /// One line under the title (Nearby rows, "Which pin?" chooser).
    var subtitle: String {
        switch kind {
        case .beacon(let beacon):
            if let schedule = beacon.schedule, beacon.isEvent {
                return EventFormatting.whenAndWhere(schedule, place: beacon.locationName)
            }
            return [beacon.kind.label, beacon.locationName].compactMap { $0 }.joined(separator: " · ")
        case .hub:
            return "Hub"
        case .person(let pin):
            return pin.locationName.map { "Met at \($0)" } ?? "Your Click"
        case .hangout(let hangout):
            return ([PlanCardView.whenText(hangout.plan.startsAt, until: hangout.plan.endsAt)] + [hangout.plan.placeName].compactMap { $0 })
                .joined(separator: " · ")
        case .place(let place):
            return PlaceCopy.mapSubtitle(place)
        }
    }
}

extension MapItem {
    /// People behind this item: going (events with RSVP), in the hub, at the place right now.
    var peopleCount: Int? {
        switch kind {
        case .beacon(let beacon): beacon.isEvent && beacon.rsvpEnabled != false ? beacon.rsvpCount : nil
        case .hub(let hub): hub.participantCount
        case .place(let place): place.hereNowCount
        case .person, .hangout: nil
        }
    }

    /// "12 going" / "3 here"; nil when nobody is.
    var peopleLabel: String? {
        guard let count = peopleCount, count > 0 else { return nil }
        if case .beacon = kind { return "\(count) going" }
        return "\(count) here"
    }

    /// When it was posted (beacons and plans; other kinds have no such date).
    var createdAt: Date? {
        switch kind {
        case .beacon(let beacon): beacon.createdAt
        case .hangout(let hangout): hangout.message.createdAt
        case .hub, .person, .place: nil
        }
    }

    /// Momentum for "Rising": people, decayed by age (Hacker News gravity), so a new event filling
    /// up outranks an old one with more RSVPs. Hub and place counts are "right now": no decay.
    func risingScore(now: Date) -> Double {
        guard let people = peopleCount, people > 0 else { return 0 }
        let hours = createdAt.map { max(0, now.timeIntervalSince($0)) / 3600 } ?? 0
        return Double(people) / pow(hours + 2, 1.5)
    }
}

/// How Nearby orders the rows in each section. Relevance is the curated order: live first,
/// events by start, places by live event and Pulse, people nearest first.
enum NearbySort: String, CaseIterable, Identifiable {
    case relevance, distance, rising, new, alphabetical

    static let storageKey = "nearby.sort.v1"

    var id: Self { self }

    var label: String {
        switch self {
        case .relevance: "Relevance"
        case .distance: "Distance"
        case .rising: "Rising"
        case .new: "New"
        case .alphabetical: "Alphabetical"
        }
    }

    var systemImage: String {
        switch self {
        case .relevance: "sparkles"
        case .distance: "location"
        case .rising: "chart.line.uptrend.xyaxis"
        case .new: "clock"
        case .alphabetical: "textformat"
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


    var camera: MapCameraPosition = .automatic
    /// Every fix, unobserved: views read `origin`, so a fix a second doesn't redraw the map and list.
    @ObservationIgnored private(set) var userCoordinate: CLLocationCoordinate2D?
    /// Where Nearby measures distance from: the user's location, moved only after a real move.
    private(set) var origin: CLLocationCoordinate2D?
    private(set) var locationState: LocationState = .notDetermined
    private(set) var discovery = ModuleState<NearbyDiscovery>() { didSet { sourceRevision &+= 1 } }
    /// Beacons fetched individually for a focus intent (e.g. an event outside the fetched radius).
    private(set) var focusedBeacons: [MapBeacon] = [] { didSet { sourceRevision &+= 1 } }
    /// Your plans with a place, from the on-device chat timelines.
    private(set) var hangouts: [PlannedHangout] = [] { didSet { sourceRevision &+= 1 } }
    /// Bumped when an item source changes; derived lists rebuild only when their inputs do.
    private var sourceRevision = 0

    var layers: Set<MapLayer> = Set(MapLayer.allCases)
    /// Nearby Place filters (§6.6), persisted per device.
    var placeFilters: PlaceFilters = PlaceFilters.load() {
        didSet { placeFilters.save() }
    }
    /// Whether the Click Places flag is on for this user.
    var placesEnabled: Bool { environment?.features.isEnabled(.clickPlaces) == true }
    /// Single-layer filter chosen from Nearby chips; applies to the map too.
    var filter: MapLayer?
    /// Nearby row order, persisted per device.
    var sort = NearbySort(rawValue: UserDefaults.standard.string(forKey: NearbySort.storageKey) ?? "") ?? .relevance {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: NearbySort.storageKey) }
    }
    var selection: MapSelection?
    /// Mirrors the router's Nearby stack: the sheet is open exactly while that stack exists.
    var isNearbyPresented: Bool {
        get { environment?.router.nearbyPath != nil }
        set {
            guard newValue != isNearbyPresented else { return }
            environment?.router.nearbyPath = newValue ? [] : nil
        }
    }
    var nearbyDetent: PresentationDetent = .medium

    private var environment: AppEnvironment?
    private var locationTask: Task<Void, Never>?
    private var lastFetchCenter: CLLocationCoordinate2D?
    private var hasCenteredOnUser = false
    private var fetchTask: Task<Void, Never>?
    private let filteredItems = Memo<ItemsKey, [MapItem]>()
    private let allItems = Memo<ItemsKey, [MapItem]>()
    private let sectionsMemo = Memo<SectionsKey, [NearbySection]>()
    private let clustersMemo = Memo<ClustersKey, [MapCluster]>()

    /// Everything the item list depends on. Reading it registers each input with observation,
    /// so a view re-renders when one changes even when the result comes from the memo.
    private struct ItemsKey: Equatable {
        let revision: Int
        let pins: [ConnectionPin]
        let deleted: Set<String>
        let placesEnabled: Bool
        let placeFilters: PlaceFilters
        let layers: Set<MapLayer>
        let filter: MapLayer?
        /// Live and ended are judged to the minute.
        let minute: Int
    }

    private struct SectionsKey: Equatable {
        let items: ItemsKey
        let sort: NearbySort
        let originLatitude: Double?
        let originLongitude: Double?
    }

    private struct ClustersKey: Equatable {
        let items: ItemsKey
        let zoom: Double
    }

    private func itemsKey(pins: [ConnectionPin], filter: MapLayer?, now: Date) -> ItemsKey {
        ItemsKey(
            revision: sourceRevision,
            pins: pins,
            deleted: environment?.router.deletedBeaconIDs ?? [],
            placesEnabled: placesEnabled,
            placeFilters: placeFilters,
            layers: layers,
            filter: filter,
            minute: Int(now.timeIntervalSince1970 / 60)
        )
    }

    func attach(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
    }

    // MARK: - Derived data (map and list read the same items)

    func items(pins: [ConnectionPin], applyingFilter: Bool = true, now: Date = .now) -> [MapItem] {
        let key = itemsKey(pins: pins, filter: applyingFilter ? filter : nil, now: now)
        return (applyingFilter ? filteredItems : allItems)(key) {
            Self.items(
                discovery: discovery.value,
                focusedBeacons: focusedBeacons,
                deleted: key.deleted,
                pins: pins,
                hangouts: hangouts,
                placesEnabled: key.placesEnabled,
                placeFilters: key.placeFilters,
                layers: key.layers,
                filter: key.filter,
                now: now
            )
        }
    }

    /// The map's pins and bubbles: clustering is quadratic, so it reruns only when the items or
    /// the zoom change.
    func clusters(pins: [ConnectionPin]) -> [MapCluster] {
        let zoom = renderZoom
        return clustersMemo(ClustersKey(items: itemsKey(pins: pins, filter: filter, now: .now), zoom: zoom)) {
            Self.clusters(items(pins: pins), zoom: zoom)
        }
    }

    /// Pure item assembly (testable without an environment). With Places on, a Place's official
    /// events render inside its pin: those beacons are dropped from the list (§6.5 event merge).
    nonisolated static func items(
        discovery: NearbyDiscovery?,
        focusedBeacons: [MapBeacon] = [],
        deleted: Set<String> = [],
        pins: [ConnectionPin] = [],
        hangouts: [PlannedHangout] = [],
        placesEnabled: Bool,
        placeFilters: PlaceFilters = .none,
        layers: Set<MapLayer> = Set(MapLayer.allCases),
        filter: MapLayer? = nil,
        now: Date = .now
    ) -> [MapItem] {
        var beacons = (discovery?.beacons ?? []).filter { $0.isActive(at: now) && !deleted.contains($0.id) }
        for focused in focusedBeacons where !beacons.contains(where: { $0.id == focused.id }) {
            beacons.append(focused)
        }
        let places = placesEnabled ? placeFilters.apply(discovery?.places ?? []) : []
        if placesEnabled {
            let placeIDs = Set((discovery?.places ?? []).map(\.id))
            beacons.removeAll { beacon in beacon.venueID.map(placeIDs.contains) ?? false }
        }
        let all = beacons.map { MapItem(kind: .beacon($0)) }
            + places.map { MapItem(kind: .place($0)) }
            + (discovery?.hubs ?? []).map { MapItem(kind: .hub($0)) }
            + pins.map { MapItem(kind: .person($0)) }
            + hangouts.filter { $0.plan.endsOrAssumedEnd > now }.map { MapItem(kind: .hangout($0)) }
        return all.filter { item in
            layers.contains(item.layer) && (filter == nil || filter == item.layer)
        }
    }

    /// Discovery list: live events first, then by layer, then "My network" (the people whose
    /// pins the map shows) — the same items the chip counts come from. Rows follow `sort`.
    func sections(pins: [ConnectionPin], now: Date = .now) -> [NearbySection] {
        let key = SectionsKey(
            items: itemsKey(pins: pins, filter: filter, now: now),
            sort: sort,
            originLatitude: origin?.latitude,
            originLongitude: origin?.longitude
        )
        return sectionsMemo(key) {
            let sections = relevanceSections(pins: pins, now: now)
            guard sort != .relevance else { return sections }
            return sections.map { NearbySection(id: $0.id, title: $0.title, items: Self.sorted($0.items, by: sort, from: origin, now: now)) }
        }
    }

    private func relevanceSections(pins: [ConnectionPin], now: Date) -> [NearbySection] {
        let visible = items(pins: pins, now: now)
        func beaconItems(_ predicate: (MapBeacon) -> Bool) -> [MapItem] {
            visible.filter { if case .beacon(let beacon) = $0.kind { return predicate(beacon) }; return false }
        }
        let live = beaconItems { $0.schedule?.isLive(at: now) == true }
        let upcoming = beaconItems { $0.isEvent && $0.schedule?.isLive(at: now) != true }
            .sorted { lhs, rhs in startDate(lhs) < startDate(rhs) }
        let hubs = visible.filter { if case .hub = $0.kind { return true }; return false }
        let placeSummaries = visible.compactMap { item -> PlaceSummary? in
            if case .place(let place) = item.kind { return place }
            return nil
        }
        let places = PlaceOrdering.sorted(placeSummaries).map { MapItem(kind: .place($0)) }
        let hangouts = visible.filter { if case .hangout = $0.kind { return true }; return false }
        var sections = [
            NearbySection(id: "live", title: "Happening now", items: live),
            NearbySection(id: "hangouts", title: MapLayer.hangouts.label, items: hangouts),
            NearbySection(id: "events", title: "Events", items: upcoming),
            NearbySection(id: "places", title: MapLayer.places.label, items: places),
            NearbySection(id: "hubs", title: "Hubs", items: hubs)
        ]
        for layer in [MapLayer.social, .soundtracks, .alerts, .other] {
            let items = beaconItems { !$0.isEvent && MapLayer(kind: $0.kind) == layer }
            sections.append(NearbySection(id: layer.rawValue, title: layer.label, items: items))
        }
        let people = visible.filter { if case .person = $0.kind { return true }; return false }
        sections.append(NearbySection(id: "people", title: MapLayer.people.label, items: Self.sorted(people, by: .distance, from: origin, now: now)))
        return sections.filter { !$0.items.isEmpty }
    }

    /// Rows in `sort` order (relevance keeps the given order). Ties go nearest first, then A–Z,
    /// so rows don't swap places between rebuilds; without a location, distance is A–Z.
    nonisolated static func sorted(_ items: [MapItem], by sort: NearbySort, from origin: CLLocationCoordinate2D?, now: Date = .now) -> [MapItem] {
        guard sort != .relevance else { return items }
        typealias Keyed = (item: MapItem, distance: Double, created: Date, rising: Double)
        // Keys computed once per item, not once per comparison.
        let keyed: [Keyed] = items.map { item in
            (item, origin.map { distanceMeters($0, item.coordinate) } ?? 0, item.createdAt ?? .distantPast, item.risingScore(now: now))
        }
        func alphabetical(_ a: Keyed, _ b: Keyed) -> Bool? {
            let order = a.item.title.localizedStandardCompare(b.item.title)
            return order == .orderedSame ? nil : order == .orderedAscending
        }
        func nearest(_ a: Keyed, _ b: Keyed) -> Bool {
            a.distance != b.distance ? a.distance < b.distance : alphabetical(a, b) ?? false
        }
        func newest(_ a: Keyed, _ b: Keyed) -> Bool {
            a.created != b.created ? a.created > b.created : nearest(a, b)
        }
        let ordered: [Keyed] = switch sort {
        case .distance, .relevance: keyed.sorted(by: nearest)
        case .alphabetical: keyed.sorted { alphabetical($0, $1) ?? ($0.distance < $1.distance) }
        case .new: keyed.sorted(by: newest)
        case .rising: keyed.sorted { $0.rising != $1.rising ? $0.rising > $1.rising : newest($0, $1) }
        }
        return ordered.map(\.item)
    }

    /// Real counts per layer for the filter chips (before the chip filter is applied).
    func layerCounts(pins: [ConnectionPin]) -> [(layer: MapLayer, count: Int)] {
        let counts = Dictionary(grouping: items(pins: pins, applyingFilter: false), by: \.layer).mapValues(\.count)
        return MapLayer.allCases.compactMap { layer in counts[layer].map { (layer, $0) } }
    }

    func summary(pins: [ConnectionPin]) -> String {
        if locationState == .notDetermined || (locationState == .denied && discovery.value == nil) {
            return "Turn on location to see what's around you"
        }
        if discovery.value == nil {
            return discovery.errorMessage != nil ? "Couldn't load what's nearby" : "Looking around you…"
        }
        let count = items(pins: pins).count
        let live = sections(pins: pins).first { $0.id == "live" }?.items.count ?? 0
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
        environment?.friction.updateLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        if origin.map({ Self.distanceMeters($0, location.coordinate) >= Self.originStepMeters }) ?? true {
            origin = location.coordinate
        }
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
        await loadHangouts()
    }

    func loadHangouts() async {
        guard let userID = environment?.session.currentSession?.userId else { return }
        hangouts = await UpcomingPlans.everywhere(userID: userID).compactMap(PlannedHangout.init)
    }

    /// Coalesces viewport changes: refetches only when the center moved ~5 km from the last fetch
    /// (a tenth of the 50 km discovery radius).
    /// Latitude span of the visible region; clustering kicks in when zoomed out.
    private(set) var visibleLatitudeDelta: Double = 0.05
    /// Pin mode stays on until the zoom clearly drops (hysteresis), and a cluster tap sets a
    /// floor so the zoom it lands on is always shown as individual pins.
    private var stickyPinMode = false
    private var pinRenderZoomFloor: Double?
    /// Pins stacked under a tap, shown in the "Which pin?" chooser.
    var overlapChoices: [MapItem] = []
    /// The item just picked from the chooser: its selection must not reopen the chooser.
    var chosenFromStack: MapSelection?

    /// The zoom clustering renders at (with hysteresis and the post-tap floor applied).
    var renderZoom: Double {
        let zoom = Self.zoom(forLatitudeDelta: visibleLatitudeDelta)
        if let floor = pinRenderZoomFloor { return max(zoom, floor) }
        return stickyPinMode ? max(zoom, Self.clusterThresholdZoom) : zoom
    }

    func noteClusterTap(targetZoom: Double) {
        pinRenderZoomFloor = max(Self.clusterThresholdZoom + 0.25, targetZoom)
    }

    func cameraSettled(center: CLLocationCoordinate2D, latitudeDelta: Double? = nil) {
        if let latitudeDelta {
            visibleLatitudeDelta = latitudeDelta
            let zoom = Self.zoom(forLatitudeDelta: latitudeDelta)
            if zoom >= Self.clusterThresholdZoom { stickyPinMode = true }
            if zoom < Self.pinModeExitZoom {
                stickyPinMode = false
                pinRenderZoomFloor = nil
            }
        }
        guard userCoordinate == nil || locationState == .denied else { return }
        fetchIfMoved(to: center)
    }

    private func fetchIfMoved(to center: CLLocationCoordinate2D) {
        if let last = lastFetchCenter {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            guard moved > 5_000 else { return }
        }
        refresh(around: center)
    }

    /// Beacons changed (live update): refetches the area on screen when the change is near it.
    func beaconsChanged(_ change: BeaconChange) {
        guard let center = lastFetchCenter, change.affects(center) else { return }
        refresh(around: center)
    }

    func refresh() {
        Task { await loadHangouts() }
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
            var firstPageLoaded = false
            do {
                let places: PlaceRepository? = environment.features.isEnabled(.clickPlaces) ? environment.places : nil
                var fresh = try await environment.beacons.discovery(around: center, userID: userID, places: places)
                guard !Task.isCancelled else { return }
                discovery.succeed(fresh)
                firstPageLoaded = true
                // The first page shows at once; the rest of the area fills in behind it (map pins
                // and the Nearby list read the same items). A new fetch cancels this.
                var pages = 1
                while pages < Self.maxDiscoveryPages, !Task.isCancelled,
                      let more = try await environment.beacons.moreBeacons(for: fresh, userID: userID) {
                    guard !Task.isCancelled else { return }
                    fresh = more
                    discovery.succeed(more)
                    pages += 1
                }
            } catch {
                guard !Task.isCancelled else { return }
                // A later page failing keeps what already loaded.
                if !firstPageLoaded { discovery.fail(error) }
            }
        }
    }

    /// How far the user moves before Nearby distances and the distance order update.
    static let originStepMeters: Double = 50

    /// Safety ceiling for one area (25 × 200 = 5,000 beacons).
    static let maxDiscoveryPages = 25

    // MARK: - Focus & selection

    /// Consumes a "show on map" intent from Home, Saved Events, notifications, or deep links.
    func consume(_ focus: MapFocus) async {
        switch focus {
        case .layer(let layer):
            filter = layer
            layers.insert(layer)
            isNearbyPresented = true
            nearbyDetent = .medium
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
            isNearbyPresented = false
            focusCamera(on: beacon.coordinate)
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
        isNearbyPresented = false
        // Warm the beacon's page (listening, reactions, alert status, drops) before it opens.
        if let environment, let beacon = beacon(for: selection) { environment.beaconExtras.prefetch(beacon, env: environment) }
        focusCamera(on: coordinate)
    }

    func focusCamera(on coordinate: CLLocationCoordinate2D) {
        withAnimation {
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    func beacon(for selection: MapSelection?) -> MapBeacon? {
        guard case .beacon(let id) = selection else { return nil }
        return (discovery.value?.beacons ?? []).first { $0.id == id } ?? focusedBeacons.first { $0.id == id }
    }

    // MARK: - Private


    private func startDate(_ item: MapItem) -> Date {
        if case .beacon(let beacon) = item.kind { return beacon.schedule?.start ?? .distantFuture }
        return .distantFuture
    }
}

/// One remembered derived value, recomputed only when its key changes.
private final class Memo<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    func callAsFunction(_ key: Key, _ make: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = make()
        entry = (key, value)
        return value
    }
}

/// A group of nearby map items drawn as one bubble when zoomed out.
struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let items: [MapItem]
}

/// Clustering and overlap rules ported from the Kotlin app (`MapUtils.kt`,
/// `MapViewModelCamera.kt`, `MapViewModelInteractions.kt`) so both clients group pins alike.
extension MapFeatureModel {
    /// At or above this zoom every pin is drawn individually.
    nonisolated static let clusterThresholdZoom: Double = 12
    /// Pin mode, once entered, holds until the zoom drops below this (no flicker at the edge).
    nonisolated static let pinModeExitZoom: Double = clusterThresholdZoom - 0.75
    /// Kept for callers that size zooms relative to the old span threshold (~9 km).
    nonisolated static let clusteringSpan: Double = 0.08

    /// Web-Mercator zoom for a visible latitude span.
    nonisolated static func zoom(forLatitudeDelta delta: Double) -> Double {
        log2(360 / max(delta, 0.000_01))
    }

    nonisolated static func latitudeDelta(forZoom zoom: Double) -> Double {
        360 / pow(2, zoom)
    }

    /// Radius within which pins merge, stepped by zoom (KMP `determineMapRenderData`).
    nonisolated static func clusterRadiusMeters(zoom: Double) -> Double {
        switch zoom {
        case ..<6: 10_000
        case ..<8: 5_000
        case ..<10: 1_000
        default: 500
        }
    }

    /// Kinds that are always drawn on their own (KMP: soundtrack, hazard, SOS, utility, event).
    nonisolated static func neverClusters(_ item: MapItem) -> Bool {
        guard case .beacon(let beacon) = item.kind else { return false }
        switch beacon.kind {
        case .soundtrack, .hazard, .sos, .utility, .event: return true
        default: return false
        }
    }

    nonisolated static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Greedy single-pass clustering in input order (KMP `clusterUnifiedMembers`). Below the
    /// threshold zoom, members within the zoom's radius of a seed merge into one bubble.
    nonisolated static func clusters(_ items: [MapItem], zoom: Double) -> [MapCluster] {
        let singles = { (item: MapItem) in MapCluster(id: "\(item.id)", coordinate: item.coordinate, items: [item]) }
        guard zoom < clusterThresholdZoom else { return items.map(singles) }
        let radius = clusterRadiusMeters(zoom: zoom)
        var result: [MapCluster] = items.filter(neverClusters).map(singles)
        let members = items.filter { !neverClusters($0) }
        var assigned = Set<MapSelection>()
        for seed in members where !assigned.contains(seed.id) {
            let nearby = members.filter { !assigned.contains($0.id) && distanceMeters(seed.coordinate, $0.coordinate) <= radius }
            for member in nearby { assigned.insert(member.id) }
            if nearby.count == 1 {
                result.append(singles(nearby[0]))
                continue
            }
            let lat = nearby.map(\.coordinate.latitude).reduce(0, +) / Double(nearby.count)
            let lon = nearby.map(\.coordinate.longitude).reduce(0, +) / Double(nearby.count)
            let key = nearby.map { "\($0.id)" }.sorted().joined(separator: "|")
            result.append(MapCluster(id: "cluster.\(key.hashValue)", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), items: nearby))
        }
        return result
    }

    /// Metres covered by one pin at this zoom and latitude (44 pt pin × 0.85, clamped 12–90 m),
    /// KMP `mapPinOverlapRadiusMeters`.
    nonisolated static func overlapRadiusMeters(latitude: Double, zoom: Double, pinDiameter: Double = 44) -> Double {
        let clampedZoom = min(max(zoom, 2), 22)
        let clampedLat = min(max(latitude, -85), 85)
        let metersPerPoint = 156_543.033_92 * cos(clampedLat * .pi / 180) / pow(2, clampedZoom)
        return min(max(pinDiameter * 0.85 * metersPerPoint, 12), 90)
    }

    /// Every drawn pin stacked under the tapped one (itself included), for the "Which pin?"
    /// chooser (KMP `overlappingMapPins`).
    nonisolated static func overlapping(_ tapped: MapItem, in items: [MapItem], zoom: Double) -> [MapItem] {
        let radius = overlapRadiusMeters(latitude: tapped.coordinate.latitude, zoom: zoom)
        var seen = Set<MapSelection>()
        return ([tapped] + items.filter { distanceMeters(tapped.coordinate, $0.coordinate) <= radius })
            .filter { seen.insert($0.id).inserted }
    }

    /// Zoom a cluster tap lands on: fits the members, never short of pin mode (KMP step table).
    nonisolated static func zoomToFit(_ cluster: MapCluster) -> Double {
        let lats = cluster.items.map(\.coordinate.latitude)
        let lons = cluster.items.map(\.coordinate.longitude)
        let span = max((lats.max() ?? 0) - (lats.min() ?? 0), (lons.max() ?? 0) - (lons.min() ?? 0))
        let fit: Double = switch span {
        case 10...: 4
        case 5...: 6
        case 1...: 8
        case 0.1...: 10
        case 0.01...: 12
        case 0.001...: 14
        default: 16
        }
        return max(clusterThresholdZoom + 1, fit)
    }
}
