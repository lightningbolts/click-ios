import CoreLocation
import Foundation
import Observation

/// Tap to Connect state machine (spec §23.2). Sensors report evidence; the server decides.
///
/// No state claims success until `POST /api/connections/proximity` (or its pending recovery /
/// host-selection confirm) returns a confirmed match.
@Observable
@MainActor
final class TapConnectModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case needsPermission(PermissionIssue)
        case sensing
        case submitting
        /// Stored server-side; polling for the other person's tap.
        case waitingForPeer(exhausted: Bool)
        case choosingPeople(candidates: [ProximityPeer], selected: Set<String>)
        case confirmingPeople
        case connected(ProximityMatch)
        case savedOffline
        case failed(String)
    }

    enum PermissionIssue: Equatable {
        case microphone
        case bluetooth
        case bluetoothOff
    }

    enum FactorStatus: Equatable {
        case waiting
        case active
        case found
        case none
        case skipped(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var bluetooth: FactorStatus = .waiting
    private(set) var sound: FactorStatus = .waiting
    private(set) var location: FactorStatus = .waiting

    private let ble = BLEProximityService()
    private let ultrasonic = UltrasonicService()
    private var environment: AppEnvironment?
    private var runTask: Task<Void, Never>?
    private var pendingID: String?
    private var lastStart: Date?

    /// Mirrors the KMP listen window and GATT grace.
    private static let listenWindow: Duration = .seconds(5)
    private static let gattGrace: Duration = .seconds(2)
    private static let selfBleedGuard: Duration = .milliseconds(900)
    private static let recoveryAttempts = 12
    private static let recoveryInterval: Duration = .milliseconds(2500)

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .sensing, .submitting, .confirmingPeople: true
        default: false
        }
    }

    // MARK: - Intents

    func start() {
        guard !isBusy else { return }
        if let lastStart, Date.now.timeIntervalSince(lastStart) < 3 { return }
        lastStart = .now
        runTask?.cancel()
        runTask = Task { await run() }
    }

    func cancel() {
        if case .choosingPeople(let candidates, let selected) = phase {
            track(.hostSelectionAbandoned, candidateCount: candidates.count, selectedCount: selected.count, reason: "dismissed")
        }
        runTask?.cancel()
        runTask = nil
        stopSensors()
        pendingID = nil
        phase = .idle
        resetFactors()
    }

    /// Radios and microphone never outlive the visible flow. A stored pending tap is kept and
    /// re-polled when the app returns.
    func enterBackground() {
        guard isBusy || phase == .waitingForPeer(exhausted: false) else { return }
        runTask?.cancel()
        runTask = nil
        stopSensors()
        if pendingID == nil {
            phase = .failed("Tap to Connect stopped when Click left the screen. Try again together.")
            resetFactors()
        }
    }

    func enterForeground() {
        guard let pendingID, runTask == nil else { return }
        runTask = Task { await recover(pendingID: pendingID) }
    }

    func toggleSelection(_ peer: ProximityPeer) {
        guard case .choosingPeople(let candidates, var selected) = phase else { return }
        if selected.contains(peer.id) {
            selected.remove(peer.id)
        } else if selected.count < ProximityRepository.maxSelectedPeers {
            selected.insert(peer.id)
        }
        ClickHaptics.selection()
        phase = .choosingPeople(candidates: candidates, selected: selected)
    }

    func confirmSelection() {
        guard case .choosingPeople(_, let selected) = phase, !selected.isEmpty,
              let pendingID, let environment else { return }
        phase = .confirmingPeople
        runTask = Task {
            do {
                let match = try await environment.proximity.confirmSelection(pendingID: pendingID, memberIDs: Array(selected))
                track(.hostSelectionConfirmed, selectedCount: selected.count)
                if match.isGroup { track(.cliqueCreated, peerCount: match.peers.count, isGroup: true) }
                await finish(with: match)
            } catch {
                track(.failed, reason: "confirm_selection_failed")
                phase = .failed("Couldn't create the group. \(error.userFacingMessage)")
            }
        }
    }

    // MARK: - Run

    private func run() async {
        guard let environment, let userID = environment.session.currentSession?.userId else { return }
        resetFactors()
        pendingID = nil
        phase = .preparing

        // The Simulator has no BLE radio or ultrasonic path; it sends the server's mock evidence,
        // which production rejects (KMP `MockProximityManager` contract).
        let simulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil

        if !simulator {
            guard await preparePermissions(environment) else { return }
        }

        let captureLocation = await shouldCaptureLocation(environment, userID: userID)
        guard !Task.isCancelled else { return }

        phase = .sensing
        track(.started)
        bluetooth = .active
        sound = .active
        location = captureLocation ? .active : .skipped("Off")

        async let fix: CLLocation? = captureLocation
            ? environment.location.preciseLocation(targetAccuracy: 20, timeout: .milliseconds(6500))
            : nil

        let evidence: ProximityEvidence
        if simulator {
            try? await Task.sleep(for: .seconds(2))
            let located = await fix
            evidence = ProximityEvidence(
                myToken: ProximityCodec.simulatorMyToken,
                heardTokens: ProximityCodec.simulatorHeardTokens,
                detectedDevices: [],
                latitude: located?.coordinate.latitude,
                longitude: located?.coordinate.longitude,
                simulatorMock: true
            )
        } else {
            let token = ProximityCodec.randomToken()
            do {
                try ultrasonic.activateSession()
            } catch {
                phase = .needsPermission(.microphone)
                return
            }
            async let heard = ultrasonic.listen(after: Self.selfBleedGuard, for: Self.listenWindow, excluding: token)
            async let detected = ble.exchange(token: token, hold: Self.listenWindow, grace: Self.gattGrace)
            // Stagger chirps so several nearby phones are less likely to talk over each other.
            try? await Task.sleep(for: .milliseconds(120 + Int.random(in: 0..<400)))
            await ultrasonic.play(token: token)
            let heardTokens = await heard
            let detectedTokens = await detected
            ultrasonic.stop()
            let located = await fix
            sound = heardTokens.isEmpty ? .none : .found
            bluetooth = detectedTokens.isEmpty ? .none : .found
            evidence = ProximityEvidence(
                myToken: token,
                heardTokens: heardTokens,
                detectedDevices: detectedTokens.sorted(),
                latitude: located?.coordinate.latitude,
                longitude: located?.coordinate.longitude,
                simulatorMock: false
            )
        }
        if captureLocation {
            location = evidence.latitude == nil ? .none : .found
        }
        guard !Task.isCancelled else { return }

        phase = .submitting
        do {
            await handle(try await environment.proximity.bind(evidence))
        } catch let error where error.isOffline {
            await environment.proximity.enqueue(evidence, userID: userID)
            track(.offlineQueued)
            phase = .savedOffline
        } catch {
            track(.failed, reason: Self.telemetryReason(error))
            phase = .failed("Tap to Connect failed. \(error.userFacingMessage)")
            ClickHaptics.error()
        }
    }

    private func handle(_ result: ProximityBindResult) async {
        switch result {
        case .matched(let match):
            if match.peers.isEmpty {
                track(.failed, reason: "no_peers")
                phase = .failed("No nearby tap detected. Try again closer together.")
                ClickHaptics.error()
            } else if match.rateLimited {
                track(.reconnectRateLimited, peerCount: match.peers.count, isGroup: match.isGroup, isReconnect: true)
                phase = .failed("You recently crossed paths with this person! Wait a bit before logging another memory.")
                ClickHaptics.warning()
            } else {
                track(.matched, peerCount: match.peers.count, isGroup: match.isGroup, isReconnect: match.isReconnect)
                if match.isReconnect { track(.reconnectSaved, peerCount: match.peers.count, isGroup: match.isGroup, isReconnect: true) }
                await finish(with: match)
            }
        case .awaitingSelection(let pendingID, let candidates):
            track(.awaitingSelection, candidateCount: candidates.count)
            self.pendingID = pendingID
            let people = Array(candidates.prefix(ProximityRepository.maxSelectedPeers))
            ClickHaptics.impact(.heavy)
            phase = .choosingPeople(candidates: people, selected: Set(people.map(\.id)))
        case .pending(let pendingID):
            track(.pending)
            self.pendingID = pendingID
            await recover(pendingID: pendingID)
        case .ignored:
            track(.failed, reason: "ignored_empty_payload")
            phase = .failed("No nearby tap detected. Try again closer together.")
        }
    }

    /// Polls the stored tap while the waiting state is visible (KMP: 12 × 2.5 s).
    private func recover(pendingID: String) async {
        guard let environment else { return }
        phase = .waitingForPeer(exhausted: false)
        for _ in 0..<Self.recoveryAttempts {
            try? await Task.sleep(for: Self.recoveryInterval)
            guard !Task.isCancelled else { return }
            guard let result = try? await environment.proximity.recover(pendingID: pendingID) else { continue }
            if case .pending = result { continue }
            track(.recoverySuccess)
            await handle(result)
            return
        }
        track(.recoveryTimeout)
        phase = .waitingForPeer(exhausted: true)
        runTask = nil
    }

    private func finish(with match: ProximityMatch) async {
        pendingID = nil
        ClickHaptics.impact(.heavy)
        ClickHaptics.success()
        phase = .connected(match)
        runTask = nil
    }

    // MARK: - Telemetry (spec §71.2)

    private func track(
        _ event: ConnectionFlowTelemetry.Event,
        peerCount: Int? = nil,
        isGroup: Bool? = nil,
        isReconnect: Bool? = nil,
        candidateCount: Int? = nil,
        selectedCount: Int? = nil,
        reason: String? = nil
    ) {
        guard let telemetry = environment?.connectionTelemetry else { return }
        Task {
            await telemetry.track(event, peerCount: peerCount, isGroup: isGroup, isReconnect: isReconnect,
                                  selectedCount: selectedCount, candidateCount: candidateCount, reason: reason)
        }
    }

    /// A short machine code for a failure (never a server message or an identifier).
    static func telemetryReason(_ error: Error) -> String {
        switch error as? APIError {
        case .timeout?: "timeout"
        case .rateLimited?: "rate_limited"
        case .unauthorized?, .forbidden?: "auth"
        case .validation?: "validation"
        case .server(let status, _, _)?: "server_\(status)"
        case .decoding?: "decoding"
        default: "unknown"
        }
    }

    // MARK: - Permissions / privacy

    private func preparePermissions(_ environment: AppEnvironment) async -> Bool {
        let microphone = environment.permissions.status(for: .microphone)
        let resolvedMicrophone = microphone == .notDetermined
            ? await environment.permissions.requestPermission(for: .microphone)
            : microphone
        guard resolvedMicrophone == .authorized else {
            phase = .needsPermission(.microphone)
            return false
        }
        switch await ble.prepare() {
        case .ready:
            return true
        case .unauthorized:
            phase = .needsPermission(.bluetooth)
        case .poweredOff:
            phase = .needsPermission(.bluetoothOff)
        case .unsupported:
            phase = .failed("Bluetooth isn't available on this device.")
        }
        return false
    }

    /// Location is captured only when Location snap is on (KMP
    /// `shouldCaptureLocationAtTap`). A failed preference read is treated as off.
    private func shouldCaptureLocation(_ environment: AppEnvironment, userID: String) async -> Bool {
        guard let privacy = try? await environment.me.locationPrivacy(userID: userID), privacy.connectionSnap else {
            return false
        }
        let status = environment.permissions.status(for: .locationWhenInUse)
        let resolved = status == .notDetermined
            ? await environment.permissions.requestPermission(for: .locationWhenInUse)
            : status
        return resolved == .authorized
    }

    private func stopSensors() {
        ble.stop()
        ultrasonic.stop()
    }

    private func resetFactors() {
        bluetooth = .waiting
        sound = .waiting
        location = .waiting
    }
}
