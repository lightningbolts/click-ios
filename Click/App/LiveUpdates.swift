import CoreLocation
import Foundation
import Observation

/// Where beacons changed: a 0.1° cell (about 11 km), as the server rounds it.
struct LiveCell: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// One coalesced batch of beacon changes. `revision` makes every batch distinct for `onChange`.
struct BeaconChange: Equatable, Sendable {
    let revision: Int
    /// nil: anywhere (a beacon without a location, or a catch-up after the channel was down).
    let cells: Set<LiveCell>?

    /// The discovery radius plus a cell's reach (rounding moves a point at most ~8 km).
    static let reachMeters = Double(BeaconRepository.discoveryRadiusMeters) + 10_000

    /// Whether a read centred on `center` could include a changed beacon (unknown center: yes).
    func affects(_ center: CLLocationCoordinate2D?) -> Bool {
        guard let cells, let center else { return true }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return cells.contains {
            here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= Self.reachMeters
        }
    }
}

/// Keeps Home, Map and Clicks current without reloading: listens on the viewer's private
/// `user:<id>` topic and the shared `beacons` topic, and refetches what a hint names through
/// the usual (audience-checked) APIs. Hints carry no content.
///
/// Bursts are coalesced into one refetch per kind. While the app isn't active hints only
/// accumulate; becoming active flushes them and revives the sockets, and a rejoin after a
/// drop catches up on everything, since hints sent meanwhile were missed.
@Observable
@MainActor
final class LiveUpdates {
    /// The latest beacon change, for screens that own their own beacon reads (the Map).
    private(set) var beaconChange: BeaconChange?

    private enum Kind: String {
        case drops, beacons, nudges, availability, activity, connections
        /// Every Home module (local only: a catch-up after the user channel was down).
        case home
    }

    private static let catchUpKinds: Set<Kind> = [.home, .drops, .activity, .connections]
    private static let coalesceDelay: Duration = .milliseconds(600)

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let userChannel = ChatRealtimeManager()
    @ObservationIgnored private let beaconsChannel = ChatRealtimeManager()
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var pendingKinds: Set<Kind> = []
    @ObservationIgnored private var pendingCells: Set<LiveCell> = []
    @ObservationIgnored private var beaconsAnywhere = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Joins both topics for `userID` (a no-op when already live for them).
    func start(userID: String) {
        guard self.userID != userID else { return }
        stop()
        let anonKey = AppConfig.shared.supabaseAnonKey
        guard !anonKey.isEmpty else { return }
        self.userID = userID
        let url = AppConfig.shared.supabaseURL
        let token = environment?.session.currentSession?.jwt

        userChannel.onLiveHint = { [weak self] in self?.receive($0) }
        userChannel.onRejoined = { [weak self] in self?.enqueue(Self.catchUpKinds) }
        userChannel.subscribe(to: userID, stream: .live, supabaseURL: url, anonKey: anonKey, authToken: token)

        beaconsChannel.onLiveHint = { [weak self] in self?.receive($0) }
        beaconsChannel.onRejoined = { [weak self] in
            self?.beaconsAnywhere = true
            self?.enqueue([.beacons])
        }
        beaconsChannel.subscribe(to: "beacons", stream: .beacons, supabaseURL: url, anonKey: anonKey, authToken: token)
    }

    /// Sign-out: leaves both topics and drops anything pending.
    func stop() {
        userChannel.teardown()
        beaconsChannel.teardown()
        userID = nil
        flushTask?.cancel()
        flushTask = nil
        pendingKinds = []
        pendingCells = []
        beaconsAnywhere = false
        beaconChange = nil
    }

    /// Scene phase: inactive only collects hints; active applies them and revives the sockets
    /// (a socket that died while suspended rejoins, which triggers a catch-up).
    func setActive(_ active: Bool) {
        isActive = active
        guard active else {
            flushTask?.cancel()
            flushTask = nil
            return
        }
        userChannel.ensureLive()
        beaconsChannel.ensureLive()
        scheduleFlush()
    }

    // MARK: - Hints

    private func receive(_ hint: LiveHint) {
        guard let kind = Kind(rawValue: hint.kind), kind != .home else { return }
        if kind == .beacons {
            if let latitude = hint.latitude, let longitude = hint.longitude {
                pendingCells.insert(LiveCell(latitude: latitude, longitude: longitude))
            } else {
                beaconsAnywhere = true
            }
        }
        enqueue([kind])
    }

    private func enqueue(_ kinds: Set<Kind>) {
        pendingKinds.formUnion(kinds)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard isActive, flushTask == nil, !pendingKinds.isEmpty else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        let kinds = pendingKinds
        pendingKinds = []
        guard let environment, userID != nil else { return }
        let home = environment.homeFeed

        if kinds.contains(.beacons) {
            let change = BeaconChange(
                revision: (beaconChange?.revision ?? 0) + 1,
                cells: beaconsAnywhere ? nil : pendingCells
            )
            pendingCells = []
            beaconsAnywhere = false
            beaconChange = change
            home.beaconsChanged(change)
        }
        // A new connection can also reveal their drops.
        if !kinds.isDisjoint(with: [.drops, .connections]), environment.features.isEnabled(.sharedDrops) {
            let store = environment.sharedDropsStore
            Task { await store.refresh(env: environment) }
        }
        if kinds.contains(.connections), let inbox = environment.inbox {
            Task { await inbox.refresh() }
        }
        if kinds.contains(.home) {
            Task { await home.refresh() }
        } else {
            if kinds.contains(.nudges) {
                Task { await home.reloadNudges() }
            }
            if kinds.contains(.availability) {
                Task { await home.availabilityChanged() }
            }
        }
        if kinds.contains(.activity) {
            let activity = environment.activity
            Task { await activity.refresh(force: true) }
        }
    }
}
