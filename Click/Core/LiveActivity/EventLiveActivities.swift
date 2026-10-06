import ActivityKit
import Foundation

/// Starts, updates and ends the event Live Activity: from a few hours before an event you're
/// going to (or hosting) until it ends, the Lock Screen and Dynamic Island count down to it, then
/// show it's on, with your Click Pass one tap away. Started on the device (no push), refreshed
/// whenever Click comes to the foreground and when your RSVP or check-in changes. One you swipe
/// away stays away: it isn't started again for that event.
///
/// ActivityKit is only touched from `nonisolated` functions given plain values, so no activity
/// object ever crosses into or out of the main actor.
@MainActor
enum EventLiveActivities {
    /// How far ahead of the start the activity appears.
    nonisolated static let leadTime: TimeInterval = 3 * 3600
    /// At most this many at once (overlapping events): the soonest win.
    nonisolated static let maxConcurrent = 2

    private static var lastSync: Date?
    private static var syncing = false
    /// A forced sync arrived while one was running: run again once it finishes.
    private static var rerun = false
    /// Bumped on sign-out, so a request started for the last account never lands afterwards.
    private static var generation = 0

    /// Brings the running activities in line with your upcoming events. `force` skips the
    /// foreground throttle (after an RSVP, a cancel or a new account).
    static func sync(env: AppEnvironment, force: Bool = false) async {
        guard let userID = env.session.currentSession?.userId else {
            await endAll()
            return
        }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 600 { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard !syncing else {
            if force { rerun = true }
            return
        }
        syncing = true
        defer { syncing = false }
        repeat {
            rerun = false
            let started = generation
            guard let mine = try? await env.events.myEvents() else { return }
            // Signed out, or another account signed in, while the request was out.
            guard started == generation, env.session.currentSession?.userId == userID else { return }
            lastSync = Date()
            let wanted = upcoming(mine, now: Date()).prefix(maxConcurrent).map { event in
                EventActivityTarget(event: event, checkedIn: env.events.cachedEngagement(beaconID: event.beaconID)?.checkedIn == true
                    || env.events.cachedPass(beaconID: event.beaconID)?.checkedInAt != nil)
            }
            await reconcile(Array(wanted))
        } while rerun
    }

    /// Sign-out: nothing of one account's events stays on the Lock Screen.
    static func endAll() async {
        generation += 1
        lastSync = nil
        await reconcile([])
        Started.reset()
    }

    /// Events worth a Live Activity now: starting within the lead time or on now, soonest first.
    nonisolated static func upcoming(_ events: [MyEvent], now: Date) -> [MyEvent] {
        events
            .filter { $0.end > now && $0.start.timeIntervalSince(now) <= leadTime }
            .sorted { $0.start < $1.start }
    }

    /// Ends activities no longer wanted, updates the ones that changed, starts the missing ones
    /// (unless you dismissed that event's one already).
    nonisolated private static func reconcile(_ wanted: [EventActivityTarget]) async {
        let wantedIDs = Set(wanted.map(\.event.beaconID))
        for activity in Activity<EventActivityAttributes>.activities where !wantedIDs.contains(activity.attributes.beaconID) {
            await activity.end(nil, dismissalPolicy: .immediate)
            Started.forget(activity.attributes.beaconID)
        }
        Started.prune(keeping: wantedIDs)
        // Running before this list existed (an earlier build started it) counts as started.
        for activity in Activity<EventActivityAttributes>.activities where wantedIDs.contains(activity.attributes.beaconID) {
            Started.remember(activity.attributes.beaconID)
        }
        for item in wanted {
            let state = EventActivityAttributes.ContentState(start: item.event.start, end: item.event.end, checkedIn: item.checkedIn)
            if let activity = Activity<EventActivityAttributes>.activities.first(where: { $0.attributes.beaconID == item.event.beaconID }) {
                if activity.activityState == .active, activity.content.state != state { await activity.update(content(state)) }
            } else if !Started.contains(item.event.beaconID) {
                let attributes = EventActivityAttributes(beaconID: item.event.beaconID, title: item.event.title, place: item.event.place,
                                                         gradient: CardVisual(seed: item.event.beaconID).gradient,
                                                         isHost: item.event.isHost)
                if (try? Activity.request(attributes: attributes, content: content(state), pushType: nil)) != nil {
                    Started.remember(item.event.beaconID)
                }
            }
        }
    }

    /// After a check-in on this phone (or the pass learning the host scanned you).
    nonisolated static func setCheckedIn(_ checkedIn: Bool, beaconID: String) async {
        for activity in Activity<EventActivityAttributes>.activities
        where activity.attributes.beaconID == beaconID && activity.activityState == .active {
            var state = activity.content.state
            guard state.checkedIn != checkedIn else { continue }
            state.checkedIn = checkedIn
            await activity.update(content(state))
        }
    }

    /// The content goes stale at the start (flipping the view to "on now") and, once it's on, at
    /// the end (flipping it to "ended"), so the Lock Screen is right even if Click isn't opened.
    nonisolated private static func content(_ state: EventActivityAttributes.ContentState) -> ActivityContent<EventActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.start > Date() ? state.start : state.end)
    }
}

/// Events whose activity this device started and hasn't ended itself. One that's gone from
/// `Activity.activities` while still listed here was swiped away (or timed out), so it isn't
/// started again. UserDefaults is thread-safe, so this is usable off the main actor.
private enum Started {
    private static let key = "events.liveActivity.started"

    private static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    static func contains(_ beaconID: String) -> Bool { ids.contains(beaconID) }
    static func remember(_ beaconID: String) { ids.insert(beaconID) }
    static func forget(_ beaconID: String) { ids.remove(beaconID) }
    /// Events no longer upcoming drop out, so the list never grows.
    static func prune(keeping wanted: Set<String>) { ids.formIntersection(wanted) }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

/// One event to show, with what its activity displays.
struct EventActivityTarget: Sendable {
    let event: MyEvent
    let checkedIn: Bool
}
