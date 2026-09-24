import Foundation
import Network
import Observation

/// Device connectivity, from `NWPathMonitor`.
///
/// The global "Offline" banner is driven only by this, never by a failed request: a 500,
/// a timeout or a cancelled request while the device is online is a per-section refresh
/// failure ("Couldn't refresh · Retry"), not "offline".
@Observable
@MainActor
public final class NetworkMonitor {
    public private(set) var isOnline: Bool
    public private(set) var isExpensive = false

    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "click.network-monitor")

    /// `start: false` builds a fixed-state monitor for tests and previews.
    public init(start: Bool = true, initiallyOnline: Bool = true) {
        isOnline = initiallyOnline
        guard start else {
            monitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.isOnline = online
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: queue)
    }

    /// Test/preview hook.
    public func setOnline(_ online: Bool) {
        isOnline = online
    }

    /// Which notice a module shows. Pure so it can be unit tested.
    public enum Notice: Equatable, Sendable {
        case none
        /// Device is offline and cached data is on screen.
        case offline
        /// Device is online but this section's last refresh failed.
        case refreshFailed
    }

    public nonisolated static func notice(isOnline: Bool, hasCachedValue: Bool, refreshFailed: Bool) -> Notice {
        if !isOnline { return hasCachedValue ? .offline : .none }
        return refreshFailed ? .refreshFailed : .none
    }
}
