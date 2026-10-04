import Foundation

/// In-context invitations to turn on an optional location setting, shown where its value is
/// obvious. Each appears once, and once more at least 30 days after "Not now", then never again.
/// Accepting only flips that one setting; nothing in the app is gated on it.
enum LocationNudge: String, CaseIterable {
    /// After a Click: remember where you met.
    case connectionSnap
    /// On a timeline whose encounters have no place.
    case timelineSnap
    /// After a Place or event check-in: anonymous venue stats. Its own consent, never bundled.
    case businessInsights

    var setting: WritableKeyPath<LocationPrivacy, Bool> {
        switch self {
        case .connectionSnap, .timelineSnap: \.connectionSnap
        case .businessInsights: \.businessInsights
        }
    }

    private static let snoozeInterval: TimeInterval = 30 * 24 * 3600

    /// Whether to show it now: the setting is off and this nudge hasn't run out.
    @MainActor
    func isDue(_ env: AppEnvironment) async -> Bool {
        guard let userID = env.session.currentSession?.userId else { return false }
        await env.selfData.loadLocationPrivacy()
        guard let privacy = env.selfData.locationPrivacy.value, !privacy[keyPath: setting] else { return false }
        let defaults = UserDefaults.standard
        switch defaults.integer(forKey: key("dismissals", userID)) {
        case 0: return true
        case 1:
            let last = defaults.double(forKey: key("dismissedAt", userID))
            return Date().timeIntervalSince1970 - last >= Self.snoozeInterval
        default: return false
        }
    }

    /// "Not now".
    @MainActor
    func dismiss(_ env: AppEnvironment) {
        guard let userID = env.session.currentSession?.userId else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key("dismissals", userID)) + 1, forKey: key("dismissals", userID))
        defaults.set(Date().timeIntervalSince1970, forKey: key("dismissedAt", userID))
    }

    /// Turns the setting on, then asks for location access if iOS hasn't been asked yet.
    /// Returns a message when it didn't fully work, nil on success.
    @MainActor
    func accept(_ env: AppEnvironment) async -> String? {
        guard let userID = env.session.currentSession?.userId,
              var next = env.selfData.locationPrivacy.value else { return "Couldn't load your location settings." }
        next[keyPath: setting] = true
        do {
            env.selfData.apply(locationPrivacy: try await env.me.setLocationPrivacy(
                next, userID: userID, includePlaceVisits: env.features.isEnabled(.clickPlaces)
            ))
        } catch {
            return "That setting wasn't changed. \(error.userFacingMessage)"
        }
        UserDefaults.standard.set(2, forKey: key("dismissals", userID))
        guard self != .businessInsights else { return nil }
        let status = env.permissions.status(for: .locationWhenInUse)
        let resolved = status == .notDetermined ? await env.permissions.requestPermission(for: .locationWhenInUse) : status
        return resolved == .authorized ? nil : "It's on, but Click can't use your location. Allow it in Settings."
    }

    private func key(_ field: String, _ userID: String) -> String { "locationNudge.\(rawValue).\(field).\(userID)" }
}
