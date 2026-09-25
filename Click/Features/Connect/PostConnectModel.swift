import Foundation
import Observation

/// State for the post-connect reveal and context tagging (spec §25–§28). Built only from a
/// server-confirmed match; everything it shows beyond the match (encounter count, place,
/// Extended Hangout, event suggestion) comes from real reads and is omitted when unavailable.
@Observable
@MainActor
final class PostConnectModel {
    enum Method: Equatable { case tap, qr }

    enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    let match: ProximityMatch
    let method: Method
    let suggestions: [ContextTag]

    private(set) var encounterCount: Int?
    private(set) var isExtendedHangout = false
    private(set) var placeName: String?
    private(set) var recommendation: EventRecommendation?
    private(set) var saveState: SaveState = .idle
    private(set) var recommendationDismissed = false
    private(set) var rsvpPending = false

    /// Ordered selection; custom text is stored as its own label (KMP convention).
    var selectedTags: [String] = []
    var customTag = ""

    init(match: ProximityMatch, method: Method, now: Date = .now, calendar: Calendar = .current) {
        self.match = match
        self.method = method
        self.suggestions = ContextTagTaxonomy.suggest(locationName: nil, hour: calendar.component(.hour, from: now))
    }

    var isGroup: Bool { match.isGroup || match.peers.count > 1 }
    var primaryPeer: ProximityPeer? { match.peers.first }

    /// The Click Drop window the server opened for this one-to-one encounter (spec §44.1).
    var clickDropSession: ClickDropSession? {
        guard !isGroup, let encounterID = match.encounterID, let endsAt = match.collaborationEndsAt,
              let connectionID = primaryPeer?.connectionID ?? match.connectionID else { return nil }
        return ClickDropSession(connectionID: connectionID, encounterID: encounterID, endsAt: endsAt)
    }

    var title: String {
        if isGroup { return match.isNewConnection ? "Group created" : "Encounter saved" }
        if match.isReconnect { return "Reconnected" }
        return "You Clicked"
    }

    var subtitle: String {
        let names = match.peers.map { HomeFeedModel.firstName($0.name) ?? $0.name }
        let joined = ListFormatter.localizedString(byJoining: names)
        if match.isReconnect, !isGroup {
            if isExtendedHangout { return "Extended Hangout · still with \(joined)" }
            if let encounterCount, encounterCount >= 2 {
                return "\(Self.ordinal(encounterCount)) time with \(joined)" + (placeName.map { " · \($0)" } ?? "")
            }
            return "Another crossing with \(joined)"
        }
        if isGroup { return "You're in a verified group with \(joined)." }
        if let placeName { return "You Clicked at \(placeName)" }
        return "You and \(joined) just Clicked."
    }

    var taggingPrompt: String {
        if match.isReconnect { return "What are you up to this time?" }
        switch method {
        case .qr: return "Where did you meet?"
        case .tap: return isGroup ? "Set the context for this group" : "What brought you together?"
        }
    }

    nonisolated static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Encounter history and an event suggestion, loaded in parallel after the reveal. Both are
    /// enrichments: a failure just leaves them out.
    func load(_ env: AppEnvironment) async {
        guard let connectionID = match.connectionID, !isGroup else { return }
        async let history = try? env.profiles.encounters(connectionID: connectionID)
        async let suggestion = try? env.encounterContext.eventRecommendation(
            connectionID: connectionID,
            latitude: env.location.lastFix?.coordinate.latitude,
            longitude: env.location.lastFix?.coordinate.longitude
        )
        if let encounters = await history {
            encounterCount = encounters.count
            if let latest = encounters.first {
                placeName = latest.placeName
                // The server debounces a same-place, same-12-hour reconnect into the previous
                // row and tags it "Extended Hangout"; a row older than this tap means that.
                isExtendedHangout = match.isReconnect
                    && latest.contextTags.contains { $0.caseInsensitiveCompare(ContextTagTaxonomy.extendedHangout) == .orderedSame }
            }
        }
        recommendation = await suggestion ?? nil
    }

    func save(_ env: AppEnvironment) async {
        let tags = ContextTagPicker.resolved(selected: selectedTags, custom: customTag)
        guard let userID = env.session.currentSession?.userId else { return }
        let connectionIDs = match.isGroup ? match.peers.compactMap(\.connectionID) : [match.connectionID].compactMap { $0 }
        guard !connectionIDs.isEmpty else {
            saveState = .failed("This connection isn't ready for tags yet.")
            return
        }
        saveState = .saving
        let sensor = await EncounterSensorSampler.sample(settings: env.settings)
        do {
            for connectionID in connectionIDs {
                try await env.encounterContext.saveContext(connectionID: connectionID, tags: tags, sensor: sensor, reportingUserID: userID)
            }
            saveState = .saved
            ClickHaptics.success()
        } catch EncounterContextRepository.TagSaveError.noActiveEncounter {
            saveState = .failed("This encounter is too old to tag here. Add tags from their profile timeline.")
        } catch {
            saveState = .failed("Tags weren't saved. \(error.userFacingMessage)")
        }
    }

    func dismissRecommendation() {
        recommendationDismissed = true
    }

    func rsvp(_ env: AppEnvironment) async -> Bool {
        guard let recommendation else { return false }
        rsvpPending = true
        defer { rsvpPending = false }
        do {
            _ = try await env.events.rsvp(beaconID: recommendation.beaconID)
            recommendationDismissed = true
            return true
        } catch {
            return false
        }
    }
}
