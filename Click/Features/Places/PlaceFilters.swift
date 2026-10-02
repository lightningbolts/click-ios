import Foundation

/// Place filters (click-web spec §4.6, §6.6): the replacement for display thresholds. AND across
/// fields, OR within the set fields. Must match web `lib/places/filters.ts` exactly; both suites
/// assert against the shared fixture `Fixtures/place_filters.json`.
public struct PlaceFilters: Codable, Equatable, Sendable {
    public var categories: Set<PlaceCategory> = []
    public var pulseNow = false
    /// UI choices: Any (0), 2+, 5+, 10+.
    public var minReports = 0
    public var energies: Set<EnergyLabel> = []
    public var eventsToday = false
    public var openNow = false
    public var beenHere = false
    public var clicksBeenHere = false
    public var hasHub = false
    public var hereNow = false

    public static let none = PlaceFilters()
    public var isActive: Bool { self != PlaceFilters.none }

    public init() {}

    public func matches(_ place: PlaceSummary) -> Bool {
        let live = place.pulse.state == .live
        if !categories.isEmpty && !categories.contains(place.category) { return false }
        if pulseNow && !live { return false }
        if minReports > 0 && !(live && place.pulse.reportCount >= minReports) { return false }
        if !energies.isEmpty {
            guard live, let label = place.pulse.label, energies.contains(label) else { return false }
        }
        if eventsToday && !(place.eventsTodayCount > 0 || place.nextEvent?.isLive == true) { return false }
        if openNow && place.openNow != true { return false }
        if beenHere && place.viewer?.hasHistory != true { return false }
        if clicksBeenHere && !((place.viewer?.connectionsBeenHereCount ?? 0) > 0) { return false }
        if hasHub && place.hubID == nil { return false }
        if hereNow && !(place.hereNowCount > 0) { return false }
        return true
    }

    public func apply(_ places: [PlaceSummary]) -> [PlaceSummary] {
        places.filter(matches)
    }

    // MARK: - Persistence (UserDefaults `places.filters.v1`; a corrupt value falls back to none)

    static let storageKey = "places.filters.v1"

    static func load(from defaults: UserDefaults = .standard) -> PlaceFilters {
        guard let data = defaults.data(forKey: storageKey),
              let filters = try? JSONDecoder().decode(PlaceFilters.self, from: data) else { return PlaceFilters.none }
        return filters
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Places in the Nearby list: live event first, then live Pulse (newest first), then distance.
enum PlaceOrdering {
    static func sorted(_ places: [PlaceSummary]) -> [PlaceSummary] {
        places.sorted { a, b in
            let aLive = a.nextEvent?.isLive == true
            let bLive = b.nextEvent?.isLive == true
            if aLive != bLive { return aLive }
            let aPulse = a.pulse.state == .live ? a.pulse.newestAt : nil
            let bPulse = b.pulse.state == .live ? b.pulse.newestAt : nil
            switch (aPulse, bPulse) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.distanceMeters ?? .infinity) < (b.distanceMeters ?? .infinity)
            }
        }
    }
}
