import Testing
import Foundation
@testable import Click

@Suite("Clicks inbox data")
struct ClicksInboxTests {
    private let me = "usr_me"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ id: String, peer: String, createdAgo: TimeInterval, hasBegun: Bool = true, status: String = "active") -> [String: Any] {
        [
            "id": id,
            "user_ids": [me, peer],
            "created": (now.timeIntervalSince1970 - createdAgo) * 1000,
            "has_begun": hasBegun,
            "status": status
        ]
    }

    @Test("Avatar fallback colors match the Android client's Java-style hash")
    func avatarPaletteParity() {
        // Fixtures computed with Kotlin's `seed.fold(0) { acc, ch -> 31 * acc + ch.code }` semantics.
        #expect(ClickColors.GeneratedContent.avatarPaletteIndex(for: "usr_marcus") == 6)
        #expect(ClickColors.GeneratedContent.avatarPaletteIndex(for: "3f1c2a9e-7b4d-4e21-9a0b-5c6d7e8f9012") == 3)
        #expect(ClickColors.GeneratedContent.avatarPaletteIndex(for: "Zoë 🙂") == 5)
        #expect(ClickColors.GeneratedContent.avatarPaletteIndex(for: "  ") == 0)
    }

    @Test("Initials follow the Android rules")
    func initialsParity() {
        #expect(Phase3Repository.initials(from: "Theo Park") == "TP")
        #expect(Phase3Repository.initials(from: "Mary Anne Smith") == "MS")
        #expect(Phase3Repository.initials(from: "cher") == "CH")
        #expect(Phase3Repository.initials(from: "  ") == "?")
    }

    @Test("Preview RPC rows are keyed by connection with direction and unread state")
    func parsesInboxPreviews() {
        let rows: [[String: Any]] = [
            [
                "chat_id": "chat_1", "connection_id": "conn_1",
                "last_message_user_id": me, "last_message_content": "e2e:abc",
                "last_message_time_created": 1_789_999_000_000.0, "last_message_type": "text",
                "last_message_is_read": true, "unread_count": 0
            ],
            [
                "chat_id": "chat_2", "connection_id": "conn_2",
                "last_message_user_id": "usr_theo", "last_message_content": "",
                "last_message_type": "image", "last_message_metadata": ["disposable_roll": true],
                "unread_count": 3
            ],
            ["chat_id": "chat_3", "connection_id": NSNull(), "unread_count": 1]
        ]
        let previews = Phase3Repository.inboxPreviews(from: rows, currentUserID: me)

        #expect(previews.count == 2)
        #expect(previews["conn_1"]?.lastMessage?.isOutgoing == true)
        #expect(previews["conn_1"]?.lastMessage?.isRead == true)
        #expect(previews["conn_1"]?.lastMessageAt == Date(timeIntervalSince1970: 1_789_999_000))
        #expect(previews["conn_2"]?.unreadCount == 3)
        #expect(previews["conn_2"]?.lastMessage?.isDisposable == true)
        #expect(previews["conn_2"]?.chatID == "chat_2")
    }

    @Test("Inbox items merge names, previews, and Core, newest activity first")
    func buildsInboxItems() {
        let rows = [
            row("conn_old", peer: "usr_ada", createdAgo: 30 * 86_400),
            row("conn_new", peer: "usr_theo", createdAgo: 10 * 86_400)
        ]
        let previews = [
            "conn_old": Phase3Repository.InboxPreviewRow(
                chatID: "chat_old",
                lastMessage: InboxLastMessage(content: "hi", messageType: "text", isOutgoing: false, isRead: false),
                lastMessageAt: now.addingTimeInterval(-60),
                unreadCount: 4
            )
        ]
        let items = Phase3Repository.inboxItems(
            rows: rows,
            currentUserID: me,
            identities: ["usr_ada": .init(name: "Ada Lovelace", avatarURL: "https://example.com/a.jpg")],
            previews: previews,
            coreIDs: ["conn_new"],
            archived: false,
            now: now
        )

        #expect(items.map(\.id) == ["conn_old", "conn_new"])
        #expect(items[0].displayName == "Ada Lovelace")
        #expect(items[0].initials == "AL")
        #expect(items[0].avatarUrl == "https://example.com/a.jpg")
        #expect(items[0].unreadCount == 4)
        #expect(items[0].chatID == "chat_old")
        #expect(items[0].isCore == false)
        #expect(items[1].displayName == "Click user")
        #expect(items[1].isCore)
        #expect(items[1].unreadCount == 0)
    }

    @Test("Only unstarted pending connections inside 48 hours get a say-hi deadline")
    func sayHiDeadline() {
        let rows = [
            row("fresh", peer: "a", createdAgo: 12 * 3600, hasBegun: false, status: "pending"),
            row("started", peer: "b", createdAgo: 12 * 3600, hasBegun: true, status: "pending"),
            row("lapsed", peer: "c", createdAgo: 50 * 3600, hasBegun: false, status: "pending"),
            row("kept", peer: "d", createdAgo: 12 * 3600, hasBegun: false, status: "kept")
        ]
        let items = Phase3Repository.inboxItems(
            rows: rows, currentUserID: me, identities: [:], previews: [:],
            coreIDs: [], archived: false, now: now
        )
        let deadlines = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.sayHiDeadline) })

        #expect(deadlines["fresh"]! == now.addingTimeInterval(36 * 3600))
        #expect(deadlines["started"]! == nil)
        #expect(deadlines["lapsed"]! == nil)
        #expect(deadlines["kept"]! == nil)

        let archived = Phase3Repository.inboxItems(
            rows: [rows[0]], currentUserID: me, identities: [:], previews: [:],
            coreIDs: [], archived: true, now: now
        )
        #expect(archived[0].sayHiDeadline == nil)
    }

    @Test("Snapshots cached before inbox fields existed still decode")
    func legacyCacheDecodes() throws {
        let legacy = """
        {"connections":[{"id":"c1","userID":"u1","connectionID":"c1","displayName":"Ada","handle":"",
        "initials":"AD","isOnline":false,"presenceKnown":false,"lastActiveRelative":"2h ago",
        "encounterLocation":"","mutualTags":[],"encounterCount":0,"segment":"All"}]}
        """
        let snapshot = try JSONDecoder().decode(ClicksSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.connections.first?.unreadCount == 0)
        #expect(snapshot.connections.first?.isCore == false)
    }
}

@Suite("Clicks inbox formatting")
struct InboxFormattingTests {
    private func item(_ message: InboxLastMessage?, location: String = "", deadline: Date? = nil) -> ConnectionItem {
        ConnectionItem(
            id: "c", userID: "u", connectionID: "c", displayName: "Ada", handle: "", initials: "AD",
            isOnline: false, lastActiveRelative: "", encounterLocation: location,
            lastMessage: message, sayHiDeadline: deadline
        )
    }

    @Test("Previews label media, keep ciphertext out of the UI, and show decrypted text")
    func previews() {
        let text = { (content: String) in InboxLastMessage(content: content, messageType: "text", isOutgoing: false, isRead: false) }
        #expect(InboxFormatting.preview(for: item(text("hey")), decryptedText: nil) == "hey")
        #expect(InboxFormatting.preview(for: item(text("e2e:xyz")), decryptedText: nil) == "Message")
        #expect(InboxFormatting.preview(for: item(text("e2e:xyz")), decryptedText: "see you\nsoon") == "see you soon")
        #expect(InboxFormatting.preview(for: item(InboxLastMessage(content: "", messageType: "audio", isOutgoing: false, isRead: false)), decryptedText: nil) == "Voice note")
        #expect(InboxFormatting.preview(for: item(InboxLastMessage(content: "", messageType: "image", isOutgoing: false, isRead: false, isDisposable: true)), decryptedText: nil) == "Click Drop")
        #expect(InboxFormatting.preview(for: item(nil, location: "Suzzallo"), decryptedText: nil) == "Met at Suzzallo")
        #expect(InboxFormatting.preview(for: item(nil, deadline: Date()), decryptedText: nil) == "New Click · say hi")
    }

    @Test("Timestamps read like a messaging inbox")
    func timestamps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let locale = Locale(identifier: "en_US")
        // Wednesday 2026-09-23 18:00 PDT
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 18)))
        let format = { (date: Date) in InboxFormatting.timestamp(for: date, now: now, calendar: calendar, locale: locale) }

        #expect(format(now.addingTimeInterval(-3600)) == "5:00\u{202F}PM")
        #expect(format(now.addingTimeInterval(-86_400)) == "Yesterday")
        #expect(format(now.addingTimeInterval(-2 * 86_400)) == "Mon")
        #expect(format(now.addingTimeInterval(-9 * 86_400)) == "9/14")
    }

    @Test("Say-hi countdown rounds up and disappears when lapsed")
    func sayHiRemaining() {
        let now = Date()
        #expect(InboxFormatting.sayHiRemaining(until: now.addingTimeInterval(35.5 * 3600), now: now) == "36h left")
        #expect(InboxFormatting.sayHiRemaining(until: now.addingTimeInterval(30 * 60), now: now) == "<1h left")
        #expect(InboxFormatting.sayHiRemaining(until: now.addingTimeInterval(-1), now: now) == nil)
    }
}
