import Foundation

/// Recently viewed timelines, held in memory for the session so reopening a conversation
/// paints instantly and refreshes in place (spec §31.3, contract 5 "cached"). Decrypted text
/// is never written to disk; the cache is dropped on sign-out and memory pressure.
@MainActor
public final class ConversationTimelineCache {
    private var timelines: [String: [ChatMessageItem]] = [:]
    private var order: [String] = []
    private let maxConversations = 40
    private let maxMessagesPerConversation = 80

    public init() {}

    public func items(for key: String) -> [ChatMessageItem]? {
        timelines[key]
    }

    public func store(_ items: [ChatMessageItem], for keys: [String]) {
        let trimmed = Array(items.suffix(maxMessagesPerConversation))
        for key in keys where !key.isEmpty {
            timelines[key] = trimmed
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > maxConversations {
            timelines[order.removeFirst()] = nil
        }
    }

    public func clear() {
        timelines = [:]
        order = []
    }
}
