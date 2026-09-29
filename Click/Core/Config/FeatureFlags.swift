import Foundation
import Observation

/// Server-driven feature flags (`GET /api/me/features`). Every post-launch feature ships dark and
/// is enabled per cohort on the server; an unknown, unloaded, or failed flag is simply off.
@Observable
@MainActor
public final class FeatureFlags {
    public enum Key: String, CaseIterable, Sendable {
        case dropsDevelop = "drops_develop"
        case alertConfirmations = "alert_confirmations"
        case soundtrackPresence = "soundtrack_presence"
    }

    private struct Resolved: Decodable {
        let enabled: Bool
    }

    private struct Response: Decodable {
        let features: [String: Resolved]
    }

    private var enabled: Set<String> = []
    private let api: ClickAPIClient?

    public init(api: ClickAPIClient?) {
        self.api = api
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
        } catch {
            ClickLog.net.error("feature flags refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Signed out: nothing is on.
    public func reset() {
        enabled = []
    }

    #if DEBUG
    /// Tests and previews only.
    public func override(_ key: Key, _ isOn: Bool) {
        if isOn { enabled.insert(key.rawValue) } else { enabled.remove(key.rawValue) }
    }
    #endif
}
