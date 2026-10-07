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


    /// Opens where the map was last left (usually around you), so it never starts zoomed out to
    /// every pin and then jumps to your location on the first fix.
    var camera: MapCameraPosition = MapFeatureModel.restoredRegion.map { .region($0) } ?? .automatic
    /// The region `camera` opened on, if any.
    private let openedRegion = MapFeatureModel.restoredRegion
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

    /// The map's pins and stacks, rebuilt only when the items or the zoom step change. Pins merge
    /// a Place's events into it; lists and counts keep every event.
    func clusters(pins: [ConnectionPin]) -> [MapCluster] {
        let zoom = clusterZoom
        return clustersMemo(ClustersKey(items: itemsKey(pins: pins, filter: filter, now: .now), zoom: zoom)) {
            Self.clusters(Self.mergingPlaceEvents(items(pins: pins)), zoom: zoom)
        }
    }

    /// Pure item assembly (testable without an environment).
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
        let all = beacons.map { MapItem(kind: .beacon($0)) }
            + places.map { MapItem(kind: .place($0)) }
            + (discovery?.hubs ?? []).map { MapItem(kind: .hub($0)) }
            + pins.map { MapItem(kind: .person($0)) }
            + hangouts.filter { $0.plan.endsOrAssumedEnd > now }.map { MapItem(kind: .hangout($0)) }
        return all.filter { item in
            layers.contains(item.layer) && (filter == nil || filter == item.layer)
        }
    }

    /// §6.5 event merge, for map pins: an official event held at a Place on the map rides in its
    /// pin instead of stacking a second pin on it. An event the Place hosts somewhere else, or
    /// whose Place is filtered out, keeps its own pin.
    nonisolated static func mergingPlaceEvents(_ items: [MapItem]) -> [MapItem] {
        var places: [String: PlaceSummary] = [:]
        for item in items { if case .place(let place) = item.kind { places[place.id] = place } }
        guard !places.isEmpty else { return items }
        return items.filter { item in
            guard case .beacon(let beacon) = item.kind, let place = beacon.venueID.flatMap({ places[$0] }) else { return true }
            return distanceMeters(beacon.coordinate, place.coordinate) > Double(place.radiusMeters) + placeMergeSlackMeters
        }
    }

    /// How far past a Place's radius its event may sit and still merge (geocoding drift).
    nonisolated static let placeMergeSlackMeters: Double = 100

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
            // Already showing your area (where the map was left): stay. Otherwise glide over.
            let showing = openedRegion.map { Self.distanceMeters($0.center, location.coordinate) < Self.recenterMeters } ?? false
            if !showing {
                withAnimation(.smooth(duration: 0.6)) {
                    camera = .region(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000))
                }
            }
        }
        fetchIfMoved(to: location.coordinate)
    }

    // MARK: - Discovery

    func loadCached() async {
        guard let environment, let userID = environment.session.currentSession?.userId else { return }
        discovery.seed(await environment.beacons.cachedDiscovery(userID: userID))
        prefetchThumbnails()
        await loadHangouts()
    }

    func loadHangouts() async {
        guard let userID = environment?.session.currentSession?.userId else { return }
        hangouts = await UpcomingPlans.everywhere(userID: userID).compactMap(PlannedHangout.init)
    }

    /// Latitude span of the visible region (kept to reopen the map where it was left). Unobserved,
    /// like the center below: the map redraws only when `clusterZoom` changes, not after every pan.
    @ObservationIgnored private(set) var visibleLatitudeDelta: Double = 0.05
    /// The middle of the map on screen (where "+" creates a beacon when there's no location).
    @ObservationIgnored private(set) var visibleCenter: CLLocationCoordinate2D?
    /// The map's Web-Mercator zoom in quarter steps (rounded down, so stacks err toward merging):
    /// what pins are stacked at. Small zooms and pans leave it, and so the pins, as they are.
    private(set) var clusterZoom: Double = 14
    /// The stack whose list sheet is open.
    var openStack: MapCluster?

    /// - Parameters:
    ///   - visibleRect: the map rect on screen; with `viewWidth` (points) it gives the true zoom,
    ///     which stacking needs because it works in on-screen points.
    func cameraSettled(center: CLLocationCoordinate2D, latitudeDelta: Double? = nil, visibleRect: MKMapRect? = nil, viewWidth: Double? = nil) {
        visibleCenter = center
        if let visibleRect, let viewWidth, viewWidth > 0, visibleRect.size.width > 0 {
            let step = Self.zoomStep(Self.zoom(mapPointsPerPoint: visibleRect.size.width / viewWidth))
            if step != clusterZoom { clusterZoom = step }
        }
        if let latitudeDelta {
            visibleLatitudeDelta = latitudeDelta
            Self.restoredRegion = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: latitudeDelta))
        }
        guard userCoordinate == nil || locationState == .denied else { return }
        fetchIfMoved(to: center)
    }

    nonisolated static func zoomStep(_ zoom: Double) -> Double { (zoom * 4).rounded(.down) / 4 }

    /// Sign-out: the next account's map doesn't open on this one's area.
    nonisolated static func forgetLastRegion() { restoredRegion = nil }

    /// Where the map was last left, kept across launches.
    private nonisolated static var restoredRegion: MKCoordinateRegion? {
        get {
            guard let values = UserDefaults.standard.array(forKey: "map.lastRegion.v1") as? [Double], values.count == 3,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: values[0], longitude: values[1])),
                  values[2] > 0 else { return nil }
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: values[0], longitude: values[1]),
                                      span: MKCoordinateSpan(latitudeDelta: values[2], longitudeDelta: values[2]))
        }
        set {
            guard let region = newValue else { return UserDefaults.standard.removeObject(forKey: "map.lastRegion.v1") }
            UserDefaults.standard.set([region.center.latitude, region.center.longitude, region.span.latitudeDelta], forKey: "map.lastRegion.v1")
        }
    }

    /// Coalesces viewport changes: refetches only when the center moved ~5 km from the last fetch
    /// (a tenth of the 50 km discovery radius).
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
                prefetchThumbnails()
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

    /// Decodes the first pins' pictures at thumbnail size, so pins and Nearby rows paint them on
    /// their first frame instead of swapping them in.
    private func prefetchThumbnails() {
        guard let value = discovery.value else { return }
        let beacons: [String?] = value.beacons.compactMap(\.imageURL).prefix(Self.prefetchedThumbnails).map { $0 }
        let places: [String?] = value.places.compactMap(\.photoURL?.absoluteString).prefix(Self.prefetchedThumbnails).map { $0 }
        EventVisual.prefetch(beacons + places, maxPixelSize: EventVisual.thumbnailPixelSize)
    }

    static let prefetchedThumbnails = 60

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

/// Map items whose pins would overlap on screen, drawn as one stack (Luma-style) and listed in a
/// sheet when tapped. A lone item is a cluster of one.
struct MapCluster: Identifiable, Equatable {
    let id: String
    /// Where the stack sits: its lead's spot, so the most important pin never moves.
    let coordinate: CLLocationCoordinate2D
    /// Most important first (see `MapItem.stackRank`); never empty.
    let items: [MapItem]

    var lead: MapItem { items[0] }

    static func == (lhs: MapCluster, rhs: MapCluster) -> Bool { lhs.id == rhs.id && lhs.items == rhs.items }
}

extension MapItem {
    /// A Core Click's pin wears the gold ring.
    var isCoreConnection: Bool {
        if case .person(let pin) = kind { return pin.isCore }
        return false
    }

    /// Which item leads a stack and the order its list reads: alerts (so one is never hidden
    /// under another pin), live events, then events (soonest first), Places, hubs, other beacons,
    /// plans, Core Clicks, then everyone else.
    func stackRank(now: Date) -> Int {
        switch kind {
        case .beacon(let beacon):
            if beacon.kind == .hazard || beacon.kind == .sos { return -1 }
            if beacon.isEvent { return beacon.schedule?.isLive(at: now) == true ? 0 : 1 }
            return 4
        case .place: return 2
        case .hub: return 3
        case .hangout: return 5
        case .person(let pin): return pin.isCore ? 6 : 7
        }
    }

    static func stackOrder(_ a: MapItem, _ b: MapItem, now: Date) -> Bool {
        let (rankA, rankB) = (a.stackRank(now: now), b.stackRank(now: now))
        if rankA != rankB { return rankA < rankB }
        let (startA, startB) = (a.eventStart ?? .distantFuture, b.eventStart ?? .distantFuture)
        if startA != startB { return startA < startB }
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? "\(a.id)" < "\(b.id)" : order == .orderedAscending
    }

    private var eventStart: Date? {
        if case .beacon(let beacon) = kind { return beacon.schedule?.start }
        return nil
    }
}

/// Stacking: pins merge exactly when they would overlap on screen, at every zoom, so the map
/// never draws one face over another (spec §49.2, Luma's map).
extension MapFeatureModel {
    /// Pins whose centres are closer than this on screen (points) would collide: a 40 pt face
    /// with its 3 pt edge, plus room for a stack's fan (13 pt each side) so stacks clear too.
    nonisolated static let stackDistance: Double = 60
    /// Members this close together can't be told apart at any zoom: the list offers no zoom.
    nonisolated static let sameSpotMeters: Double = 20
    /// A map opening within this of you is left where it was rather than recentered.
    nonisolated static let recenterMeters: Double = 3_000

    /// Web-Mercator zoom (256 pt world tiles) for an on-screen scale.
    nonisolated static func zoom(mapPointsPerPoint: Double) -> Double {
        log2(MKMapSize.world.width / 256 / max(mapPointsPerPoint, 0.000_001))
    }

    nonisolated static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Walking items most important first, each unclaimed item takes every unclaimed item whose
    /// pin would overlap its own at `zoom`. A grid of `stackDistance` cells keeps this close to
    /// linear for thousands of pins.
    nonisolated static func clusters(_ items: [MapItem], zoom: Double, now: Date = .now) -> [MapCluster] {
        let ordered = items.sorted { MapItem.stackOrder($0, $1, now: now) }
        // On-screen points per map point at this zoom.
        let scale = 256 * pow(2, zoom) / MKMapSize.world.width
        let points = ordered.map { item -> (x: Double, y: Double) in
            let point = MKMapPoint(item.coordinate)
            return (point.x * scale, point.y * scale)
        }
        struct Cell: Hashable { let x: Int; let y: Int }
        func cell(_ point: (x: Double, y: Double)) -> Cell {
            Cell(x: Int((point.x / stackDistance).rounded(.down)), y: Int((point.y / stackDistance).rounded(.down)))
        }
        var grid: [Cell: [Int]] = [:]
        for index in ordered.indices {
            grid[cell(points[index]), default: []].append(index)
        }
        var claimed = [Bool](repeating: false, count: ordered.count)
        var result: [MapCluster] = []
        for seed in ordered.indices where !claimed[seed] {
            claimed[seed] = true
            var members = [seed]
            let home = cell(points[seed])
            for dx in -1...1 {
                for dy in -1...1 {
                    for other in grid[Cell(x: home.x + dx, y: home.y + dy)] ?? [] where !claimed[other] {
                        let distance = hypot(points[other].x - points[seed].x, points[other].y - points[seed].y)
                        guard distance < stackDistance else { continue }
                        claimed[other] = true
                        members.append(other)
                    }
                }
            }
            // Indices follow the stack order, so sorting them keeps the lead first.
            members.sort()
            let group = members.map { ordered[$0] }
            result.append(MapCluster(id: group.count == 1 ? "\(group[0].id)" : "stack.\(group[0].id)",
                                     coordinate: group[0].coordinate, items: group))
        }
        return result
    }

    /// Whether zooming in could pull a stack apart (its members aren't all at one spot).
    nonisolated static func canSeparate(_ cluster: MapCluster) -> Bool {
        cluster.items.contains { distanceMeters(cluster.coordinate, $0.coordinate) > sameSpotMeters }
    }

    /// A region showing every member with room around them, close enough that they separate.
    nonisolated static func region(fitting cluster: MapCluster) -> MKCoordinateRegion {
        let lats = cluster.items.map(\.coordinate.latitude)
        let lons = cluster.items.map(\.coordinate.longitude)
        let (minLat, maxLat) = (lats.min() ?? 0, lats.max() ?? 0)
        let (minLon, maxLon) = (lons.min() ?? 0, lons.max() ?? 0)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.8, 0.003),
                                   longitudeDelta: max((maxLon - minLon) * 1.8, 0.003))
        )
    }
}
