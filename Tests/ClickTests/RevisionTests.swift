import Testing
import Foundation
@testable import Click

@Suite("Profile timeline labels")
struct EncounterLabelTests {
    @Test("Chips and lines are human-readable, never raw enum values")
    func chips() {
        let encounter = Encounter(
            id: "e", date: .now, place: "21310 11th Drive Southeast, Bothell", eventTitle: nil, eventBeaconID: nil,
            contextTags: ["extended_hangout", "study", "met_face_to_face"], noiseLevel: "LOUD", elevation: "BELOW_GROUND",
            venue: "Gas Works Park", temperatureCelsius: 16, weatherCondition: "Clear", relativeAltitudeMeters: 14
        )
        let chips = EncounterLabels.chips(for: encounter)
        #expect(chips.contains("Extended hangout"))
        #expect(chips.contains("📚 Study Session"))
        #expect(chips.contains("Met face to face"))
        let lines = EncounterLabels.lines(for: encounter).map(\.text)
        #expect(lines.count == 2)
        #expect(lines[1] == "Gas Works Park")
        #expect(!(chips + lines).contains { $0.contains("_") })
        #expect(encounter.placeName == "Gas Works Park")
        #expect(EncounterLabels.elevation("GROUND_LEVEL") == "Ground level")
    }

    @Test("KMP timeline formats")
    func kmpFormats() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 22; components.hour = 19; components.minute = 4
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = calendar.date(from: components)!
        #expect(EncounterLabels.whenLine(date, timeZone: utc) == "Tue, Sep 22, 2026 · 7:04 PM")
        #expect(EncounterLabels.placeLine(locationName: "Gas Works Park", displayLocation: "Seattle", neighbourhood: "Wallingford") == "Gas Works Park • Wallingford, Seattle")
        #expect(EncounterLabels.placeLine(locationName: "Cafe", displayLocation: "Seattle", neighbourhood: nil) == "Cafe · Seattle")
    }

    @Test("An encounter with 6 metrics produces 6 pills in table order with exact texts")
    func metricPills() {
        let encounter = Encounter(
            id: "e6",
            date: .now,
            place: "Gas Works Park",
            eventTitle: nil,
            eventBeaconID: nil,
            contextTags: [],
            noiseLevel: "QUIET",
            elevation: "ELEVATED",
            temperatureCelsius: 20,
            weatherCondition: "Clear",
            relativeAltitudeMeters: 12,
            windKph: 12,
            windDirectionDegrees: 45,
            compassAzimuth: 45
        )
        let pills = EncounterLabels.metricPills(for: encounter)
        #expect(pills.count == 6)
        #expect(pills[0] == EncounterLabels.MetricPill(symbol: "cloud", tintHex: "#B0BEC5", text: "Clear"))
        #expect(pills[1] == EncounterLabels.MetricPill(symbol: "thermometer.medium", tintHex: "#FFCC80", text: "68°F (20°C)"))
        #expect(pills[2] == EncounterLabels.MetricPill(symbol: "wind", tintHex: "#81D4FA", text: "12 km/h NE"))
        #expect(pills[3] == EncounterLabels.MetricPill(symbol: "waveform", tintHex: "#69F0AE", text: "Quiet"))
        #expect(pills[4] == EncounterLabels.MetricPill(symbol: "mountain.2", tintHex: "#90CAF9", text: "Elevated · 12 m"))
        #expect(pills[5] == EncounterLabels.MetricPill(symbol: "safari", tintHex: "#B39DDB", text: "45°"))
    }

    @Test("Without a venue, the place is the first address component")
    func placeFallback() {
        let encounter = Encounter(id: "e", date: .now, place: "Café Allegro, 4214 University Way", eventTitle: nil,
                                  eventBeaconID: nil, contextTags: [], noiseLevel: nil, elevation: nil)
        #expect(encounter.placeName == "Café Allegro")
    }
}

@Suite("Chat beacon cards and timeline cache")
struct ChatRevisionTests {
    @Test("Beacon shares parse into a card instead of 'Beacon: …' text")
    func beaconCard() {
        let card = SharedBeacon.parse(
            messageType: "beacon",
            metadata: ["beacon_id": "b1", "beacon_type": "event", "title": "Machine Learning",
                       "schedule_label": "Fri 8 PM", "location_name": "UW"],
            content: "Beacon: Machine Learning"
        )
        #expect(card?.isEvent == true)
        #expect(card?.title == "Machine Learning")
        #expect(SharedBeacon.parse(messageType: "text", metadata: [:], content: "hi") == nil)
    }

    @Test("Reopening a conversation paints its cached timeline immediately")
    @MainActor
    func cachedTimeline() {
        let cache = ConversationTimelineCache()
        let item = ChatMessageItem(id: "m1", chatID: "chat-1", senderID: "u", senderName: "U", content: "hey", isOutgoing: false)
        cache.store([item], for: ["chat-1", "conn-1"])
        let identity = ConversationIdentity(chatID: "conn-1", connectionID: "conn-1", peerUserID: "u", peerDisplayName: "U")
        let model = ConversationModel(identity: identity, chatRepository: NoopRepo(), currentUserID: "me", timelineCache: cache)
        #expect(model.items.map(\.id) == ["m1"])
        #expect(model.phase == .loaded)
        cache.clear()
        #expect(cache.items(for: "chat-1") == nil)
    }

    private struct NoopRepo: ChatRepositoryProtocol {
        func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String { chatID }
        func fetchMessages(conversation: ConversationIdentity, currentUserID: String, cursor: Int64?, limit: Int) async throws -> [ChatMessageItem] { [] }
        func sendMessage(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, content: String,
                         replyToID: String?, replyToSnippet: String?, replyToSenderName: String?, clientMessageID: String) async throws -> ChatMessageItem {
            throw ChatRepositoryError.unresolvedChat
        }
        func editMessage(message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String, newContent: String) async throws {}
        func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {}
        func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {}
        func markRead(chatID: String, messageIDs: [String]) async throws {}
        func markDelivered(chatID: String, messageIDs: [String]) async throws {}
        func registerDevice() async throws {}
        func decodeRealtimeMessage(_ payload: RealtimeMessagePayload, conversation: ConversationIdentity, currentUserID: String) async throws -> ChatMessageItem {
            throw ChatRepositoryError.unresolvedChat
        }
    }
}

@Suite("Round 3 behaviors")
struct Round3Tests {
    private func person(_ id: String, daysQuiet: Double, core: Bool = false) -> ConnectionItem {
        ConnectionItem(id: id, userID: "u-\(id)", connectionID: id, displayName: id, handle: "", initials: "X",
                       isOnline: false, lastActiveRelative: "", encounterLocation: "Café",
                       lastActivityAt: Date().addingTimeInterval(-daysQuiet * 86_400), isCore: core)
    }

    @Test("Reconnect picks the quietest Click past 14 days, Core first, and respects snooze")
    func reconnectPick() {
        UserDefaults.standard.removeObject(forKey: "home.reconnect.snoozed")
        let picks = [person("recent", daysQuiet: 2), person("quiet", daysQuiet: 40), person("core", daysQuiet: 20, core: true)]
        #expect(ReconnectSuggestion.pick(from: picks)?.id == "core")
        ReconnectSuggestion.snooze(picks[2])
        #expect(ReconnectSuggestion.pick(from: picks)?.id == "quiet")
        #expect(ReconnectSuggestion.pick(from: [person("recent", daysQuiet: 2)]) == nil)
        UserDefaults.standard.removeObject(forKey: "home.reconnect.snoozed")
    }

    @Test("People here ranks by shared interests plus mutuals, high to low")
    func bestMatch() {
        func attendee(_ id: String, interests: Int, mutuals: Int, rel: DirectoryAttendee.Relationship = .stranger) -> DirectoryAttendee {
            DirectoryAttendee(userID: id, name: id, avatarURL: nil, sharedInterests: Array(repeating: "x", count: interests),
                              relationship: rel, mutualNames: [], mutualCount: mutuals, signedUpAt: nil)
        }
        let ranked = EventDirectoryView.bestMatch([attendee("a", interests: 1, mutuals: 0), attendee("b", interests: 2, mutuals: 3),
                                                   attendee("c", interests: 0, mutuals: 1)])
        #expect(ranked.map(\.userID) == ["b", "a", "c"])
        #expect(EventDirectoryView.details(attendee("d", interests: 2, mutuals: 1)).count == 2)
    }

    @Test("Shared beacon metadata mirrors KMP and parses back into a card")
    func beaconShare() throws {
        let beacon = try #require(MapBeacon.decode(["id": "b9", "beacon_type": "event", "lat": 1.0, "lng": 2.0,
                                                    "metadata": ["title": "Hack Night", "location_name": "Allen Center"]]))
        let meta = ChatRepository.beaconMetadata(beacon, clientMessageID: "c1")
        #expect(meta["beacon_id"] as? String == "b9")
        #expect(meta["share_url"] as? String == "https://joinclick.co/e/b9")
        let card = SharedBeacon.parse(messageType: "beacon", metadata: meta, content: "Beacon: Hack Night")
        #expect(card?.title == "Hack Night")
        #expect(card?.locationName == "Allen Center")
    }

    @Test("Click Drops stay locked until 24 h after sending")
    func clickDropLock() {
        let locked = MessageMedia.parse(messageType: "image", metadata: [
            "media_url": "https://x/storage/v1/object/sign/chat-attachments/c/u/1.jpg?t=1", "disposable_roll": true,
            "collaboration_ttl": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
        ], decryptedContent: " ", chatID: "c")
        #expect(locked?.isLocked() == true)
        #expect(locked?.isLocked(now: Date().addingTimeInterval(7_200)) == false)
    }
}
