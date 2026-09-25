import CoreLocation
import Foundation
import Observation

/// The single highest-priority social opportunity Home promotes (spec §20.2 item 3).
enum HomeOpportunity: Equatable, Identifiable {
    /// A live or imminent event the user saved, or one happening nearby.
    case event(HomeEventHighlight)
    /// A server nudge: reconnect lull or a shared upcoming event.
    case nudge(InboxNudge)
    /// A new connection that must be greeted before the server's 48-hour gentle archive.
    case sayHi(ConnectionItem, deadline: Date)

    var id: String {
        switch self {
        case .event(let event): "event.\(event.id)"
        case .nudge(let nudge): "nudge.\(nudge.id)"
        case .sayHi(let item, _): "sayhi.\(item.id)"
        }
    }

    /// Deterministic priority (unit-tested):
    /// 1. a saved event that is live now;
    /// 2. a saved event starting today;
    /// 3. a nearby event that is live now;
    /// 4. a shared-upcoming-event nudge;
    /// 5. a greeting deadline expiring within 12 hours;
    /// 6. a reconnect nudge;
    /// 7. a nearby event starting today.
    static func select(
        savedEvents: [SavedEvent],
        nearbyBeacons: [MapBeacon],
        nudges: [InboxNudge],
        connections: [ConnectionItem],
        now: Date = .now
    ) -> HomeOpportunity? {
        let saved = savedEvents
            .filter { $0.isUpcomingOrLive(at: now) && $0.schedule != nil }
            .sorted { $0.schedule!.start < $1.schedule!.start }
        let savedIDs = Set(saved.map(\.beaconID))
        let nearbyEvents = nearbyBeacons
            .filter { $0.isEvent && $0.isActive(at: now) && $0.schedule != nil && !savedIDs.contains($0.id) }
            .sorted { $0.schedule!.start < $1.schedule!.start }

        if let live = saved.first(where: { $0.schedule!.isLive(at: now) }) {
            return .event(HomeEventHighlight(saved: live, now: now))
        }
        if let today = saved.first(where: { $0.schedule!.startsToday(at: now) }) {
            return .event(HomeEventHighlight(saved: today, now: now))
        }
        if let live = nearbyEvents.first(where: { $0.schedule!.isLive(at: now) }) {
            return .event(HomeEventHighlight(beacon: live, now: now))
        }
        if let shared = nudges.first(where: { $0.kind == .sharedUpcomingEvent }) {
            return .nudge(shared)
        }
        if let urgent = connections
            .compactMap({ item in item.sayHiDeadline.map { (item, $0) } })
            .filter({ $0.1 > now && $0.1.timeIntervalSince(now) <= 12 * 3600 })
            .min(by: { $0.1 < $1.1 }) {
            return .sayHi(urgent.0, deadline: urgent.1)
        }
        if let reconnect = nudges.first(where: { $0.kind == .reconnectLull }) {
            return .nudge(reconnect)
        }
        if let today = nearbyEvents.first(where: { $0.schedule!.startsToday(at: now) }) {
            return .event(HomeEventHighlight(beacon: today, now: now))
        }
        return nil
    }
}

/// Presentation data for the Home event hero, from a saved event or a nearby beacon.
struct HomeEventHighlight: Equatable, Identifiable {
    let id: String
    let title: String
    let schedule: EventSchedule
    let place: String?
    let imageURL: String?
    let isLive: Bool
    let isSaved: Bool

    init(saved: SavedEvent, now: Date) {
        id = saved.beaconID
        title = saved.title ?? "Saved event"
        schedule = saved.schedule!
        place = saved.placeLabel
        imageURL = nil
        isLive = saved.schedule!.isLive(at: now)
        isSaved = true
    }

    init(beacon: MapBeacon, now: Date) {
        id = beacon.id
        title = beacon.title
        schedule = beacon.schedule!
        place = beacon.locationName ?? beacon.formattedAddress
        imageURL = beacon.imageURL
        isLive = beacon.schedule!.isLive(at: now)
        isSaved = false
    }
}

/// Owns Home's independently loadable modules (spec §20.2 "Loading architecture").
///
/// The scaffold renders immediately; each module seeds from cache, then refreshes concurrently
/// and updates only its own state. People and insights come from the shell-owned
/// `ConversationListModel` so Home never refetches the inbox.
@Observable
@MainActor
final class HomeFeedModel {
    private(set) var firstName: String?
    private(set) var intents = ModuleState<[AvailabilityIntentPost]>()
    private(set) var savedEvents = ModuleState<[SavedEvent]>()
    private(set) var nudges = ModuleState<[InboxNudge]>()
    private(set) var discovery = ModuleState<NearbyDiscovery>()
    private(set) var recaps: [ActivityRecap.Window: ModuleState<ActivityRecap>] = [:]
    var recapWindow: ActivityRecap.Window = .week

    /// Nudges resolved this session; hidden immediately even if a stale fetch returns them.
    private var resolvedNudgeIDs: Set<String> = []
    private var environment: AppEnvironment?
    private var refreshTask: Task<Void, Never>?
    private var hasLoaded = false

    init() {}

    var recap: ModuleState<ActivityRecap> {
        recaps[recapWindow] ?? ModuleState()
    }

    var visibleNudges: [InboxNudge] {
        (nudges.value ?? []).filter { !resolvedNudgeIDs.contains($0.id) }
    }

    /// A module is showing cached data because its last refresh failed (not cancelled).
    /// Whether that reads as "Offline" is decided by `NetworkMonitor`, not by this flag.
    var hasRefreshFailure: Bool {
        [intents.isStale, savedEvents.isStale, nudges.isStale, discovery.isStale, recap.isStale].contains(true)
    }

    var hasCachedData: Bool {
        intents.value != nil || savedEvents.value != nil || nudges.value != nil || discovery.value != nil || recap.value != nil
    }

    func opportunity(connections: [ConnectionItem], now: Date = .now) -> HomeOpportunity? {
        HomeOpportunity.select(
            savedEvents: savedEvents.value ?? [],
            nearbyBeacons: discovery.value?.beacons ?? [],
            nudges: visibleNudges,
            connections: connections,
            now: now
        )
    }

    /// Saved events that are still upcoming/live, soonest first, excluding the promoted event.
    func upcomingSaved(excluding promotedID: String?, now: Date = .now) -> [SavedEvent] {
        (savedEvents.value ?? [])
            .filter { $0.isUpcomingOrLive(at: now) && $0.beaconID != promotedID }
            .sorted { ($0.schedule?.start ?? .distantFuture) < ($1.schedule?.start ?? .distantFuture) }
    }

    // MARK: - Loading

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Seeds cached modules on first appearance, then refreshes. Later appearances do nothing;
    /// pull-to-refresh and foregrounding call `refresh()`.
    func loadIfNeeded() async {
        guard !hasLoaded, let environment, let userID else { return }
        hasLoaded = true
        await seedFromCache(environment, userID: userID)
        // Let the cached frame commit before network work competes for the main actor.
        await Task.yield()
        await refresh()
    }

    /// Refreshes every module concurrently; concurrent callers share one pass.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func selectRecapWindow(_ window: ActivityRecap.Window) async {
        recapWindow = window
        guard recaps[window]?.isFresh != true else { return }
        await loadRecap(window)
    }

    func reloadIntents() async {
        await loadIntents()
    }

    /// Clicks whose live availability overlaps the viewer's (empty until the viewer shares one).
    private(set) var overlappingPeerIDs: Set<String> = []

    func loadOverlaps(peerIDs: [String]) async {
        guard let environment, !(intents.value ?? []).isEmpty else {
            overlappingPeerIDs = []
            return
        }
        // Best effort: a failed lookup keeps the last answer rather than flashing the card away.
        if let overlaps = try? await environment.me.availabilityOverlaps(peerIDs: peerIDs) {
            overlappingPeerIDs = overlaps
        }
    }

    /// "Lena is also free", "Lena and Sam are also free", "3 Clicks are also free".
    nonisolated static func overlapTitle(names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(names[0]) is also free"
        case 2: "\(names[0]) and \(names[1]) are also free"
        default: "\(names.count) Clicks are also free"
        }
    }

    /// Hides a nudge immediately and records the outcome; a failed dismissal restores it.
    func resolveNudge(_ nudge: InboxNudge, action: MeRepository.NudgeAction) async {
        guard let environment, let userID else { return }
        resolvedNudgeIDs.insert(nudge.id)
        do {
            try await environment.me.resolveNudge(nudge.id, action: action, userID: userID)
        } catch {
            if action == .dismiss { resolvedNudgeIDs.remove(nudge.id) }
        }
    }

    // MARK: - Private

    private var userID: String? { environment?.session.currentSession?.userId }

    private func seedFromCache(_ environment: AppEnvironment, userID: String) async {
        if let cached = await environment.me.cachedSelfProfile(userID: userID) {
            firstName = cached.firstName.nonEmptyTrimmed ?? Self.firstName(cached.displayName)
        }
        intents.seed(await environment.me.cachedIntents(userID: userID))
        savedEvents.seed(await environment.beacons.cachedBookmarks(userID: userID))
        nudges.seed(await environment.me.cachedNudges(userID: userID))
        for window in ActivityRecap.Window.allCases {
            var state = ModuleState<ActivityRecap>()
            state.seed(await environment.me.cachedRecap(window: window, userID: userID))
            recaps[window] = state
        }
        if environment.location.isAuthorized {
            discovery.seed(await environment.beacons.cachedDiscovery(userID: userID))
        }
    }

    private func performRefresh() async {
        async let identity: Void = loadIdentity()
        async let intents: Void = loadIntents()
        async let saved: Void = loadSavedEvents()
        async let nudges: Void = loadNudges()
        async let recap: Void = loadRecap(recapWindow)
        async let discovery: Void = loadDiscovery()
        _ = await (identity, intents, saved, nudges, recap, discovery)
    }

    private func loadIdentity() async {
        guard let environment, let userID else { return }
        if let identity = try? await environment.phase3.identity(userID: userID), !identity.firstName.isEmpty {
            firstName = identity.firstName
        }
    }

    private func loadIntents() async {
        guard let environment, let userID else { return }
        intents.begin()
        do {
            intents.succeed(try await environment.me.availabilityIntents(userID: userID))
        } catch {
            intents.fail(error)
        }
    }

    private func loadSavedEvents() async {
        guard let environment, let userID else { return }
        savedEvents.begin()
        do {
            savedEvents.succeed(try await environment.beacons.bookmarks(userID: userID))
        } catch {
            savedEvents.fail(error)
        }
    }

    private func loadNudges() async {
        guard let environment, let userID else { return }
        nudges.begin()
        do {
            nudges.succeed(try await environment.me.nudges(userID: userID))
        } catch {
            nudges.fail(error)
        }
    }

    private func loadRecap(_ window: ActivityRecap.Window) async {
        guard let environment, let userID else { return }
        var state = recaps[window] ?? ModuleState()
        state.begin()
        recaps[window] = state
        do {
            state.succeed(try await environment.me.recap(window: window, userID: userID))
        } catch {
            state.fail(error)
        }
        recaps[window] = state
    }

    /// Discovery needs location, which Home never requests on its own (spec §14): without
    /// existing authorization the module is unavailable rather than empty.
    private func loadDiscovery() async {
        guard let environment, let userID else { return }
        guard environment.location.isAuthorized else {
            discovery.markUnavailable("Turn on location in Map to see what's live near you.")
            return
        }
        discovery.begin()
        guard let location = await environment.location.currentLocation() else {
            // A missing fix is a location problem, not a network one: keep any cached value
            // and don't flag the module as a failed refresh.
            if discovery.value == nil {
                discovery.markUnavailable("Couldn't find your location.")
            } else {
                discovery.succeedKeepingValue()
            }
            return
        }
        do {
            discovery.succeed(try await environment.beacons.discovery(around: location.coordinate, userID: userID))
        } catch {
            discovery.fail(error)
        }
    }

    static func firstName(_ displayName: String) -> String? {
        displayName.split(separator: " ").first.map(String.init)
    }
}

/// The time-of-day salutation shown as Home's expanded title.
enum HomeGreeting {
    static func salutation(for name: String?, date: Date = .now, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let prefix = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello"
        }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? prefix : "\(prefix), \(clean)"
    }
}
