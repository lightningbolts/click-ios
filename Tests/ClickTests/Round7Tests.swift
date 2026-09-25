import Testing
import Foundation
@testable import Click

@Suite("Local store", .serialized)
struct LocalStoreTests {
    private func message(_ id: String, _ text: String, minutesAgo: Double) -> ChatMessageItem {
        ChatMessageItem(id: id, chatID: "c1", senderID: "peer", senderName: "Maya", content: text,
                        createdAt: Date().addingTimeInterval(-minutesAgo * 60), deliveryStatus: .read, isOutgoing: false)
    }

    @Test("Messages round-trip newest-last, page backwards, and are searchable")
    func messagesRoundTrip() async {
        let user = "test-\(UUID().uuidString)"
        let store = LocalStore.shared
        defer { store.wipe(userID: user) }
        let rows = (0..<50).map { message("m\($0)", $0 == 7 ? "pizza at seven" : "hello \($0)", minutesAgo: Double(50 - $0)) }
        store.upsertMessages(rows, conversation: "c1", userID: user)

        let latest = store.latestMessages(conversation: "c1", userID: user, limit: 10)
        #expect(latest.map(\.id) == (40..<50).map { "m\($0)" })

        let older = await store.messages(conversation: "c1", userID: user, before: latest[0].createdAt, limit: 5)
        #expect(older.map(\.id) == (35..<40).map { "m\($0)" })

        let hits = await store.searchMessages("pizz", userID: user)
        #expect(hits.map(\.messageID) == ["m7"])
    }

    @Test("Aliases resolve a connection ID to the canonical chat")
    func aliases() {
        let user = "test-\(UUID().uuidString)"
        let store = LocalStore.shared
        defer { store.wipe(userID: user) }
        store.upsertMessages([message("a", "hi", minutesAgo: 1)], conversation: "chat-canonical", userID: user)
        store.link(aliases: ["conn-1"], to: "chat-canonical", userID: user)
        #expect(store.latestMessages(conversation: "conn-1", userID: user, limit: 5).map(\.id) == ["a"])
    }

    @Test("Optimistic rows are never persisted; wipe deletes everything")
    func optimisticAndWipe() {
        let user = "test-\(UUID().uuidString)"
        let store = LocalStore.shared
        var sending = message("tmp", "sending", minutesAgo: 0)
        sending.deliveryStatus = .sending
        store.upsertMessages([sending, message("ok", "done", minutesAgo: 1)], conversation: "c", userID: user)
        #expect(store.latestMessages(conversation: "c", userID: user, limit: 5).map(\.id) == ["ok"])
        store.wipe(userID: user)
        #expect(store.latestMessages(conversation: "c", userID: user, limit: 5).isEmpty)
        store.wipe(userID: user)
    }

    @Test("Key/value values round-trip with their save date")
    func keyValue() {
        let user = "test-\(UUID().uuidString)"
        let store = LocalStore.shared
        defer { store.wipe(userID: user) }
        store.save(["a", "b"], key: "k", userID: user)
        let loaded = store.load([String].self, key: "k", userID: user)
        #expect(loaded?.value == ["a", "b"])
        #expect((loaded?.savedAt.timeIntervalSinceNow ?? -100) > -5)
    }
}

@Suite("Timeline and transport")
struct TimelineTransportTests {
    @Test("Prepends are detected (older rows above), appends are not")
    func prepend() {
        let old: [ChatTimelineRow] = [.message("5"), .message("6")]
        #expect(ChatTimelineView.Coordinator.isPrepend(old: old, new: [.message("3"), .message("4"), .message("5"), .message("6")]))
        #expect(!ChatTimelineView.Coordinator.isPrepend(old: old, new: [.message("5"), .message("6"), .message("7")]))
        #expect(ChatTimelineView.Coordinator.isPrepend(old: old + [.typing], new: [.message("4"), .message("5"), .message("6"), .typing]))
    }

    @Test("Realtime reconnects forever with capped backoff")
    func backoff() {
        #expect(ChatRealtimeManager.reconnectDelay(attempt: 1) == 0.5)
        #expect(ChatRealtimeManager.reconnectDelay(attempt: 10) == 5)
        #expect(ChatRealtimeManager.reconnectDelay(attempt: 500) == 30)
    }

    @Test("A cancelled retry never brings back an earlier failure")
    func cancelledRetry() {
        var state = ModuleState<[String]>(value: ["cached"])
        state.fail("boom")
        #expect(state.isStale)
        state.begin()
        state.fail(CancellationError())
        #expect(!state.isStale)
        #expect(state.value == ["cached"])
    }

    @Test("Screen refreshes retry transient failures, never auth or offline")
    func refreshRetryPolicy() {
        #expect(Transport.shouldRetryRefresh(APIError.timeout))
        #expect(Transport.shouldRetryRefresh(APIError.server(status: 503, code: nil, message: nil)))
        #expect(!Transport.shouldRetryRefresh(APIError.unauthorized))
        #expect(!Transport.shouldRetryRefresh(APIError.offline))
    }
}
