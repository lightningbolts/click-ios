import Foundation
import Observation

/// Server-driven feature flags (`GET /api/me/features`). Every post-launch feature ships dark and
/// is enabled per cohort on the server; an unknown, unloaded, or failed flag is simply off.
/// The last flags each user got are kept on device, so a cold launch paints flagged screens on
/// its first frame (no pop-in) and the network refresh only corrects them.
@Observable
@MainActor
public final class FeatureFlags {
    public enum Key: String, CaseIterable, Sendable {
        case dropsDevelop = "drops_develop"
        case alertConfirmations = "alert_confirmations"
        case soundtrackPresence = "soundtrack_presence"
        case eventDrops = "event_drops"
        case eventHistory = "event_history"
        case sharedDrops = "shared_drops"
        case reconnectNearby = "reconnect_nearby"
        case clickPlaces = "click_places"
    }

    private struct Resolved: Decodable {
        let enabled: Bool
    }

    private struct Response: Decodable {
        let features: [String: Resolved]
    }

    private var enabled: Set<String> = []
    private var userID: String?
    private let api: ClickAPIClient?
    private static let defaults = UserDefaults.standard
    private static let lastUserKey = "features.lastUser"
    private static func key(_ userID: String) -> String { "features.enabled.\(userID)" }

    public init(api: ClickAPIClient?) {
        self.api = api
        // The app (not tests/previews) starts from the last signed-in user's flags.
        if api != nil { restore(userID: Self.defaults.string(forKey: Self.lastUserKey)) }
    }

    /// Flags are per user: switch to this user's last known flags (none when signed out).
    public func restore(userID: String?) {
        guard userID != self.userID || userID == nil else { return }
        self.userID = userID
        enabled = userID.map { Set(Self.defaults.stringArray(forKey: Self.key($0)) ?? []) } ?? []
        Self.defaults.set(userID, forKey: Self.lastUserKey)
    }

    public func isEnabled(_ key: Key) -> Bool {
        enabled.contains(key.rawValue)
    }

    /// Refreshes from the server; keeps the last known flags when offline or on error.
    public func refresh() async {
        guard let api else { return }
        do {
            let response: Response = try await api.execute(APIRequest(path: "/api/me/features"))
            enabled = Set(response.features.filter(\.value.enabled).map(\.key))
            if let userID { Self.defaults.set(enabled.sorted(), forKey: Self.key(userID)) }
        } catch {
            ClickLog.net.error("feature flags refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Signed out: nothing is on.
    public func reset() {
        restore(userID: nil)
    }

    #if DEBUG
    /// Tests and previews only.
    public func override(_ key: Key, _ isOn: Bool) {
        if isOn { enabled.insert(key.rawValue) } else { enabled.remove(key.rawValue) }
    }
    #endif
}
