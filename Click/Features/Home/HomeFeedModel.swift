import CoreLocation
import Foundation
import Observation
import SwiftUI

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
    /// 4. a hangout waiting for your confirmation (it expires);
    /// 5. a shared-upcoming-event nudge;
    /// 6. a wave;
    /// 7. a greeting deadline expiring within 12 hours;
    /// 8. an anniversary;
    /// 9. a reconnect nudge;
    /// 10. a memory prompt, then a quiet group;
    /// 11. a nearby event starting today.
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
        if let hangout = nudges.first(where: { $0.kind == .hangoutConfirm }) {
            return .nudge(hangout)
        }
        if let shared = nudges.first(where: { $0.kind == .sharedUpcomingEvent }) {
            return .nudge(shared)
        }
        if let wave = nudges.first(where: { $0.kind == .wave }) {
            return .nudge(wave)
        }
        if let urgent = connections
            .compactMap({ item in item.sayHiDeadline.map { (item, $0) } })
            .filter({ $0.1 > now && $0.1.timeIntervalSince(now) <= 12 * 3600 })
            .min(by: { $0.1 < $1.1 }) {
            return .sayHi(urgent.0, deadline: urgent.1)
        }
        for kind in [InboxNudge.Kind.anniversary, .reconnectLull, .memoryPrompt, .groupRevival] {
            if let nudge = nudges.first(where: { $0.kind == kind }) { return .nudge(nudge) }
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

/// An event on your plate, for Home's Upcoming: one you host, are going to, or saved.
struct HomeUpcomingEvent: Identifiable, Equatable {
    enum Role: Equatable {
        case hosting, going, saved

        var label: String {
            switch self {
            case .hosting: "Hosting"
            case .going: "Going"
            case .saved: "Saved"
            }
        }
    }

    let id: String
    let title: String
    let schedule: EventSchedule
    let place: String?
    let imageURL: String?
    let role: Role

    /// Hosting and going first-hand (`/api/beacons/mine`), then saved events not already there;
    /// soonest first, nothing that has ended, and not the event Home's hero already shows.
    static func merge(mine: [MyEvent], saved: [SavedEvent], excluding promotedID: String?, now: Date) -> [HomeUpcomingEvent] {
        var events: [HomeUpcomingEvent] = mine.compactMap { event in
            guard let schedule = EventSchedule(start: event.start, end: event.end), !schedule.isEnded(at: now) else { return nil }
            return HomeUpcomingEvent(id: event.beaconID, title: event.title, schedule: schedule, place: event.place,
                                     imageURL: event.imageURL, role: event.isHost ? .hosting : .going)
        }
        let known = Set(events.map(\.id))
        events += saved.compactMap { event in
            guard !known.contains(event.beaconID), event.isUpcomingOrLive(at: now), let schedule = event.schedule else { return nil }
            return HomeUpcomingEvent(id: event.beaconID, title: event.title ?? "Saved event", schedule: schedule,
                                     place: event.placeLabel, imageURL: nil, role: .saved)
        }
        return events
            .filter { $0.id != promotedID }
            .sorted { $0.schedule.start != $1.schedule.start ? $0.schedule.start < $1.schedule.start : $0.title < $1.title }
    }
}

/// An event Home suggests that you haven't joined, and the one reason it reads first.
struct HomeRecommendation: Identifiable, Equatable {
    enum Reason: Equatable {
        case interest(String)
        case trending(going: Int)
        case live
        case today
        case tomorrow
        case nearby(meters: Double)
        case popular(going: Int)
        case comingUp

        var text: String {
            switch self {
            case .interest(let tag): "Because you like \(tag)"
            case .trending(let going): "Trending · \(going) going"
            case .live: "Happening now"
            case .today: "Today"
            case .tomorrow: "Tomorrow"
            case .nearby(let meters):
                Measurement(value: meters, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
                    + " away"
            case .popular(let going): "\(going) going"
            case .comingUp: "Coming up"
            }
        }

        var systemImage: String {
            switch self {
            case .interest: "heart.fill"
            case .trending: "flame.fill"
            case .live: "dot.radiowaves.left.and.right"
            case .today: "clock.fill"
            case .tomorrow: "calendar"
            case .nearby: "location.fill"
            case .popular: "person.2.fill"
            case .comingUp: "sparkles"
            }
        }
    }

    let beacon: MapBeacon
    let reason: Reason
    var id: String { beacon.id }
}

/// Picks events for "Recommended for you" from what's around you: your interests, how close,
/// how soon, and how fast people are joining (rising) or how many already have (hot).
enum HomeRecommendations {
    static let limit = 8
    /// Only what's coming up in the next two weeks.
    static let horizon: TimeInterval = 14 * 86_400

    static func rank(
        beacons: [MapBeacon],
        interests: [String],
        origin: CLLocationCoordinate2D?,
        excluding taken: Set<String>,
        viewerID: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [HomeRecommendation] {
        let tags = interests.compactMap { tag -> (label: String, key: String)? in
            tag.nonEmptyTrimmed.map { ($0, $0.lowercased()) }
        }
        var scored: [(recommendation: HomeRecommendation, score: Double)] = []
        for beacon in beacons {
            guard beacon.isEvent, let schedule = beacon.schedule, !schedule.isEnded(at: now),
                  schedule.start.timeIntervalSince(now) <= horizon,
                  !taken.contains(beacon.id), beacon.creatorID != viewerID else { continue }
            let live = schedule.isLive(at: now)
            let hoursAway = max(0, schedule.start.timeIntervalSince(now)) / 3600
            let meters = origin.map { MapFeatureModel.distanceMeters($0, beacon.coordinate) }
            let going = beacon.rsvpCount ?? 0
            let rising = MapItem(kind: .beacon(beacon)).risingScore(now: now)
            let interest = Self.interest(of: beacon, among: tags)

            // Typed parts: one long mixed expression is too slow for the type checker.
            let interestScore: Double = interest == nil ? 0 : 3
            let nearScore: Double = meters.map { 2.5 * exp(-$0 / 3_000) } ?? 0
            let soonScore: Double = live ? 2 : 2 * exp(-hoursAway / 36)
            let hotScore: Double = min(1.5, log1p(Double(going)) * 0.6)
            let risingScore: Double = min(1.5, rising * 3)
            let score = interestScore + nearScore + soonScore + hotScore + risingScore

            let reason: HomeRecommendation.Reason
            if let interest {
                reason = .interest(interest)
            } else if going >= 3, rising >= 0.25 {
                reason = .trending(going: going)
            } else if live {
                reason = .live
            } else if schedule.startsToday(at: now, calendar: calendar) {
                reason = .today
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(schedule.start, inSameDayAs: tomorrow) {
                reason = .tomorrow
            } else if let meters, meters <= 1_500 {
                reason = .nearby(meters: meters)
            } else if going >= 5 {
                reason = .popular(going: going)
            } else {
                reason = .comingUp
            }
            scored.append((HomeRecommendation(beacon: beacon, reason: reason), score))
        }
        // A repeating event appears once: its best-placed date.
        var seenTitles = Set<String>()
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : ($0.recommendation.beacon.schedule?.start ?? .distantFuture) < ($1.recommendation.beacon.schedule?.start ?? .distantFuture) }
            .map(\.recommendation)
            .filter { seenTitles.insert($0.beacon.title.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// The first of your interests the event is about: one of its categories, or named in its
    /// title as a whole word ("Art" matches "Art Walk", never "Startup").
    static func interest(of beacon: MapBeacon, among tags: [(label: String, key: String)]) -> String? {
        let categories = Set(beacon.eventCategories.map { $0.lowercased() })
        let title = beacon.title.lowercased()
        let words = Set(title.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return tags.first { tag in
            categories.contains(tag.key)
                || words.contains(tag.key)
                || (tag.key.contains(" ") && title.contains(tag.key))
        }?.label
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
    /// Shared with Me and the editors (one copy, so edits show everywhere without a reload).
    var intents: ModuleState<[AvailabilityIntentPost]> { environment?.selfData.intents ?? ModuleState() }
    var savedEvents: ModuleState<[SavedEvent]> { environment?.selfData.savedEvents ?? ModuleState() }
    private(set) var nudges = ModuleState<[InboxNudge]>()
    private(set) var discovery = ModuleState<NearbyDiscovery>()
    /// Events you host or are going to (`/api/beacons/mine`), for Upcoming.
    private(set) var myEvents = ModuleState<[MyEvent]>()
    private(set) var recaps: [ActivityRecap.Window: ModuleState<ActivityRecap>] = [:]
    /// The event-history recap card (flag-gated), cached so it's in place when Home opens.
    private(set) var recapCard: PastEvent?
    var recapWindow: ActivityRecap.Window = .week

    /// Nudges resolved this session; hidden immediately even if a stale fetch returns them.
    private var resolvedNudgeIDs: Set<String> = []
    private var environment: AppEnvironment?
    private var refreshTask: Task<Void, Never>?
    private var hasLoaded = false
    /// Seeded by `restore` before the shell's first frame (the async seed then only warms caches).
    private var restored = false

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
        intents.isStale || savedEvents.isStale
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

    /// True until every source of the opportunity card has answered once (cache counts), so
    /// Home can hold the card's space instead of pushing everything down when it lands.
    /// The opportunity card's minimum height.
    nonisolated static let opportunityPlaceholderHeight: CGFloat = 132

    /// Events you host, are going to or saved that haven't ended, soonest first.
    func upcoming(excluding promotedID: String?, now: Date = .now) -> [HomeUpcomingEvent] {
        HomeUpcomingEvent.merge(mine: myEvents.value ?? [], saved: savedEvents.value ?? [], excluding: promotedID, now: now)
    }

    /// Whether Upcoming has heard back from both of its sources (cache counts).
    var hasUpcomingAnswer: Bool { myEvents.value != nil && savedEvents.value != nil }

    /// Events near you you're not part of yet, best first (none without discovery).
    func recommendations(excluding promotedID: String?, now: Date = .now) -> [HomeRecommendation] {
        var taken = Set(upcoming(excluding: nil, now: now).map(\.id))
        if let promotedID { taken.insert(promotedID) }
        return HomeRecommendations.rank(
            beacons: discovery.value?.beacons ?? [],
            interests: environment?.selfData.profile.value?.interests ?? [],
            origin: environment?.location.lastFix?.coordinate,
            excluding: taken,
            viewerID: userID,
            now: now
        )
    }

    // MARK: - Loading

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Every cached module, read on the spot before the shell's first frame: Home opens whole
    /// (greeting, plans, opportunity, recap, nearby) instead of sections landing and pushing the
    /// rest down after launch. Expects `selfData.restoreNow` first.
    func restore(_ environment: AppEnvironment, userID: String) {
        attach(environment)
        restored = true
        if let cached = environment.selfData.profile.value {
            firstName = cached.firstName.nonEmptyTrimmed ?? Self.firstName(cached.displayName)
        }
        nudges.seed(CacheStore.loadNow([InboxNudge].self, key: "nudges", userID: userID))
        for window in ActivityRecap.Window.allCases {
            var state = ModuleState<ActivityRecap>()
            state.seed(CacheStore.loadNow(ActivityRecap.self, key: "recap.\(window.rawValue)", userID: userID))
            recaps[window] = state
        }
        if environment.location.isAuthorized {
            discovery.seed(CacheStore.loadNow(NearbyDiscovery.self, key: "nearby", userID: userID))
        }
        recapCard = CacheStore.loadNow([PastEvent].self, key: Self.recapCardKey, userID: userID)?.first
        myEvents.seed(CacheStore.loadNow([MyEvent].self, key: Self.myEventsKey, userID: userID))
    }

    private static let recapCardKey = "event-recap-card"
    private static let myEventsKey = "my-events"

    /// A failed read keeps the card shown; an answer (a card or none) replaces it and is cached.
    func loadRecapCard() async {
        guard let environment, let userID else { return }
        let card: PastEvent?
        do { card = try await environment.beacons.eventRecapCard() } catch { return }
        if card != recapCard { withAnimation(ClickMotion.subtleFade) { recapCard = card } }
        await CacheStore.shared.save([card].compactMap { $0 }, key: Self.recapCardKey, userID: userID)
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
        // Upcoming events open with their RSVP already known (their pages never wait on it).
        let upcoming = upcoming(excluding: nil).prefix(6).map(\.id)
        await environment.events.warm(beaconIDs: Array(upcoming))
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
    /// Bumped when a Click's availability changes (live update): Home re-asks for overlaps.
    private(set) var overlapsRevision = 0

    // MARK: - Live updates

    /// Someone's "I'm down for…" changed: yours (another device) or a Click's.
    func availabilityChanged() async {
        overlapsRevision += 1
        await loadIntents()
    }

    func reloadNudges() async {
        await loadNudges()
    }

    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryRerun = false

    /// Beacons changed: refetches discovery when the change is near where it was read. A change
    /// arriving mid-read queues one more read rather than cancelling (a cancelled read would fail).
    func beaconsChanged(_ change: BeaconChange) {
        guard discovery.value != nil, change.affects(environment?.location.lastFix?.coordinate) else { return }
        guard discoveryTask == nil else {
            discoveryRerun = true
            return
        }
        discoveryTask = Task {
            repeat {
                discoveryRerun = false
                await loadDiscovery()
            } while discoveryRerun
            discoveryTask = nil
        }
    }

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

    /// Shown after a nudge action that needs feedback (hangout logged, wave sent, errors).
    var actionNotice: String?

    /// Confirms a hangout from its nudge (the server resolves the nudge).
    func confirmHangout(_ nudge: InboxNudge) async {
        guard let environment, let id = nudge.confirmationID else { return }
        resolvedNudgeIDs.insert(nudge.id)
        do {
            switch try await environment.relationships.confirmHangout(id: id) {
            case .logged(let alreadyLogged):
                ClickHaptics.success()
                actionNotice = alreadyLogged ? "Already on your timeline" : "Added to your timeline with \(nudge.peerFirstName ?? "them")"
            case .waiting:
                ClickHaptics.success()
                actionNotice = "Confirmed. It's added once \(nudge.peerFirstName ?? "they") confirm too."
            }
        } catch {
            resolvedNudgeIDs.remove(nudge.id)
            actionNotice = error.userFacingMessage
        }
    }

    func declineHangout(_ nudge: InboxNudge) async {
        guard let environment, let id = nudge.confirmationID else { return }
        resolvedNudgeIDs.insert(nudge.id)
        do {
            try await environment.relationships.declineHangout(id: id)
        } catch {
            resolvedNudgeIDs.remove(nudge.id)
            actionNotice = error.userFacingMessage
        }
    }

    /// Waves back (the server marks their wave answered).
    func waveBack(_ nudge: InboxNudge) async {
        guard let environment, let connectionID = nudge.connectionID else { return }
        resolvedNudgeIDs.insert(nudge.id)
        do {
            _ = try await environment.relationships.wave(connectionID: connectionID)
            ClickHaptics.success()
            actionNotice = "You waved at \(nudge.peerFirstName ?? "them") 👋"
        } catch {
            resolvedNudgeIDs.remove(nudge.id)
            actionNotice = error.userFacingMessage
        }
    }

    // MARK: - Private

    private var userID: String? { environment?.session.currentSession?.userId }

    private func seedFromCache(_ environment: AppEnvironment, userID: String) async {
        if restored {
            // Already on screen; this read also teaches the beacon cache those events.
            if environment.location.isAuthorized { _ = await environment.beacons.cachedDiscovery(userID: userID) }
            return
        }
        if let cached = await environment.me.cachedSelfProfile(userID: userID) {
            firstName = cached.firstName.nonEmptyTrimmed ?? Self.firstName(cached.displayName)
        }
        await environment.selfData.seedIfNeeded()
        nudges.seed(await environment.me.cachedNudges(userID: userID))
        for window in ActivityRecap.Window.allCases {
            var state = ModuleState<ActivityRecap>()
            state.seed(await environment.me.cachedRecap(window: window, userID: userID))
            recaps[window] = state
        }
        if environment.location.isAuthorized {
            discovery.seed(await environment.beacons.cachedDiscovery(userID: userID))
        }
        myEvents.seed(await CacheStore.shared.load([MyEvent].self, key: Self.myEventsKey, userID: userID))
    }

    private func performRefresh() async {
        async let identity: Void = loadIdentity()
        async let intents: Void = loadIntents()
        async let saved: Void = loadSavedEvents()
        async let nudges: Void = loadNudges()
        async let recap: Void = loadRecap(recapWindow)
        async let discovery: Void = loadDiscovery()
        async let mine: Void = reloadMyEvents()
        _ = await (identity, intents, saved, nudges, recap, discovery, mine)
    }

    /// Also after an RSVP, a cancel or a new event, so Upcoming is right when you come back.
    func reloadMyEvents() async {
        guard let environment, let userID else { return }
        myEvents.begin()
        do {
            let fresh = try await environment.events.myEvents()
            myEvents.succeed(fresh)
            await CacheStore.shared.save(fresh, key: Self.myEventsKey, userID: userID)
        } catch {
            myEvents.fail(error)
        }
    }

    private func loadIdentity() async {
        guard let environment, let userID else { return }
        if let identity = try? await environment.phase3.identity(userID: userID), !identity.firstName.isEmpty {
            firstName = identity.firstName
        }
    }

    private func loadIntents() async {
        await environment?.selfData.loadIntents(force: true)
    }

    private func loadSavedEvents() async {
        await environment?.selfData.loadSavedEvents(force: true)
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
