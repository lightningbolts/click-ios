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

    public init(
        id: String,
        chatID: String,
        senderID: String,
        content: String,
        messageType: String = "text",
        timeCreated: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        isRead: Bool = false,
        deliveredAt: Int64? = nil,
        metadata: [String: Any]? = nil
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
    }
}

/// Realtime coordinator for one active chat.
///
/// The manager keeps transport state independent from ConversationModel so a token/socket failure
/// never mutates the timeline itself. It understands both current Supabase postgres-change /
/// broadcast envelopes and the legacy INSERT/UPDATE event form during rollout.
@Observable
@MainActor
public final class ChatRealtimeManager {
    public private(set) var health: SubscriptionHealth = .idle
    public private(set) var typingUserIDs: Set<String> = []

    public var onMessageInserted: (@Sendable (RealtimeMessagePayload) -> Void)?
    public var onMessageUpdated: (@Sendable (RealtimeMessagePayload) -> Void)?
    public var onMessageDeleted: (@Sendable (String) -> Void)?
    public var onTypingChanged: (@Sendable (Set<String>) -> Void)?

    private struct ConnectionContext {
        let chatID: String
        let supabaseURL: URL
        let anonKey: String
        let authToken: String?
    }

    private var context: ConnectionContext?
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var typingDecayTimers: [String: Timer] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 5

    public init() {}

    public func subscribe(to chatID: String, supabaseURL: URL, anonKey: String, authToken: String?) {
        let next = ConnectionContext(
            chatID: chatID,
            supabaseURL: supabaseURL,
            anonKey: anonKey,
            authToken: authToken
        )
        if context?.chatID == chatID, health == .connected {
            return
        }
        context = next
        reconnectAttempt = 0
        connect(next, isReconnect: false)
    }

    public func teardown() {
        reconnectTask?.cancel()
        reconnectTask = nil
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
            "topic": topic(for: context.chatID),
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

    private func connect(_ context: ConnectionContext, isReconnect: Bool) {
        tearDownTransport(preserveTyping: isReconnect)
        health = isReconnect ? .reconnecting : .connecting

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

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: wsURL)
        urlSession = session
        webSocketTask = task
        task.resume()

        listen(task: task)
        joinChannel(context: context, task: task)
        startHeartbeat()
    }

    private func joinChannel(context: ConnectionContext, task: URLSessionWebSocketTask) {
        var payload: [String: Any] = [
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["key": ""],
                "postgres_changes": [
                    [
                        "event": "*",
                        "schema": "public",
                        "table": "messages",
                        "filter": "chat_id=eq.\(context.chatID)"
                    ]
                ]
            ]
        ]
        if let token = context.authToken, !token.isEmpty {
            payload["access_token"] = token
        }

        let join: [String: Any] = [
            "topic": topic(for: context.chatID),
            "event": "phx_join",
            "payload": payload,
            "ref": "join-\(UUID().uuidString)"
        ]
        sendJSON(join, task: task)
    }

    private func topic(for chatID: String) -> String {
        "realtime:chat:\(chatID)"
    }

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

        switch event {
        case "phx_reply":
            guard let payload = json["payload"] as? [String: Any],
                  let status = payload["status"] as? String else { return }
            if status == "ok" {
                health = .connected
                reconnectAttempt = 0
            } else {
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
            handleDatabaseChange(type: changeType, record: record, oldRecord: oldRecord)

        case "INSERT", "UPDATE", "DELETE":
            guard let payload = json["payload"] as? [String: Any] else { return }
            let record = (payload["record"] as? [String: Any]) ?? [:]
            let oldRecord = (payload["old_record"] as? [String: Any]) ?? [:]
            handleDatabaseChange(type: event, record: record, oldRecord: oldRecord)

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
        record: [String: Any],
        oldRecord: [String: Any]
    ) {
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

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self,
                  let task = self.webSocketTask,
                  self.health == .connected else { return }
            self.sendJSON(
                [
                    "topic": "phoenix",
                    "event": "heartbeat",
                    "payload": [:],
                    "ref": UUID().uuidString
                ],
                task: task
            )
        }
    }

    private func handleDisconnection() {
        guard context != nil, health != .idle else { return }
        tearDownTransport(preserveTyping: true)

        guard reconnectAttempt < maxReconnectAttempts else {
            health = .failed
            return
        }

        reconnectAttempt += 1
        health = .reconnecting
        let delaySeconds = Double(min(1 << reconnectAttempt, 12))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let context = self.context, self.health == .reconnecting else { return }
                self.connect(context, isReconnect: true)
            }
        }
    }

    private func tearDownTransport(preserveTyping: Bool = false) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

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
        RealtimeMessagePayload(
            id: record["id"] as? String ?? UUID().uuidString,
            chatID: record["chat_id"] as? String ?? context?.chatID ?? "",
            senderID: record["user_id"] as? String ?? "",
            content: record["content"] as? String ?? "",
            messageType: record["message_type"] as? String ?? "text",
            timeCreated: Self.int64(record["time_created"]) ?? Int64(Date().timeIntervalSince1970 * 1000),
            isRead: record["is_read"] as? Bool ?? false,
            deliveredAt: Self.int64(record["delivered_at"]),
            metadata: record["metadata"] as? [String: Any]
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
