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

    @Test("Only rows arriving at the end (messages, typing) animate in")
    func tailChange() {
        let old: [ChatTimelineRow] = [.message("5"), .message("6"), .typing]
        let arrived = ChatTimelineView.Coordinator.tailChange(old: old, new: [.message("5"), .message("6"), .message("7")])
        #expect(arrived?.added == [.message("7")])
        #expect(arrived?.removed == [.typing])
        #expect(ChatTimelineView.Coordinator.tailChange(old: [.message("5")], new: [.message("5"), .typing])?.added == [.typing])
        // Prepends, removals of messages and big reloads jump without animation.
        #expect(ChatTimelineView.Coordinator.tailChange(old: [.message("5")], new: [.message("4"), .message("5")]) == nil)
        #expect(ChatTimelineView.Coordinator.tailChange(old: [.message("5"), .message("6")], new: [.message("5")]) == nil)
        #expect(ChatTimelineView.Coordinator.tailChange(old: [], new: [.message("5")]) == nil)
    }

    @Test("A receipt update never blanks a photo or un-reads a message")
    @MainActor
    func realtimeUpdateMerge() {
        let media = MessageMedia(kind: .image, mimeType: "image/jpeg", fileName: nil, sizeBytes: nil, durationSeconds: nil,
                                 remoteURL: "https://x/p.jpg", storagePath: nil, v2: nil, fileKey: nil, plaintextSha256: nil, isDisposable: false)
        var existing = ChatMessageItem(id: "m1", chatID: "c", senderID: "peer", senderName: "Peer", content: "", messageType: .image,
                                       deliveryStatus: .read, isOutgoing: false, replyToSnippet: "quote", media: media, clientMessageID: "client-1")
        existing.reactions = [ReactionSummary(reactionType: "👍", count: 1, userReacted: true)]
        // An UPDATE whose metadata/content were omitted (unchanged TOAST) and older receipt state.
        let update = ChatMessageItem(id: "m1", chatID: "c", senderID: "peer", senderName: "Peer", content: "", rawContent: "",
                                     messageType: .image, deliveryStatus: .delivered, isOutgoing: false)
        let merged = ConversationModel.merged(existing: existing, update: update)
        #expect(merged.media == media)
        #expect(merged.stableID == "client-1")
        #expect(merged.replyToSnippet == "quote")
        #expect(merged.reactions.count == 1)
        #expect(merged.deliveryStatus == .read)

        // A real edit still lands.
        let edit = ChatMessageItem(id: "m1", chatID: "c", senderID: "peer", senderName: "Peer", content: "new", rawContent: "e2e:x",
                                   deliveryStatus: .read, isOutgoing: false, isEdited: true)
        #expect(ConversationModel.merged(existing: existing, update: edit).content == "new")
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

@Suite("Search routing")
@MainActor
struct SearchRoutingTests {
    @Test("Search, chat and profile deep links parse")
    func deepLinks() {
        let router = AppRouter()
        #expect(router.searchQuery(from: URL(string: "click://search?q=pizza")!) == "pizza")
        #expect(router.searchQuery(from: URL(string: "https://joinclick.co/search?q=tacos")!) == "tacos")
        #expect(router.searchQuery(from: URL(string: "click://hub/abc")!) == nil)
        #expect(router.parseIncomingURL(URL(string: "click://chat/chat-1?m=msg-9")!) == .conversation(chatID: "chat-1", messageID: "msg-9"))
        #expect(router.parseIncomingURL(URL(string: "click://profile/user-2")!) == .publicProfile(userID: "user-2"))
    }

    @Test("A route chosen in search opens only after the sheet dismisses")
    func routeAfterDismiss() {
        let router = AppRouter()
        router.presentSearch(query: "x")
        #expect(router.searchRequest?.query == "x")
        router.openFromSearch(.hub(hubID: "h"))
        #expect(router.searchRequest == nil)
        #expect(router.homePath.isEmpty)
        router.searchDidDismiss()
        #expect(router.homePath == [.hub(hubID: "h")])
    }

    @Test("Unified search response decodes every domain")
    func decode() {
        let root: [String: Any] = [
            "people": [["userId": "u", "name": "Lena", "context": "In a hub with you"]],
            "events": [["beaconId": "b", "title": "Jazz night", "locationName": "Blue Moon"]],
            "hits": [["messageId": "m", "chatId": "c", "snippet": "see you"]]
        ]
        let results = GlobalSearchView.decodeRemote(root)
        #expect(results.people.map(\.name) == ["Lena"])
        #expect(results.events.map(\.title) == ["Jazz night"])
        #expect(results.hits.map(\.messageID) == ["m"])
    }
}

@Suite("Soundtracks and shared media")
struct SoundtrackTests {
    @Test("Links match the server's allowlist exactly")
    func allowlist() {
        #expect(BeaconFormRules.isMusicLink("https://music.youtube.com/watch?v=abc"))
        #expect(BeaconFormRules.isMusicLink("https://music.apple.com/us/album/x/1?i=2"))
        #expect(!BeaconFormRules.isMusicLink("https://soundcloud.com/a/b"))
        #expect(!BeaconFormRules.isMusicLink("http://open.spotify.com/track/1"))
        #expect(!BeaconFormRules.isMusicLink("https://m.youtube.com/watch?v=1"))
    }

    @Test("Album art is upscaled; only Apple previews are trusted")
    func artworkAndPreview() {
        #expect(SoundtrackResolver.artwork("https://is1-ssl.mzstatic.com/a/b.jpg/100x100bb.jpg") == "https://is1-ssl.mzstatic.com/a/b.jpg/600x600bb.jpg")
        #expect(SoundtrackResolver.isTrustedPreview("https://audio-ssl.itunes.apple.com/x.m4a"))
        #expect(!SoundtrackResolver.isTrustedPreview("https://evil.example.com/x.m4a"))
        #expect(!SoundtrackResolver.isTrustedPreview("http://audio-ssl.itunes.apple.com/x.m4a"))
    }

    @Test("Beacons parse preview and art; an uploaded photo still wins the banner")
    func beaconParse() {
        let row: [String: Any] = ["id": "b", "lat": 1.0, "lng": 2.0, "beacon_type": "soundtrack", "metadata": [
            "track_name": "Song", "artist_name": "Artist",
            "preview_url": "https://audio-ssl.itunes.apple.com/p.m4a",
            "album_art_url": "https://is1-ssl.mzstatic.com/x/100x100bb.jpg"]]
        let beacon = MapBeacon.decode(row)
        #expect(beacon?.title == "Song — Artist")
        #expect(beacon?.previewURL == "https://audio-ssl.itunes.apple.com/p.m4a")
        #expect(beacon?.imageURL == "https://is1-ssl.mzstatic.com/x/600x600bb.jpg")
    }

    @Test("Older shared-media pages append without duplicates and stop when exhausted")
    func pagingMerge() {
        func item(_ id: String, _ t: Double) -> SharedItem {
            SharedItem(id: id, chatID: "c", senderID: "s", messageType: "image", createdAt: Date(timeIntervalSince1970: t), beaconID: nil, beaconTitle: nil)
        }
        var first = SharedTabs(chatID: "c", media: [item("a", 3), item("b", 2)], files: [], beacons: [],
                               mediaRows: Data(#"[{"id":"a"},{"id":"b"}]"#.utf8))
        first.hasMore = true
        var page = SharedTabs(chatID: "c", media: [item("b", 2), item("c", 1)], files: [], beacons: [],
                              mediaRows: Data(#"[{"id":"b"},{"id":"c"}]"#.utf8))
        page.hasMore = true
        let merged = first.appending(page)
        #expect(merged.media.map(\.id) == ["a", "b", "c"])
        #expect(merged.oldestAttachment == Date(timeIntervalSince1970: 1))
        #expect(merged.hasMore == true)
        let rows = (try? JSONSerialization.jsonObject(with: merged.mediaRows)) as? [[String: Any]]
        #expect(rows?.count == 3)
        #expect(merged.appending(page).hasMore == false)   // nothing new: stop paging
    }
}

@Suite("History paging with tombstones")
struct HistoryTombstoneTests {
    private func row(_ id: String, _ seconds: Double, deleted: Bool = false) -> ChatMessageItem {
        var item = ChatMessageItem(id: id, chatID: "c", senderID: "peer", senderName: "Peer", content: "x",
                                   createdAt: Date(timeIntervalSince1970: seconds), deliveryStatus: .read, isOutgoing: false)
        item.isDeleted = deleted
        return item
    }

    @Test func oldTombstoneStaysOutOfALaterPage() {
        // A full page spanning 100…139s; the server also sent a tombstone from 5s.
        let page = (0..<40).map { row("m\($0)", 100 + Double($0)) }
        let tombstones = [row("t-old", 5, deleted: true), row("t-in", 120.5, deleted: true)]
        let kept = ChatRepository.tombstones(tombstones, within: page, cursor: nil, around: false, since: false, limit: 40)
        #expect(kept.map(\.id) == ["t-in"])
    }

    @Test func olderPageKeepsOnlyTombstonesBelowTheCursor() {
        let page = (0..<40).map { row("m\($0)", 100 + Double($0)) }
        let tombstones = [row("t-new", 150, deleted: true), row("t-in", 110, deleted: true)]
        let kept = ChatRepository.tombstones(tombstones, within: page, cursor: 140_000, around: false, since: false, limit: 40)
        #expect(kept.map(\.id) == ["t-in"])
    }

    @Test func shortPageReachesTheStartAndDeltasKeepEverything() {
        let page = [row("m1", 100)]
        let old = [row("t-old", 5, deleted: true)]
        #expect(ChatRepository.tombstones(old, within: page, cursor: nil, around: false, since: false, limit: 40).count == 1)
        #expect(ChatRepository.tombstones(old, within: [], cursor: nil, around: false, since: true, limit: 40).count == 1)
    }

    @Test func tombstonesDontMakeAPageFull() {
        let short = (0..<39).map { row("m\($0)", Double($0)) } + [row("t", 50, deleted: true)]
        #expect(!ConversationModel.isFullPage(short))
        #expect(ConversationModel.isFullPage((0..<40).map { row("m\($0)", Double($0)) }))
    }
}
