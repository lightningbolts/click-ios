import CoreLocation
import Foundation
import Observation

/// One foreground location read for a single tap (no background location, ever: spec §0.2).
enum PlaceLocationOutcome: Sendable {
    case fix(CLLocationCoordinate2D, accuracy: Double)
    case denied
    case unavailable
}

/// The Place page (§6.4, §6.7, §6.8): detail, check-in, Pulse. Location is read once per tap
/// through `locate`; the server owns the geofence and stores no coordinates.
@Observable
@MainActor
final class PlaceDetailModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }
    enum CheckInPhase: Equatable { case idle, locating, submitting, failed(PlaceError) }
    enum PulsePhase: Equatable { case idle, submitting, submitted(pulseID: String, editableUntil: Date?), failed(PlaceError) }

    let idOrSlug: String
    private let repository: any PlaceRepositoryProtocol
    private let locate: @MainActor () async -> PlaceLocationOutcome
    private let source: String?

    private(set) var detail: PlaceDetail?
    private(set) var loadState: LoadState = .idle
    private(set) var checkInPhase: CheckInPhase = .idle
    private(set) var pulsePhase: PulsePhase = .idle
    /// From a check-in QR code: asks "Check in at …?" and is sent with the check-in.
    private(set) var pendingAnchorToken: String?
    /// The confirmation sheet for a QR check-in (never checks in without the tap).
    var showAnchorConfirmation = false
    /// "Come back at this time?" after Leave.
    var showWouldReturn = false
    /// "Let my Clicks see I'm here": this check-in only, off by default.
    var shareWithConnections = false
    /// Follow-up questions answered on the current Pulse (hidden once answered).
    private(set) var answeredFollowUps: Set<String> = []

    init(
        idOrSlug: String,
        anchorToken: String?,
        repository: any PlaceRepositoryProtocol,
        source: String? = nil,
        locate: @escaping @MainActor () async -> PlaceLocationOutcome
    ) {
        self.idOrSlug = idOrSlug
        self.repository = repository
        self.locate = locate
        self.pendingAnchorToken = anchorToken
        self.showAnchorConfirmation = anchorToken != nil
        self.source = source ?? (anchorToken == nil ? nil : "qr")
    }

    var placeID: String { detail?.summary.id ?? idOrSlug }
    var isCheckedIn: Bool { detail?.checkIn?.active == true }
    var isManager: Bool { detail?.isManager == true }

    /// Shown when the user can Pulse, or to explain the cooldown; hidden for managers and when not present.
    var showsPulseCard: Bool {
        guard let eligibility = detail?.pulseEligibility, !isManager else { return false }
        return eligibility.canPulse || eligibility.reason == .cooldown || pulseSubmitted
    }

    var pulseSubmitted: Bool {
        if case .submitted = pulsePhase { return true }
        return false
    }

    /// Chips are disabled during the cooldown.
    var energyChipsEnabled: Bool {
        guard let eligibility = detail?.pulseEligibility else { return false }
        return eligibility.canPulse && pulsePhase != .submitting && !pulseSubmitted
    }

    /// Follow-ups still to offer after an energy Pulse, while it is editable.
    func remainingFollowUps(now: Date = .now) -> [PulseQuestion] {
        guard case .submitted(_, let editableUntil) = pulsePhase else { return [] }
        if let editableUntil, editableUntil <= now { return [] }
        return (detail?.pulseEligibility?.questions ?? []).filter { $0.key != "energy" && !answeredFollowUps.contains($0.key) }
    }

    var wouldReturnQuestion: PulseQuestion? {
        detail?.pulseEligibility?.leavingQuestions.first { $0.key == "would_return" }
    }

    // MARK: - Load

    func load() async {
        if detail == nil { loadState = .loading }
        do {
            detail = try await repository.detail(idOrSlug: idOrSlug, source: detail == nil ? source : nil)
            loadState = .loaded
        } catch {
            guard !error.isCancellation else { return }
            if detail == nil { loadState = .failed((error as? PlaceError ?? .network).message) }
        }
    }

    // MARK: - Check-in

    func confirmAnchorCheckIn() async {
        showAnchorConfirmation = false
        await checkIn()
    }

    func dismissAnchorConfirmation() {
        showAnchorConfirmation = false
        pendingAnchorToken = nil
    }

    func checkIn() async {
        guard checkInPhase != .locating, checkInPhase != .submitting else { return }
        checkInPhase = .locating
        var coordinate: CLLocationCoordinate2D?
        var accuracy: Double?
        switch await locate() {
        case .fix(let fix, let fixAccuracy):
            coordinate = fix
            accuracy = fixAccuracy
        case .denied, .unavailable:
            // A QR check-in still works without location (§4.4); GPS needs it.
            if pendingAnchorToken == nil {
                checkInPhase = .failed(.noLocation)
                return
            }
        }
        checkInPhase = .submitting
        do {
            let state = try await repository.checkIn(
                placeID: placeID,
                coordinate: coordinate,
                accuracy: accuracy,
                anchorToken: pendingAnchorToken,
                shareWithConnections: shareWithConnections
            )
            pendingAnchorToken = nil
            detail?.checkIn = state
            checkInPhase = .idle
            ClickHaptics.success()
            await load()
        } catch {
            checkInPhase = .failed(error as? PlaceError ?? .network)
        }
    }

    func checkOut() async {
        do {
            let askWouldReturn = try await repository.checkOut(placeID: placeID)
            detail?.checkIn = nil
            pulsePhase = .idle
            answeredFollowUps = []
            showWouldReturn = askWouldReturn && wouldReturnQuestion != nil
            await load()
        } catch {
            checkInPhase = .failed(error as? PlaceError ?? .network)
        }
    }

    // MARK: - Pulse

    func submitEnergy(_ energy: Int) async {
        guard energyChipsEnabled else { return }
        pulsePhase = .submitting
        do {
            let result = try await repository.submitPulse(placeID: placeID, energy: energy, talkable: nil, categoryAnswer: nil, wouldReturn: nil)
            if let current = detail { detail?.summary = replacingPulse(current.summary, with: result.summary) }
            answeredFollowUps = []
            pulsePhase = .submitted(pulseID: result.pulseID, editableUntil: result.editableUntil)
            ClickHaptics.success()
        } catch {
            pulsePhase = .failed(error as? PlaceError ?? .network)
            if case .cooldown = error as? PlaceError { await load() }
        }
    }

    func answerFollowUp(_ question: PulseQuestion, value: Int) async {
        guard case .submitted(let pulseID, _) = pulsePhase else { return }
        answeredFollowUps.insert(question.key)
        do {
            let summary = try await repository.updatePulse(
                placeID: placeID,
                pulseID: pulseID,
                talkable: question.key == "talkable" ? value : nil,
                categoryAnswer: question.key == "category" ? value : nil
            )
            if let current = detail { detail?.summary = replacingPulse(current.summary, with: summary) }
        } catch {
            // The window closed or the field was already set: just stop offering it.
        }
    }

    /// nil = dismissed without answering.
    func answerWouldReturn(_ value: Int?) async {
        showWouldReturn = false
        guard let value else { return }
        _ = try? await repository.submitPulse(placeID: placeID, energy: nil, talkable: nil, categoryAnswer: nil, wouldReturn: value)
    }

    private func replacingPulse(_ summary: PlaceSummary, with pulse: PulseSummary) -> PlaceSummary {
        PlaceSummary(
            id: summary.id, slug: summary.slug, name: summary.name, category: summary.category, photoURL: summary.photoURL,
            latitude: summary.latitude, longitude: summary.longitude, radiusMeters: summary.radiusMeters,
            distanceMeters: summary.distanceMeters, addressLine: summary.addressLine, city: summary.city, openNow: summary.openNow,
            pulse: pulse, hereNowCount: summary.hereNowCount, eventsTodayCount: summary.eventsTodayCount,
            nextEvent: summary.nextEvent, hubID: summary.hubID, viewer: summary.viewer
        )
    }
}
