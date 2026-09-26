import Foundation
import SQLite3

/// On-device store for everything the app shows: message timelines (with full-text search),
/// the inbox snapshot, feed modules, profiles, events and hubs. Screens paint from here
/// instantly and the server only sends deltas, which keeps the app fast offline and cuts
/// Supabase egress (WhatsApp model).
///
/// - One SQLite database per signed-in user in Application Support (`LocalStore/<user>.sqlite`),
///   WAL mode, `completeUntilFirstUserAuthentication` file protection, excluded from backup,
///   deleted at sign-out.
/// - Decrypted message text is stored here (as WhatsApp does) so history and search work
///   offline. It never leaves the device and is never logged.
/// - All access goes through one serial queue. Reads used for the first frame of a screen are
///   synchronous (a few rows, well under a millisecond); writes are asynchronous.
public final class LocalStore: @unchecked Sendable {
    static let shared = LocalStore()

    private let queue = DispatchQueue(label: "click.local-store", qos: .userInitiated)
    private var db: OpaquePointer?
    private var openUserID: String?
    private var hasFTS = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Lifecycle

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalStore", isDirectory: true)
    }

    private static func fileURL(userID: String) -> URL {
        let safe = userID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).sqlite")
    }

    /// Opens (or switches to) the user's database. Must be called on `queue`.
    private func ensureOpen(_ userID: String) -> Bool {
        guard !userID.isEmpty else { return false }
        if openUserID == userID, db != nil { return true }
        closeLocked()
        let url = Self.fileURL(userID: userID)
        do {
            var directory = Self.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        } catch {
            ClickLog.store.error("could not create store directory: \(error.localizedDescription, privacy: .public)")
            return false
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            ClickLog.store.error("could not open local store")
            if let handle { sqlite3_close(handle) }
            return false
        }
        db = handle
        openUserID = userID
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
        migrate()
        return true
    }

    private func closeLocked() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        openUserID = nil
    }

    /// Sign-out: closes and deletes this user's database.
    func wipe(userID: String) {
        queue.sync {
            if openUserID == userID { closeLocked() }
            let url = Self.fileURL(userID: userID)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS messages (
            conv TEXT NOT NULL,
            id TEXT NOT NULL,
            created_ms INTEGER NOT NULL,
            sender TEXT NOT NULL DEFAULT '',
            body TEXT NOT NULL DEFAULT '',
            json BLOB NOT NULL,
            PRIMARY KEY (conv, id)
        );
        CREATE INDEX IF NOT EXISTS messages_by_time ON messages (conv, created_ms);
        CREATE TABLE IF NOT EXISTS conv_alias (alias TEXT PRIMARY KEY, conv TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, json BLOB NOT NULL, fetched_at REAL NOT NULL);
        """)
        hasFTS = exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            body, sender, conv UNINDEXED, id UNINDEXED, created_ms UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
        // Earlier builds stored islands (detached search windows; old tombstones from history
        // pages and from delta syncs), so history pages skipped a gap or stopped early with the
        // start wrongly marked reached. Messages are a cache: drop them once and refetch.
        if userVersion() < 3 {
            exec("DELETE FROM messages; DROP TABLE IF EXISTS conv_meta;")
            if hasFTS { exec("DELETE FROM messages_fts;") }
            exec("PRAGMA user_version = 3;")
        }
    }

    private func userVersion() -> Int64 {
        guard let db, let statement = Statement(db, "PRAGMA user_version") else { return 0 }
        return statement.step() ? statement.int64(0) : 0
    }

    // MARK: - SQLite helpers (queue only)

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            ClickLog.store.error("sqlite exec failed: \(message, privacy: .public)")
            sqlite3_free(error)
            return false
        }
        return true
    }

    private final class Statement {
        let handle: OpaquePointer
        init?(_ db: OpaquePointer, _ sql: String) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                ClickLog.store.error("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                return nil
            }
            handle = statement
        }
        deinit { sqlite3_finalize(handle) }

        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func bind(_ values: [Any?]) {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case let text as String: sqlite3_bind_text(handle, index, text, -1, Self.transient)
                case let int as Int64: sqlite3_bind_int64(handle, index, int)
                case let int as Int: sqlite3_bind_int64(handle, index, Int64(int))
                case let double as Double: sqlite3_bind_double(handle, index, double)
                case let data as Data:
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(data.count), Self.transient) }
                default: sqlite3_bind_null(handle, index)
                }
            }
        }

        @discardableResult
        func step() -> Bool { sqlite3_step(handle) == SQLITE_ROW }

        func run() { _ = sqlite3_step(handle) }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(handle, column).map { String(cString: $0) } ?? ""
        }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
        func data(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(handle, column))
            guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    private func transaction(_ body: () -> Void) {
        exec("BEGIN IMMEDIATE;")
        body()
        exec("COMMIT;")
    }

    // MARK: - Conversation keys

    /// Resolves an alias (connection ID, pre-canonical chat ID) to the stored conversation key.
    private func resolveLocked(_ key: String) -> String {
        guard let db, let statement = Statement(db, "SELECT conv FROM conv_alias WHERE alias = ?") else { return key }
        statement.bind([key])
        return statement.step() ? statement.text(0) : key
    }

    /// Records that `aliases` (e.g. the connection ID) name the conversation stored as `conv`.
    func link(aliases: [String], to conv: String, userID: String) {
        queue.async {
            guard self.ensureOpen(userID), let db = self.db,
                  let statement = Statement(db, "INSERT OR REPLACE INTO conv_alias (alias, conv) VALUES (?, ?)") else { return }
            for alias in aliases where !alias.isEmpty && alias != conv {
                statement.bind([alias, conv])
                statement.run()
            }
        }
    }

    // MARK: - Messages

    static func searchableText(_ item: ChatMessageItem) -> String {
        if item.isDeleted { return "" }
        if let beacon = item.beacon { return beacon.title }
        if let media = item.media { return media.kind == .file ? media.displayName : "" }
        return item.content
    }

    /// Inserts or replaces messages (server rows only; optimistic rows are never stored).
    func upsertMessages(_ items: [ChatMessageItem], conversation: String, userID: String) {
        let rows = items.filter { $0.deliveryStatus != .sending && $0.deliveryStatus != .failed }
        guard !rows.isEmpty, !conversation.isEmpty else { return }
        let encoded: [(ChatMessageItem, Data)] = rows.compactMap { item in
            (try? encoder.encode(item)).map { (item, $0) }
        }
        queue.async {
            guard self.ensureOpen(userID), let db = self.db else { return }
            let conv = self.resolveLocked(conversation)
            guard let upsert = Statement(db, "INSERT OR REPLACE INTO messages (conv, id, created_ms, sender, body, json) VALUES (?, ?, ?, ?, ?, ?)") else { return }
            let ftsDelete = self.hasFTS ? Statement(db, "DELETE FROM messages_fts WHERE conv = ? AND id = ?") : nil
            let ftsInsert = self.hasFTS ? Statement(db, "INSERT INTO messages_fts (body, sender, conv, id, created_ms) VALUES (?, ?, ?, ?, ?)") : nil
            self.transaction {
                for (item, json) in encoded {
                    let created = Int64(item.createdAt.timeIntervalSince1970 * 1000)
                    let body = Self.searchableText(item)
                    upsert.bind([conv, item.id, created, item.senderName, body, json])
                    upsert.run()
                    ftsDelete?.bind([conv, item.id])
                    ftsDelete?.run()
                    if !body.isEmpty {
                        ftsInsert?.bind([body, item.senderName, conv, item.id, created])
                        ftsInsert?.run()
                    }
                }
            }
        }
    }

    func removeMessage(id: String, conversation: String, userID: String) {
        queue.async {
            guard self.ensureOpen(userID), let db = self.db else { return }
            let conv = self.resolveLocked(conversation)
            if let statement = Statement(db, "DELETE FROM messages WHERE conv = ? AND id = ?") {
                statement.bind([conv, id]); statement.run()
            }
            if self.hasFTS, let statement = Statement(db, "DELETE FROM messages_fts WHERE conv = ? AND id = ?") {
                statement.bind([conv, id]); statement.run()
            }
        }
    }

    private func decodeMessages(_ statement: Statement) -> [ChatMessageItem] {
        var result: [ChatMessageItem] = []
        while statement.step() {
            if let item = try? decoder.decode(ChatMessageItem.self, from: statement.data(0)) {
                result.append(item)
            }
        }
        return result
    }

    /// The newest `limit` messages, oldest first. Synchronous: used for a chat's first frame.
    func latestMessages(conversation: String, userID: String, limit: Int) -> [ChatMessageItem] {
        queue.sync {
            guard ensureOpen(userID), let db,
                  let statement = Statement(db, "SELECT json FROM messages WHERE conv = ? ORDER BY created_ms DESC LIMIT ?") else { return [] }
            statement.bind([resolveLocked(conversation), limit])
            return decodeMessages(statement).reversed()
        }
    }

    /// Up to `limit` messages older than `before`, oldest first.
    func messages(conversation: String, userID: String, before: Date, limit: Int) async -> [ChatMessageItem] {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.ensureOpen(userID), let db = self.db,
                      let statement = Statement(db, "SELECT json FROM messages WHERE conv = ? AND created_ms < ? ORDER BY created_ms DESC LIMIT ?") else {
                    continuation.resume(returning: [])
                    return
                }
                statement.bind([self.resolveLocked(conversation), Int64(before.timeIntervalSince1970 * 1000), limit])
                continuation.resume(returning: self.decodeMessages(statement).reversed())
            }
        }
    }

    /// Stored messages by ID, in no particular order.
    func messages(ids: [String], conversation: String, userID: String) async -> [ChatMessageItem] {
        await withCheckedContinuation { continuation in
            queue.async {
                var result: [ChatMessageItem] = []
                defer { continuation.resume(returning: result) }
                guard self.ensureOpen(userID), let db = self.db,
                      let statement = Statement(db, "SELECT json FROM messages WHERE conv = ? AND id = ?") else { return }
                let conv = self.resolveLocked(conversation)
                for id in ids {
                    statement.bind([conv, id])
                    result += self.decodeMessages(statement)
                }
            }
        }
    }

    /// Inbox previews this device can show without keys: for each key, the plaintext of the
    /// conversation's stored message carrying `wire` (the server's ciphertext), among its newest.
    func plaintext(ofLatest wires: [String: (conversation: String, wire: String)], userID: String) async -> [String: String] {
        await withCheckedContinuation { continuation in
            queue.async {
                var result: [String: String] = [:]
                defer { continuation.resume(returning: result) }
                guard self.ensureOpen(userID), let db = self.db,
                      let statement = Statement(db, "SELECT json FROM messages WHERE conv = ? ORDER BY created_ms DESC LIMIT 5") else { return }
                for (key, source) in wires where !source.wire.isEmpty {
                    statement.bind([self.resolveLocked(source.conversation)])
                    if let match = self.decodeMessages(statement).first(where: { $0.rawContent == source.wire && !$0.isDeleted }) {
                        result[key] = match.content
                    }
                }
            }
        }
    }

    struct MessageHit: Sendable, Hashable {
        let conversation: String
        let messageID: String
        let senderName: String
        let snippet: String
        let createdAt: Date
    }

    /// Full-text search across every stored conversation (prefix match on each word).
    func searchMessages(_ query: String, userID: String, limit: Int = 40) async -> [MessageHit] {
        let words = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard self.ensureOpen(userID), let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                var hits: [MessageHit] = []
                if self.hasFTS, let statement = Statement(db, """
                    SELECT conv, id, sender, snippet(messages_fts, 0, '', '', '…', 12), created_ms
                    FROM messages_fts WHERE messages_fts MATCH ? ORDER BY created_ms DESC LIMIT ?
                    """) {
                    let match = words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
                    statement.bind([match, limit])
                    while statement.step() {
                        hits.append(MessageHit(conversation: statement.text(0), messageID: statement.text(1), senderName: statement.text(2),
                                               snippet: statement.text(3), createdAt: Date(timeIntervalSince1970: Double(statement.int64(4)) / 1000)))
                    }
                } else if let statement = Statement(db, "SELECT conv, id, sender, body, created_ms FROM messages WHERE body LIKE ? ORDER BY created_ms DESC LIMIT ?") {
                    statement.bind(["%\(query)%", limit])
                    while statement.step() {
                        hits.append(MessageHit(conversation: statement.text(0), messageID: statement.text(1), senderName: statement.text(2),
                                               snippet: String(statement.text(3).prefix(120)), createdAt: Date(timeIntervalSince1970: Double(statement.int64(4)) / 1000)))
                    }
                }
                continuation.resume(returning: hits)
            }
        }
    }

    // MARK: - Key/value (read models)

    func save<Value: Encodable>(_ value: Value, key: String, userID: String) {
        guard let data = try? encoder.encode(value) else { return }
        saveRaw(data, key: key, userID: userID)
    }

    func saveRaw(_ data: Data, key: String, userID: String) {
        let now = Date().timeIntervalSince1970
        queue.async {
            guard self.ensureOpen(userID), let db = self.db,
                  let statement = Statement(db, "INSERT OR REPLACE INTO kv (key, json, fetched_at) VALUES (?, ?, ?)") else { return }
            statement.bind([key, data, now])
            statement.run()
        }
    }

    /// The stored value and when it was saved. Synchronous (small reads for first paint).
    func load<Value: Decodable>(_ type: Value.Type, key: String, userID: String) -> (value: Value, savedAt: Date)? {
        let row: (Data, Double)? = queue.sync {
            guard ensureOpen(userID), let db,
                  let statement = Statement(db, "SELECT json, fetched_at FROM kv WHERE key = ?") else { return nil }
            statement.bind([key])
            return statement.step() ? (statement.data(0), statement.double(1)) : nil
        }
        guard let row, let value = try? decoder.decode(Value.self, from: row.0) else { return nil }
        return (value, Date(timeIntervalSince1970: row.1))
    }

    func remove(key: String, userID: String) {
        queue.async {
            guard self.ensureOpen(userID), let db = self.db,
                  let statement = Statement(db, "DELETE FROM kv WHERE key = ?") else { return }
            statement.bind([key])
            statement.run()
        }
    }

    /// Waits for queued writes (tests, sign-out ordering).
    func flush() {
        queue.sync {}
    }
}
