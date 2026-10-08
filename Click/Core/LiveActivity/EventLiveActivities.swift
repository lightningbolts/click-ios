import ActivityKit
import UIKit

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
        var artworks: [String: String] = [:]
        for item in wanted {
            artworks[item.event.beaconID] = await Artwork.prepare(item.event)
        }
        Artwork.prune(keeping: Set(artworks.values))
        // Running before this list existed (an earlier build started it) counts as started.
        for activity in Activity<EventActivityAttributes>.activities where wantedIDs.contains(activity.attributes.beaconID) {
            Started.remember(activity.attributes.beaconID)
        }
        for item in wanted {
            let state = EventActivityAttributes.ContentState(start: item.event.start, end: item.event.end, checkedIn: item.checkedIn,
                                                             artwork: artworks[item.event.beaconID])
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

/// Each event's picture as the small square the activity draws, saved where ClickWidgets reads
/// it. Named by the event and the picture's URL, so a new picture is a new file (and an update).
private enum Artwork {
    /// The badge's largest size (52 pt on the Lock Screen) at 3x.
    static let pixels: CGFloat = 156

    /// The saved file's name, saving it first; nil when the event has no picture or it can't load.
    static func prepare(_ event: MyEvent) async -> String? {
        guard let directory = EventActivityAttributes.artworkDirectory,
              let url = event.imageURL?.nonEmptyTrimmed.flatMap(URL.init(string:)) else { return nil }
        let name = String(CardVisual.fnv1a32(event.beaconID + "|" + url.absoluteString), radix: 16) + ".jpg"
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        // Room to fill the square from a wide banner before it's cropped.
        guard let image = await ImagePipeline.shared.image(for: url, maxPixelSize: pixels * 4),
              let data = square(image).jpegData(compressionQuality: 0.8) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil ? name : nil
    }

    /// Pictures of events no longer shown are deleted (all of them on sign-out).
    static func prune(keeping names: Set<String>) {
        guard let directory = EventActivityAttributes.artworkDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Center-cropped to a `pixels` square, as the badge draws it.
    private static func square(_ image: UIImage) -> UIImage {
        let scale = pixels / max(1, min(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(x: (pixels - size.width) / 2, y: (pixels - size.height) / 2), size: size))
        }
    }
}

/// Events whose activity this device started and hasn't ended itself. One that's gone from
/// `Activity.activities` while still listed here was swiped away (or timed out), so it isn't
/// started again. iOS ends every activity when Click is updated, so a list written by another
/// build means nothing was swiped away: it reads as empty and those events start again.
/// UserDefaults is thread-safe, so this is usable off the main actor.
private enum Started {
    private static let key = "events.liveActivity.started"
    private static let buildKey = "events.liveActivity.startedBuild"
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    private static var ids: Set<String> {
        get {
            guard UserDefaults.standard.string(forKey: buildKey) == build else { return [] }
            return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: key)
            UserDefaults.standard.set(build, forKey: buildKey)
        }
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
