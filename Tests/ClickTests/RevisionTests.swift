import Testing
import Foundation
@testable import Click

@Suite("Profile timeline labels")
struct EncounterLabelTests {
    @Test("Chips are human-readable, never raw enum values")
    func chips() {
        let encounter = Encounter(
            id: "e", date: .now, place: "21310 11th Drive Southeast, Bothell", eventTitle: nil, eventBeaconID: nil,
            contextTags: ["extended_hangout", "study"], noiseLevel: "LOUD", elevation: "BELOW_GROUND",
            venue: "Gas Works Park", temperatureCelsius: 16, weatherCondition: "Clear", relativeAltitudeMeters: 14
        )
        let chips = EncounterLabels.chips(for: encounter, locale: Locale(identifier: "en_US"))
        #expect(chips.contains("Extended hangout"))
        #expect(chips.contains("Study"))
        #expect(chips.contains("Lively"))
        #expect(chips.contains("Below ground"))
        #expect(chips.contains("+14 m"))
        #expect(chips.contains { $0.contains("Clear") && $0.contains("°") })
        #expect(!chips.contains { $0.contains("_") || $0 == $0.uppercased() && $0.count > 3 && $0.allSatisfy(\.isLetter) })
        #expect(encounter.placeName == "Gas Works Park")
        #expect(EncounterLabels.elevation("GROUND_LEVEL") == nil)
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
