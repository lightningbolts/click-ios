import Foundation
import Observation

public enum SubscriptionHealth: String, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed
}

public struct RealtimeMessagePayload: @unchecked Sendable {
    public let id: String
    public let chatID: String
    public let senderID: String
    public let content: String
    public let messageType: String
    public let timeCreated: Int64
    public let isRead: Bool
    public let deliveredAt: Int64?
    public let metadata: [String: Any]?
    public let isEdited: Bool

    public init(
        id: String,
        chatID: String,
        senderID: String,
        content: String,
        messageType: String = "text",
        timeCreated: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        isRead: Bool = false,
        deliveredAt: Int64? = nil,
        metadata: [String: Any]? = nil,
        isEdited: Bool = false
    ) {
        self.id = id
        self.chatID = chatID
        self.senderID = senderID
        self.content = content
        self.messageType = messageType
        self.timeCreated = timeCreated
        self.isRead = isRead
        self.deliveredAt = deliveredAt
        self.metadata = metadata
        self.isEdited = isEdited
    }
}

/// Which table a conversation's changes stream from.
public enum RealtimeStream: Sendable {
    /// `messages` filtered by `chat_id` (direct chats).
    case chat
    /// `messages` plus members' `chat_read_cursors` for one group chat (read receipts).
    case groupChat
    /// `hub_messages` filtered by `hub_id`.
    case hub
    /// Every `messages` row the viewer can read (RLS-scoped); drives inbox freshness.
    case inbox
    /// `group_members` changes the viewer can see (joins, leaves, removals), RLS-scoped.
    case groupMembers
}

/// Realtime coordinator for one channel (a chat, a hub, the inbox, or group membership).
///
/// The manager keeps transport state independent from ConversationModel so a token/socket failure
/// never mutates the timeline itself. It understands both current Supabase postgres-change /
/// broadcast envelopes and the legacy INSERT/UPDATE event form during rollout.
///
/// Staying live for hours (the "conversations need reloading" bug) needs all of:
/// - a fresh JWT on every (re)join, from `tokenProvider`, never one captured at subscribe time;
/// - pushing refreshed tokens to joined channels (`access_token`), before the old one expires;
/// - treating `phx_close` / `phx_error` / `system` errors on our topic as a disconnect;
/// - heartbeat acknowledgements: an unanswered heartbeat means a half-open socket;
/// - reconnecting forever with capped backoff, and immediately when the network path changes.
@Observable
@MainActor
public final class ChatRealtimeManager {
    public private(set) var health: SubscriptionHealth = .idle
    public private(set) var typingUserIDs: Set<String> = []

    public var onMessageInserted: (@Sendable (RealtimeMessagePayload) -> Void)?
    public var onMessageUpdated: (@Sendable (RealtimeMessagePayload) -> Void)?
    public var onMessageDeleted: (@Sendable (String) -> Void)?
    /// A member's read cursor moved (`groupChat`): user ID and read-through time.
    public var onReadCursor: (@Sendable (String, Date) -> Void)?
    /// A message was pinned or unpinned (`chat`, `groupChat`).
    public var onPinsChanged: (@Sendable () -> Void)?
    public var onTypingChanged: (@Sendable (Set<String>) -> Void)?
    /// Any row change on a non-message stream (`groupMembers`).
    public var onRowChanged: (@Sendable () -> Void)?
    /// Called after a reconnect re-joins the channel: events may have been missed while the
    /// socket was down, so owners run a delta sync.
    public var onRejoined: (@MainActor () -> Void)?

    /// Supplies a valid (refreshed when near expiry) access token for each join. Set once by
    /// `AppEnvironment`; falls back to the token passed to `subscribe`.
    public static var tokenProvider: (@MainActor () async -> String?)?

    private struct ConnectionContext {
        let chatID: String
        let stream: RealtimeStream
        let supabaseURL: URL
        let anonKey: String
        var authToken: String?
    }

    private var context: ConnectionContext?
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var typingDecayTimers: [String: Timer] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var joinRef: String?
    private var pendingHeartbeatRef: String?
    private var hasJoinedOnce = false

    nonisolated static let heartbeatInterval: Duration = .seconds(25)

    public init() {
        Self.registry.add(self)
        NetworkPathObserver.shared.start()
    }

    // MARK: Shared token + network fan-out

    private final class WeakBox { weak var value: ChatRealtimeManager?; init(_ v: ChatRealtimeManager) { value = v } }
    private final class Registry {
        private var boxes: [WeakBox] = []
        func add(_ manager: ChatRealtimeManager) {
            boxes.removeAll { $0.value == nil }
            boxes.append(WeakBox(manager))
        }
        var live: [ChatRealtimeManager] { boxes.compactMap(\.value) }
    }
    private static let registry = Registry()

    /// The session refreshed its JWT: tell every joined channel before the old one expires.
    public static func accessTokenDidChange(_ token: String) {
        for manager in registry.live { manager.pushAccessToken(token) }
    }

    /// The device regained (or switched) network: sockets opened on the old path are dead.
    static func networkPathDidChange() {
        for manager in registry.live where manager.context != nil {
            manager.reconnectNow()
        }
    }

    // MARK: Public API

    public func subscribe(to chatID: String, stream: RealtimeStream = .chat, supabaseURL: URL, anonKey: String, authToken: String?) {
        if context?.chatID == chatID, context?.stream == stream, health == .connected || health == .connecting {
            return
        }
        let next = ConnectionContext(
            chatID: chatID,
            stream: stream,
            supabaseURL: supabaseURL,
            anonKey: anonKey,
            authToken: authToken
        )
        context = next
        reconnectAttempt = 0
        hasJoinedOnce = false
        connect(isReconnect: false)
    }

    /// Foreground return: sockets may have been silently dropped while suspended. Rejoins
    /// unless a heartbeat was acknowledged very recently.
    public func ensureLive() {
        guard context != nil else { return }
        if health == .connected, pendingHeartbeatRef == nil, let last = lastAckAt, Date().timeIntervalSince(last) < 30 {
            return
        }
        reconnectNow()
    }

    public func teardown() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        context = nil
        tearDownTransport()
        reconnectAttempt = 0
        health = .idle
    }

    public func sendTyping(isTyping: Bool, userID: String) {
        guard let task = webSocketTask,
              health == .connected,
              let context else { return }

        let message: [String: Any] = [
            "topic": topic(for: context),
            "event": "broadcast",
            "payload": [
                "type": "broadcast",
                "event": "typing",
                "payload": [
                    "user_id": userID,
                    "is_typing": isTyping
                ]
            ],
            "ref": UUID().uuidString
        ]
        sendJSON(message, task: task)
    }

    // MARK: Transport

    private var lastAckAt: Date?

    private func reconnectNow() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        connect(isReconnect: true)
    }

    private func connect(isReconnect: Bool) {
        tearDownTransport(preserveTyping: isReconnect)
        health = isReconnect ? .reconnecting : .connecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            // Always join with a fresh token: a captured one may expire minutes later, and
            // Supabase then closes the channel while heartbeats keep succeeding.
            let token = await Self.tokenProvider?()
            guard let self, !Task.isCancelled, var context = self.context else { return }
            if let token, !token.isEmpty { context.authToken = token; self.context = context }
            self.openSocket(context)
        }
    }

    private func openSocket(_ context: ConnectionContext) {
        guard var components = URLComponents(url: context.supabaseURL, resolvingAgainstBaseURL: true) else {
            health = .failed
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: context.anonKey),
            URLQueryItem(name: "vsn", value: "1.0.0")
        ]
        guard let wsURL = components.url else {
            health = .failed
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: wsURL)
        urlSession = session
        webSocketTask = task
        task.resume()

        listen(task: task)
        joinChannel(context: context, task: task)
        startHeartbeat(task: task)
    }

    private func joinChannel(context: ConnectionContext, task: URLSessionWebSocketTask) {
        var payload: [String: Any] = [
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["key": ""],
                "postgres_changes": changeFilters(for: context)
            ]
        ]
        if let token = context.authToken, !token.isEmpty {
            payload["access_token"] = token
        }
        let ref = "join-\(UUID().uuidString)"
        joinRef = ref
        let join: [String: Any] = [
            "topic": topic(for: context),
            "event": "phx_join",
            "payload": payload,
            "ref": ref,
            "join_ref": ref
        ]
        sendJSON(join, task: task)
    }

    private func pushAccessToken(_ token: String) {
        guard var context else { return }
        context.authToken = token
        self.context = context
        guard let task = webSocketTask, health == .connected else { return }
        sendJSON([
            "topic": topic(for: context),
            "event": "access_token",
            "payload": ["access_token": token],
            "ref": UUID().uuidString,
            "join_ref": joinRef ?? ""
        ], task: task)
    }

    private func topic(for context: ConnectionContext) -> String {
        switch context.stream {
        case .chat, .groupChat: "realtime:chat:\(context.chatID)"
        case .hub: "realtime:hub:\(context.chatID)"
        case .inbox: "realtime:inbox:\(context.chatID)"
        case .groupMembers: "realtime:group-members:\(context.chatID)"
        }
    }

    private func changeFilters(for context: ConnectionContext) -> [[String: Any]] {
        let messages: [String: Any] = ["event": "*", "schema": "public", "table": "messages", "filter": "chat_id=eq.\(context.chatID)"]
        let pins: [String: Any] = ["event": "*", "schema": "public", "table": Self.pinsTable, "filter": "chat_id=eq.\(context.chatID)"]
        return switch context.stream {
        case .chat:
            [messages, pins]
        case .groupChat:
            [messages, pins, ["event": "*", "schema": "public", "table": Self.readCursorsTable, "filter": "chat_id=eq.\(context.chatID)"]]
        case .hub:
            [["event": "*", "schema": "public", "table": "hub_messages", "filter": "hub_id=eq.\(context.chatID)"]]
        case .inbox:
            [["event": "INSERT", "schema": "public", "table": "messages"]]
        case .groupMembers:
            [["event": "*", "schema": "public", "table": "group_members"]]
        }
    }

    private static let readCursorsTable = "chat_read_cursors"
    private static let pinsTable = "message_pins"

    private func listen(task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            Task { @MainActor in
                guard self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    if self.webSocketTask === task {
                        self.listen(task: task)
                    }
                case .failure:
                    self.handleDisconnection()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else { return }
            text = value
        @unknown default:
            return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return }

        let ref = json["ref"] as? String
        let messageTopic = json["topic"] as? String
        let ourTopic = context.map(topic(for:))

        switch event {
        case "phx_reply":
            guard let payload = json["payload"] as? [String: Any],
                  let status = payload["status"] as? String else { return }
            if let ref, ref == pendingHeartbeatRef {
                pendingHeartbeatRef = nil
                lastAckAt = .now
                return
            }
            guard ref == nil || ref == joinRef else { return }
            if status == "ok" {
                let isRejoin = hasJoinedOnce
                health = .connected
                reconnectAttempt = 0
                lastAckAt = .now
                hasJoinedOnce = true
                // Anything sent while we were disconnected must be fetched.
                if isRejoin { onRejoined?() }
            } else {
                handleDisconnection()
            }

        case "phx_close", "phx_error":
            // The server closed our channel (commonly: the JWT expired). Heartbeats on the
            // socket would keep succeeding, so this must be treated as a disconnect.
            if messageTopic == ourTopic { handleDisconnection() }

        case "system":
            if messageTopic == ourTopic,
               let payload = json["payload"] as? [String: Any],
               (payload["status"] as? String) == "error" {
                handleDisconnection()
            }

        case "postgres_changes":
            guard let payload = json["payload"] as? [String: Any] else { return }
            let dataPayload = (payload["data"] as? [String: Any]) ?? payload
            let changeType = (
                dataPayload["type"] as? String ??
                dataPayload["eventType"] as? String ??
                dataPayload["event"] as? String ??
                ""
            ).uppercased()
            let record = (dataPayload["record"] as? [String: Any]) ?? [:]
            let oldRecord = (dataPayload["old_record"] as? [String: Any]) ?? [:]
            handleDatabaseChange(type: changeType, table: dataPayload["table"] as? String, record: record, oldRecord: oldRecord)

        case "INSERT", "UPDATE", "DELETE":
            guard let payload = json["payload"] as? [String: Any] else { return }
            let record = (payload["record"] as? [String: Any]) ?? [:]
            let oldRecord = (payload["old_record"] as? [String: Any]) ?? [:]
            handleDatabaseChange(type: event, table: payload["table"] as? String, record: record, oldRecord: oldRecord)

        case "broadcast":
            guard let outer = json["payload"] as? [String: Any] else { return }
            let broadcastEvent = outer["event"] as? String
            let inner = (outer["payload"] as? [String: Any]) ?? outer
            if broadcastEvent == "typing" || inner["event"] as? String == "typing" {
                let payload = (inner["payload"] as? [String: Any]) ?? inner
                handleTypingPayload(payload)
            }

        case "typing_start", "typing_stop":
            guard let payload = json["payload"] as? [String: Any],
                  let userID = payload["user_id"] as? String else { return }
            if event == "typing_start" {
                registerTyping(userID: userID)
            } else {
                clearTyping(userID: userID)
            }

        default:
            break
        }
    }

    private func handleDatabaseChange(
        type: String,
        table: String?,
        record: [String: Any],
        oldRecord: [String: Any]
    ) {
        if context?.stream == .groupMembers {
            onRowChanged?()
            return
        }
        if table == Self.pinsTable {
            onPinsChanged?()
            return
        }
        if table == Self.readCursorsTable {
            if let userID = record["user_id"] as? String, let readThrough = Self.int64(record["read_through"]) {
                onReadCursor?(userID, Date(timeIntervalSince1970: Double(readThrough) / 1000))
            }
            return
        }
        switch type {
        case "INSERT":
            onMessageInserted?(parseRecord(record))
        case "UPDATE":
            onMessageUpdated?(parseRecord(record))
        case "DELETE":
            let id = (oldRecord["id"] as? String) ?? (record["id"] as? String)
            if let id { onMessageDeleted?(id) }
        default:
            break
        }
    }

    private func handleTypingPayload(_ payload: [String: Any]) {
        guard let userID = payload["user_id"] as? String else { return }
        let isTyping = (payload["is_typing"] as? Bool) ?? true
        if isTyping {
            registerTyping(userID: userID)
        } else {
            clearTyping(userID: userID)
        }
    }

    private func registerTyping(userID: String) {
        typingUserIDs.insert(userID)
        onTypingChanged?(typingUserIDs)

        typingDecayTimers[userID]?.invalidate()
        typingDecayTimers[userID] = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.clearTyping(userID: userID)
            }
        }
    }

    private func clearTyping(userID: String) {
        typingUserIDs.remove(userID)
        typingDecayTimers[userID]?.invalidate()
        typingDecayTimers.removeValue(forKey: userID)
        onTypingChanged?(typingUserIDs)
    }

    /// Heartbeats run on a task (a `Timer` stalls while a list is being scrolled). If the
    /// previous heartbeat was never acknowledged, the socket is half-open: reconnect.
    private func startHeartbeat(task: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        pendingHeartbeatRef = nil
        heartbeatTask = Task { [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self, let task, self.webSocketTask === task else { return }
                if self.pendingHeartbeatRef != nil {
                    self.handleDisconnection()
                    return
                }
                let ref = "hb-\(UUID().uuidString)"
                self.pendingHeartbeatRef = ref
                self.sendJSON(["topic": "phoenix", "event": "heartbeat", "payload": [:], "ref": ref], task: task)
            }
        }
    }

    /// Reconnects forever (KMP `RealtimeCoordinator`): 0.5 s × attempt, capped at 30 s.
    private func handleDisconnection() {
        guard context != nil, health != .idle else { return }
        tearDownTransport(preserveTyping: true)

        reconnectAttempt += 1
        health = .reconnecting
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.context != nil, self.health == .reconnecting else { return }
            self.connect(isReconnect: true)
        }
    }

    nonisolated static func reconnectDelay(attempt: Int) -> Double {
        min(30, 0.5 * Double(max(1, attempt)))
    }

    private func tearDownTransport(preserveTyping: Bool = false) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingHeartbeatRef = nil
        joinRef = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        if !preserveTyping {
            for timer in typingDecayTimers.values {
                timer.invalidate()
            }
            typingDecayTimers.removeAll()
            typingUserIDs.removeAll()
            onTypingChanged?(typingUserIDs)
        }
    }

    private func sendJSON(_ object: [String: Any], task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.handleDisconnection()
            }
        }
    }

    private func parseRecord(_ record: [String: Any]) -> RealtimeMessagePayload {
        if context?.stream == .hub {
            let created = JSONFields.date(record["created_at"]) ?? .now
            return RealtimeMessagePayload(
                id: record["id"] as? String ?? UUID().uuidString,
                chatID: record["hub_id"] as? String ?? context?.chatID ?? "",
                senderID: record["user_id"] as? String ?? "",
                content: record["body"] as? String ?? "",
                messageType: record["message_type"] as? String ?? "text",
                timeCreated: Int64(created.timeIntervalSince1970 * 1000),
                metadata: JSONFields.dictionary(record["metadata"]),
                isEdited: JSONFields.string(record["edited_at"]) != nil
            )
        }
        return RealtimeMessagePayload(
            id: record["id"] as? String ?? UUID().uuidString,
            chatID: record["chat_id"] as? String ?? context?.chatID ?? "",
            senderID: record["user_id"] as? String ?? "",
            content: record["content"] as? String ?? "",
            messageType: record["message_type"] as? String ?? "text",
            timeCreated: Self.int64(record["time_created"]) ?? Int64(Date().timeIntervalSince1970 * 1000),
            isRead: record["is_read"] as? Bool ?? false,
            deliveredAt: Self.int64(record["delivered_at"]),
            metadata: JSONFields.dictionary(record["metadata"])
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}
