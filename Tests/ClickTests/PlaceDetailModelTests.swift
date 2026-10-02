import CoreLocation
import Foundation
import Testing
@testable import Click

/// A scripted Places API for the Place page model.
private actor StubPlaceRepository: PlaceRepositoryProtocol {
    var detailResult: PlaceDetail
    var checkInResult: Result<PlaceCheckInState, PlaceError> = .success(PlaceCheckInState(
        active: true, checkInID: "ci1", checkedInAt: .now, expiresAt: .now.addingTimeInterval(10_800), proof: "gps", shareWithConnections: false
    ))
    var pulseResult: Result<PulseSummary, PlaceError>
    private(set) var checkInCalls: [(anchorToken: String?, hasCoordinate: Bool)] = []
    private(set) var pulseCalls = 0

    init(detail: PlaceDetail, pulseSummary: PulseSummary) {
        detailResult = detail
        pulseResult = .success(pulseSummary)
    }

    func setCheckInResult(_ result: Result<PlaceCheckInState, PlaceError>) { checkInResult = result }
    func setDetail(_ detail: PlaceDetail) { detailResult = detail }

    func nearby(around: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [PlaceSummary] { [] }
    func detail(idOrSlug: String, source: String?) async throws -> PlaceDetail { detailResult }
    func checkIn(placeID: String, coordinate: CLLocationCoordinate2D?, accuracy: Double?, anchorToken: String?, shareWithConnections: Bool) async throws -> PlaceCheckInState {
        checkInCalls.append((anchorToken, coordinate != nil))
        return try checkInResult.get()
    }
    func checkInStatus(placeID: String) async throws -> PlaceCheckInState? { nil }
    func checkOut(placeID: String) async throws -> Bool { true }
    func submitPulse(placeID: String, energy: Int?, talkable: Int?, categoryAnswer: Int?, wouldReturn: Int?) async throws -> (pulseID: String, editableUntil: Date?, summary: PulseSummary) {
        pulseCalls += 1
        return ("pulse1", .now.addingTimeInterval(900), try pulseResult.get())
    }
    func updatePulse(placeID: String, pulseID: String, talkable: Int?, categoryAnswer: Int?) async throws -> PulseSummary { try pulseResult.get() }
    func myPlaces() async throws -> [MyPlaceVisit] { [] }
}

@Suite("Place page model")
@MainActor
struct PlaceDetailModelTests {
    static func eligibility(canPulse: Bool, reason: PulseEligibility.Reason?) -> PulseEligibility {
        PulseEligibility(
            canPulse: canPulse, reason: reason, cooldownUntil: reason == .cooldown ? .now.addingTimeInterval(600) : nil,
            questions: [
                PulseQuestion(key: "energy", categoryQuestion: nil, prompt: "How's the energy?", required: true, phase: "present", options: []),
                PulseQuestion(key: "talkable", categoryQuestion: nil, prompt: "Easy to talk here?", required: false, phase: "present",
                              options: [.init(value: 1, label: "Yes"), .init(value: 0, label: "No")])
            ],
            leavingQuestions: [], myLastPulse: nil
        )
    }

    static func detail(isManager: Bool = false, eligibility: PulseEligibility?) -> PlaceDetail {
        PlaceDetail(
            summary: PlacesMapTests.place("p1"),
            description: nil, websiteURL: nil, todayHoursLabel: nil, appleMapsURL: nil, googleMapsURL: nil, pattern: nil,
            upcomingEvents: [], hereNowConnections: [], clicksBeenHere: nil, youMetHere: nil, ownHistory: nil,
            checkIn: nil, pulseEligibility: eligibility, hub: nil, isManager: isManager
        )
    }

    static let livePulse = PulseSummary(
        state: .live, label: .lively, energyScore: 3, reportCount: 1, newestAt: .now, confidence: .low,
        distribution: [0, 0, 1, 0], talkableYes: 0, talkableNo: 0, categoryQuestion: nil, categoryCounts: nil, windowMinutes: 90
    )

    private func model(_ repo: StubPlaceRepository, anchor: String? = nil, locate: PlaceLocationOutcome = .fix(.init(latitude: 47.6588, longitude: -122.3131), accuracy: 15)) -> PlaceDetailModel {
        PlaceDetailModel(idOrSlug: "p1", anchorToken: anchor, repository: repo, locate: { locate })
    }

    @Test("Check-in success stores the state and clears the phase")
    func checkInSuccess() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: Self.eligibility(canPulse: false, reason: .notPresent)), pulseSummary: Self.livePulse)
        let model = model(repo)
        await model.load()
        await model.checkIn()
        #expect(model.checkInPhase == .idle)
        #expect(await repo.checkInCalls.count == 1)
        #expect(await repo.checkInCalls.first?.hasCoordinate == true)
    }

    @Test("Out of bounds shows the distance copy")
    func outOfBounds() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: nil), pulseSummary: Self.livePulse)
        await repo.setCheckInResult(.failure(.outOfBounds(distance: 312)))
        let model = model(repo)
        await model.load()
        await model.checkIn()
        #expect(model.checkInPhase == .failed(.outOfBounds(distance: 312)))
        #expect(PlaceError.outOfBounds(distance: 312).message.hasPrefix("You're about "))
        #expect(PlaceError.outOfBounds(distance: 312).message.hasSuffix(" away. Check in when you're here."))
    }

    @Test("GPS check-in without location fails locally with the location copy")
    func noLocation() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: nil), pulseSummary: Self.livePulse)
        let model = model(repo, locate: .denied)
        await model.load()
        await model.checkIn()
        #expect(model.checkInPhase == .failed(.noLocation))
        #expect(await repo.checkInCalls.isEmpty)
    }

    @Test("A QR code asks first and never checks in on its own; confirming sends the token")
    func qrConfirm() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: nil), pulseSummary: Self.livePulse)
        let model = model(repo, anchor: "tok", locate: .denied)
        await model.load()
        #expect(model.showAnchorConfirmation)
        #expect(await repo.checkInCalls.isEmpty)
        await model.confirmAnchorCheckIn()
        let calls = await repo.checkInCalls
        #expect(calls.count == 1)
        #expect(calls.first?.anchorToken == "tok")
        #expect(calls.first?.hasCoordinate == false)
    }

    @Test("Dismissing the QR prompt drops the token")
    func qrDismiss() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: nil), pulseSummary: Self.livePulse)
        let model = model(repo, anchor: "tok")
        await model.load()
        model.dismissAnchorConfirmation()
        #expect(model.pendingAnchorToken == nil)
        #expect(await repo.checkInCalls.isEmpty)
    }

    @Test("Submitting a Pulse replaces the summary and offers the follow-ups")
    func pulseSubmit() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: Self.eligibility(canPulse: true, reason: nil)), pulseSummary: Self.livePulse)
        let model = model(repo)
        await model.load()
        #expect(model.detail?.summary.pulse.state == PulseSummary.State.none)
        await model.submitEnergy(3)
        #expect(model.detail?.summary.pulse == Self.livePulse)
        #expect(model.pulseSubmitted)
        #expect(model.remainingFollowUps().map(\.key) == ["talkable"])
        await model.answerFollowUp(model.remainingFollowUps()[0], value: 1)
        #expect(model.remainingFollowUps().isEmpty)
    }

    @Test("The cooldown disables the energy chips")
    func cooldown() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: Self.eligibility(canPulse: false, reason: .cooldown)), pulseSummary: Self.livePulse)
        let model = model(repo)
        await model.load()
        #expect(model.showsPulseCard)
        #expect(!model.energyChipsEnabled)
        await model.submitEnergy(2)
        #expect(await repo.pulseCalls == 0)
    }

    @Test("Managers never see the Pulse card")
    func managerHidesPulse() async {
        let repo = StubPlaceRepository(detail: Self.detail(isManager: true, eligibility: Self.eligibility(canPulse: false, reason: .manager)), pulseSummary: Self.livePulse)
        let model = model(repo)
        await model.load()
        #expect(!model.showsPulseCard)
    }

    @Test("Not present hides the Pulse card")
    func notPresentHidesPulse() async {
        let repo = StubPlaceRepository(detail: Self.detail(eligibility: Self.eligibility(canPulse: false, reason: .notPresent)), pulseSummary: Self.livePulse)
        let model = model(repo)
        await model.load()
        #expect(!model.showsPulseCard)
    }
}
