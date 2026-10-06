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

    /// The verified group (clique) chat for a group Click. The server only creates the group
    /// connection and the pairwise connections; the group chat is a clique a client must create.
    enum GroupState: Equatable {
        case idle, preparing
        case ready(CliqueItem)
        case failed(String)
    }

    let match: ProximityMatch
    let method: Method
    let suggestions: [ContextTag]
    /// What confirmed this connection on this phone (signals and location accuracy).
    let verification: ConnectionVerification?
    /// A one-off explanation shown above the details (e.g. another phone confirmed first).
    let notice: String?
    /// When this phone saw the connection.
    let connectedAt: Date

    private(set) var encounterCount: Int?
    /// This pair's encounters (newest first), for the souvenir.
    private(set) var encounters: [Encounter] = []
    private(set) var isExtendedHangout = false
    private(set) var placeName: String?
    /// This tap's encounter (this viewer's row merged with the others), once loaded.
    private(set) var latestEncounter: Encounter?
    /// Details are still loading (place names arrive a moment after the encounter is saved).
    private(set) var isLoadingDetails = true
    private(set) var recommendation: EventRecommendation?
    private(set) var saveState: SaveState = .idle
    private(set) var recommendationDismissed = false
    private(set) var rsvpPending = false
    private(set) var groupState: GroupState = .idle

    /// Ordered selection; custom text is stored as its own label (KMP convention).
    var selectedTags: [String] = []
    var customTag = ""

    init(
        match: ProximityMatch,
        method: Method,
        verification: ConnectionVerification? = nil,
        notice: String? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.match = match
        self.method = method
        self.verification = verification
        self.notice = notice
        self.connectedAt = now
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

    /// The place for the details card: venue or first label component, else area.
    var detailsPlace: String? {
        placeName ?? latestEncounter.flatMap { encounter in
            [encounter.neighbourhood, encounter.city].compactMap { $0 }.first
        }
    }

    /// "12°C · Clear", when the server attached weather.
    var detailsWeather: String? {
        guard let encounter = latestEncounter else { return nil }
        let parts = [
            encounter.temperatureCelsius.map {
                Measurement(value: $0, unit: UnitTemperature.celsius)
                    .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
            },
            encounter.weatherCondition
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var verificationLine: String {
        let summary = verification?.summary ?? ""
        switch method {
        case .tap: return summary.isEmpty ? "Tap to Connect" : summary
        case .qr: return summary.isEmpty ? "QR code" : summary
        }
    }

    /// Encounter history and an event suggestion, loaded in parallel after the reveal. Both are
    /// enrichments: a failure just leaves them out. The place name is added by the server a
    /// moment after the encounter is saved, so a missing one is fetched once more.
    func load(_ env: AppEnvironment, placeRetryDelay: Duration = .milliseconds(2500)) async {
        defer { isLoadingDetails = false }
        guard let connectionID = match.connectionID ?? primaryPeer?.connectionID else { return }
        let viewerID = env.session.currentSession?.userId
        async let history = try? env.profiles.encounters(connectionID: connectionID, viewerID: viewerID)
        async let suggestion = eventSuggestion(env, connectionID: connectionID)
        if let encounters = await history { apply(encounters) }
        recommendation = await suggestion

        guard placeName == nil, latestEncounter?.latitude != nil || latestEncounter == nil else { return }
        try? await Task.sleep(for: placeRetryDelay)
        guard !Task.isCancelled,
              let encounters = try? await env.profiles.encounters(connectionID: connectionID, viewerID: viewerID) else { return }
        apply(encounters)
    }

    /// One-to-one only: a group has no single peer to go with.
    private func eventSuggestion(_ env: AppEnvironment, connectionID: String) async -> EventRecommendation? {
        guard !isGroup else { return nil }
        return try? await env.encounterContext.eventRecommendation(
            connectionID: connectionID,
            latitude: env.location.lastFix?.coordinate.latitude,
            longitude: env.location.lastFix?.coordinate.longitude
        )
    }

    private func apply(_ encounters: [Encounter]) {
        self.encounters = encounters
        encounterCount = encounters.count
        guard let latest = encounters.first else { return }
        // Only this tap's row: an older row means the server merged into it (Extended Hangout).
        latestEncounter = latest
        placeName = latest.placeName
        // The server debounces a same-place, same-12-hour reconnect into the previous
        // row and tags it "Extended Hangout"; a row older than this tap means that.
        isExtendedHangout = !isGroup && match.isReconnect
            && latest.contextTags.contains(where: ContextTagTaxonomy.isExtendedHangout)
    }

    /// Everyone in this group Click, including the viewer.
    func groupMemberIDs(viewerID: String) -> [String] {
        Array(Set(match.groupMemberIDs + match.peers.map(\.id) + [viewerID])).sorted()
    }

    /// Finds or creates the verified group chat for a group Click. Every member's phone runs this,
    /// so the lowest member ID creates right away and the others first wait for that group to
    /// appear (create_verified_clique rejects a second group for the same members anyway).
    func prepareGroup(_ env: AppEnvironment, conversations: ConversationListModel) async {
        guard isGroup, let userID = env.session.currentSession?.userId else { return }
        switch groupState {
        case .preparing, .ready: return
        case .idle, .failed: break
        }
        let members = groupMemberIDs(viewerID: userID)
        guard members.count >= 3 else { return }
        groupState = .preparing

        func existing() async -> CliqueItem? {
            let groups = (try? await env.groups.groups(userID: userID)) ?? []
            return groups.first { Set($0.members.map(\.userID)) == Set(members) }
        }

        if let group = await existing() { return await open(group, env, conversations) }
        if members.first != userID {
            for wait in Self.creatorWaits {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { groupState = .idle; return }
                if let group = await existing() { return await open(group, env, conversations) }
            }
        }

        let peers = members.filter { $0 != userID }
        do {
            let pairs = try await env.groups.pairConnectionIDs(viewerID: userID, peerIDs: peers)
            let names = match.peers.map { HomeFeedModel.firstName($0.name) ?? $0.name }.sorted()
            _ = try await env.groups.create(creatorID: userID, connectionIDs: pairs, name: names.joined(separator: ", "))
        } catch {
            // Another member's phone may have created it between our check and our create.
            if let group = await existing() { return await open(group, env, conversations) }
            groupState = .failed("Couldn't set up the group chat. \(error.userFacingMessage)")
            return
        }
        if let group = await existing() {
            await open(group, env, conversations)
        } else {
            groupState = .failed("The group was created but couldn't be loaded yet. Pull to refresh Groups.")
        }
    }

    private func open(_ group: CliqueItem, _ env: AppEnvironment, _ conversations: ConversationListModel) async {
        groupState = .ready(group)
        _ = try? await env.chat.reconcileMembershipEpoch(chatID: group.chatID, participantUserIDs: group.members.map(\.userID))
        await conversations.refresh()
    }

    /// How long a non-creating member waits for the creator's group before creating it itself
    /// (the creator may be on Android, which only offers a prefilled group sheet).
    nonisolated static let creatorWaits: [Duration] = [.seconds(2), .seconds(3), .seconds(4)]

    func save(_ env: AppEnvironment) async {
        let tags = ContextTagPicker.resolved(selected: selectedTags, custom: customTag)
        guard let userID = env.session.currentSession?.userId else { return }
        let connectionIDs = taggableConnectionIDs
        guard !connectionIDs.isEmpty else {
            saveState = .failed("This connection isn't ready for tags yet.")
            return
        }
        saveState = .saving
        // Sensor context is recorded on its own when the screen opens (`recordSensorContext`).
        let sensor = EncounterSensorContext()
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

    /// Samples ambient noise now that the tap's microphone use is over, then writes it to this
    /// encounter (sensor-only patch; tags are saved separately). Silent on failure. The barometer
    /// was already read at the connection moment, so a later reading never replaces it.
    func recordSensorContext(_ env: AppEnvironment) async {
        guard env.settings.ambientNoiseOptIn,
              let userID = env.session.currentSession?.userId else { return }
        let connectionIDs = taggableConnectionIDs
        guard !connectionIDs.isEmpty else { return }
        let sensor = await EncounterSensorSampler.sample(settings: env.settings)
        guard !sensor.isEmpty else { return }
        for connectionID in connectionIDs {
            try? await env.encounterContext.saveContext(connectionID: connectionID, tags: [], sensor: sensor, reportingUserID: userID)
        }
    }

    /// Where this Click's tags and sensor context go: the group itself plus each person's own
    /// connection (a group confirm returns the group id for everyone, so de-duplicate).
    private var taggableConnectionIDs: [String] {
        var seen = Set<String>()
        let ids = isGroup ? [match.connectionID] + match.peers.map(\.connectionID) : [match.connectionID ?? primaryPeer?.connectionID]
        return ids.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// What this tap added (new spot, level, streak, milestone), once history has loaded.
    var highlights: HangoutHighlights? { HangoutHighlights.of(encounters) }

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
