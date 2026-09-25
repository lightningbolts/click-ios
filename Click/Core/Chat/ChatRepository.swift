import Foundation
import CryptoKit

/// Conversation operations for every supported kind (direct, verified group, community hub).
///
/// The protocol intentionally owns wire/encryption concerns. Presentation models never decide
/// whether plaintext, v1, or v2 should be written.
public protocol ChatRepositoryProtocol: Sendable {
    func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String

    func fetchMessages(
        conversation: ConversationIdentity,
        currentUserID: String,
        cursor: Int64?,
        limit: Int
    ) async throws -> [ChatMessageItem]

    func sendMessage(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        content: String,
        replyToID: String?,
        replyToSnippet: String?,
        replyToSenderName: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem

    func editMessage(
        message: ChatMessageItem,
        conversation: ConversationIdentity,
        currentUserID: String,
        newContent: String
    ) async throws

    func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws

    /// A window centred on one message (search deep links): the target, up to `limit` older and
    /// up to 40 newer rows, newest first.
    func fetchMessages(around messageID: String, conversation: ConversationIdentity, currentUserID: String, limit: Int) async throws -> [ChatMessageItem]
    func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws
    func markRead(chatID: String, messageIDs: [String]) async throws
    func markDelivered(chatID: String, messageIDs: [String]) async throws
    func registerDevice() async throws

    func decodeRealtimeMessage(
        _ payload: RealtimeMessagePayload,
        conversation: ConversationIdentity,
        currentUserID: String
    ) async throws -> ChatMessageItem

    /// Encrypts, uploads, and sends an image, voice note, or file (spec §37.2).
    func sendMedia(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        draft: MediaDraft,
        replyToID: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem

    /// Same as `sendMedia`, reporting encrypting/uploading progress.
    func sendMedia(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        draft: MediaDraft,
        replyToID: String?,
        clientMessageID: String,
        progress: (@Sendable (MediaUploadProgress) -> Void)?
    ) async throws -> ChatMessageItem

    /// Shares an event/beacon card (plaintext card fields only; the server allows it in v2 chats).
    func sendBeacon(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, beacon: MapBeacon, clientMessageID: String) async throws -> ChatMessageItem

    /// Returns a decrypted local file for a media message, downloading at most once (spec §37.3).
    func loadMedia(for message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String) async throws -> URL
}

public extension ChatRepositoryProtocol {
    func fetchMessages(around messageID: String, conversation: ConversationIdentity, currentUserID: String, limit: Int) async throws -> [ChatMessageItem] {
        []
    }

    func sendMedia(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        draft: MediaDraft,
        replyToID: String?,
        clientMessageID: String,
        progress: (@Sendable (MediaUploadProgress) -> Void)?
    ) async throws -> ChatMessageItem {
        try await sendMedia(conversation: conversation, currentUserID: currentUserID, currentUserName: currentUserName,
                            draft: draft, replyToID: replyToID, clientMessageID: clientMessageID)
    }

    func sendMedia(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        draft: MediaDraft,
        replyToID: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem {
        throw ChatRepositoryError.mediaUnsupported
    }

    func loadMedia(for message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String) async throws -> URL {
        throw ChatRepositoryError.mediaUnsupported
    }

    func sendBeacon(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, beacon: MapBeacon, clientMessageID: String) async throws -> ChatMessageItem {
        throw ChatRepositoryError.mediaUnsupported
    }
}

/// Hub access failures surfaced with their real reason (spec §62), never as "expired".
public enum HubChatError: Error, LocalizedError, Equatable, Sendable {
    case outOfRange
    case locationRequired
    case accessDenied
    case ended

    public var errorDescription: String? {
        switch self {
        case .outOfRange: "You're no longer near this hub. Move closer to post."
        case .locationRequired: "Turn on location to post in this hub."
        case .accessDenied: "Join this hub (or RSVP to its event) to see the conversation."
        case .ended: "This chat has ended."
        }
    }

    static func map(_ error: Error) -> Error {
        switch error as? APIError {
        case .validation(_, let message?) where message.contains("OUT_OF_BOUNDS"): HubChatError.outOfRange
        case .validation(_, let message?) where message.contains("user_lat"): HubChatError.locationRequired
        case .forbidden: HubChatError.accessDenied
        case .server(410, _, _): HubChatError.ended
        default: error
        }
    }
}

public enum ChatRepositoryError: Error, LocalizedError, Sendable {
    case missingConversationIdentity
    case unresolvedChat
    case encryptionUnavailable
    case currentDeviceNotRegistered
    case currentEpochUnavailable
    case currentEpochKeyUnavailable
    case invalidServerPayload
    case mediaUnsupported
    case mediaTooLarge
    case mediaTypeNotAllowed
    case mediaUnavailable

    public var errorDescription: String? {
        switch self {
        case .mediaUnsupported:
            return "Media in hub chats isn't available on iOS yet."
        case .mediaTooLarge:
            return "This file is too large to send."
        case .mediaTypeNotAllowed:
            return "This type of file can't be sent in chat."
        case .mediaUnavailable:
            return "This media couldn't be opened on this device."
        case .missingConversationIdentity:
            return "This conversation is missing the identity required for secure messaging."
        case .unresolvedChat:
            return "The conversation could not be resolved."
        case .encryptionUnavailable:
            return "Secure messaging is not available for this conversation right now."
        case .currentDeviceNotRegistered:
            return "This device is not registered for secure messaging."
        case .currentEpochUnavailable:
            return "The secure conversation key is not initialized."
        case .currentEpochKeyUnavailable:
            return "This device does not have the current secure conversation key."
        case .invalidServerPayload:
            return "The chat service returned an invalid response."
        }
    }
}

/// Authoritative repository for conversation transport and the E2EE v1/v2 lifecycle across
/// direct chats, verified groups, and community/event hubs.
///
/// Invariants:
/// - direct and group text is never silently downgraded to plaintext; if neither current v2 nor
///   legacy v1 can securely write, the operation fails closed;
/// - an upgraded (v2) conversation never accepts a legacy write;
/// - non-upgraded hubs post plaintext exactly like the KMP client (the legacy hub key is derived
///   from the public hub ID and is not a security boundary), and upgraded hubs post v2 only.
public actor ChatRepository: ChatRepositoryProtocol {
    public typealias Coordinates = @Sendable () async -> (latitude: Double, longitude: Double)?

    private let apiClient: ClickAPIClient
    private let vault: DeviceIdentityVault
    private let supabaseURL: URL?
    private let supabaseAnonKey: String
    private let hubCoordinates: Coordinates?
    private let messageReplayGuard = ClickCryptoV2.ReplayGuard()
    private let wrapReplayGuard = ClickCryptoV2.ReplayGuard()

    private var v1KeyCache: [String: ClickCryptoV1.DerivedKeys] = [:]
    private var groupMasterCache: [String: Data] = [:]
    private var v2SessionCache: [String: V2Session] = [:]
    private var hubParticipants: [String: [String]] = [:]
    /// Actor-local mirror of `identities` so synchronous mapping can read resolved names.
    private var senderNames: [String: (name: String, avatarURL: String?)] = [:]
    private let identities: IdentityCache
    /// Device registration is idempotent; once per app session is enough.
    private var deviceRegistered = false

    public init(
        apiClient: ClickAPIClient,
        vault: DeviceIdentityVault = .shared,
        supabaseURL: URL? = nil,
        supabaseAnonKey: String = "",
        identities: IdentityCache? = nil,
        hubCoordinates: Coordinates? = nil
    ) {
        self.apiClient = apiClient
        self.identities = identities ?? IdentityCache(api: apiClient)
        self.vault = vault
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.hubCoordinates = hubCoordinates
    }

    // MARK: - Canonical conversation identity

    public func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String {
        let proposed = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = connectionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Once a canonical chat UUID differs from the connection ID, do not perform another
        // resolution request during pagination/send/retry.
        if !proposed.isEmpty, connection.isEmpty || proposed != connection {
            return proposed
        }

        guard !connection.isEmpty else {
            guard !proposed.isEmpty else { throw ChatRepositoryError.unresolvedChat }
            return proposed
        }

        let request = APIRequest(
            path: "/api/connections/\(connection)/tabs",
            method: .get,
            queryItems: [URLQueryItem(name: "limit", value: "1")],
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)
        let decoded = try JSONDecoder().decode(ChatResolutionResponse.self, from: data)
        let resolved = decoded.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { throw ChatRepositoryError.unresolvedChat }
        return resolved
    }

    private func canonicalChatID(_ conversation: ConversationIdentity) async throws -> String {
        if let hubID = conversation.hubID { return hubID }
        return try await resolveCanonicalChatID(chatID: conversation.chatID, connectionID: conversation.connectionID)
    }

    // MARK: - Device registration / E2EE v2 session lifecycle

    public func registerDevice() async throws {
        guard !deviceRegistered else { return }
        let identity = try vault.loadOrCreate()
        let body = try JSONSerialization.data(
            withJSONObject: [
                "device_id": identity.info.deviceID,
                "identity_public_key": identity.info.publicKeySpkiBase64
            ],
            options: []
        )
        let request = APIRequest(
            path: "/api/chat/devices",
            method: .post,
            body: body,
            requiresAuth: true
        )

        do {
            _ = try await apiClient.executeRaw(request)
        } catch APIError.conflict(_) {
            // Registration is idempotent from the client's perspective.
        }
        deviceRegistered = true
    }

    /// Where a v2 epoch lives: chat routes (direct + group) or hub routes. Hub envelopes bind to
    /// the hub ID in place of a chat ID.
    private enum V2Scope: Sendable {
        case chat(String)
        case hub(String)

        var id: String {
            switch self {
            case .chat(let id), .hub(let id): id
            }
        }

        var cacheKey: String {
            switch self {
            case .chat(let id): id
            case .hub(let id): "hub:\(id)"
            }
        }

        var root: String {
            switch self {
            case .chat: "/api/chat"
            case .hub: "/api/hub"
            }
        }

        var idField: String {
            switch self {
            case .chat: "chat_id"
            case .hub: "hub_id"
            }
        }

        var isHub: Bool {
            if case .hub = self { return true }
            return false
        }
    }

    private func resolveV2Session(
        scope: V2Scope,
        participantUserIDs: [String],
        allowUpgrade: Bool,
        didRetryDiscovery: Bool = false
    ) async throws -> V2Session? {
        if !allowUpgrade, let cached = v2SessionCache[scope.cacheKey] {
            return cached
        }

        let identity = try vault.loadOrCreate()
        try await registerDevice()

        let devices = try await discoverDevices(scope)
        guard let ownDevice = devices.first(where: { $0.deviceID == identity.info.deviceID }) else {
            // Registration and discovery are separate authenticated requests. Refresh once in case
            // the just-created row was not visible to the first read.
            guard !didRetryDiscovery else { throw ChatRepositoryError.currentDeviceNotRegistered }
            return try await resolveV2Session(
                scope: scope,
                participantUserIDs: participantUserIDs,
                allowUpgrade: allowUpgrade,
                didRetryDiscovery: true
            )
        }

        var state = try await fetchEpochState(scope, deviceID: identity.info.deviceID)
        let participants = Set(
            participantUserIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let deviceUsers = Set(devices.compactMap(\.userID))
        let allParticipantsHaveV2Devices = !participants.isEmpty && participants.isSubset(of: deviceUsers)

        if state.currentEpoch == nil {
            guard allowUpgrade, allParticipantsHaveV2Devices else { return nil }
            do {
                try await createEpoch(scope, identity: identity, devices: devices, epoch: 1)
            } catch APIError.conflict(_) {
                // Another active device may have created epoch 1 concurrently.
            }
            state = try await fetchEpochState(scope, deviceID: identity.info.deviceID)
        } else if allowUpgrade {
            // Hub participant lists can be intentionally hidden (hosts-only guest lists); the
            // server RPC verifies every participant has a device, exactly as in KMP.
            if !scope.isHub, !allParticipantsHaveV2Devices {
                // An already-upgraded conversation must never downgrade to v1 merely because an
                // active participant temporarily has no usable v2 device.
                throw ChatRepositoryError.encryptionUnavailable
            }

            let fingerprint = membershipFingerprint(devices)
            // Hubs rotate on any fingerprint difference (KMP); chats only when one is recorded.
            let mismatch = scope.isHub
                ? state.membershipFingerprint != fingerprint
                : state.membershipFingerprint.map { $0 != fingerprint } ?? false
            if let currentEpoch = state.currentEpoch, mismatch {
                do {
                    try await createEpoch(scope, identity: identity, devices: devices, epoch: currentEpoch + 1)
                } catch APIError.conflict(_) {
                    // A peer device can rotate first; fresh state below is authoritative.
                }
                state = try await fetchEpochState(scope, deviceID: identity.info.deviceID)
            }
        }

        guard let currentEpoch = state.currentEpoch else {
            throw ChatRepositoryError.currentEpochUnavailable
        }

        var epochKeys: [Int: Data] = [:]
        let ownIDs: Set<String> = [identity.info.deviceID, ownDevice.id]
        for row in state.envelopes where ownIDs.contains(row.recipientDeviceID) {
            do {
                let key = try ClickCryptoV2.unwrapEpochKey(
                    metadata: .init(
                        chatId: scope.id,
                        epoch: row.epoch,
                        senderDeviceId: row.senderDeviceID,
                        recipientDeviceId: identity.info.deviceID
                    ),
                    recipientPrivateKey: identity.privateKey,
                    envelope: row.envelope,
                    replayGuard: wrapReplayGuard
                )
                epochKeys[row.epoch] = key
            } catch {
                if row.epoch == currentEpoch {
                    throw ChatRepositoryError.currentEpochKeyUnavailable
                }
            }
        }

        guard epochKeys[currentEpoch] != nil else {
            throw ChatRepositoryError.currentEpochKeyUnavailable
        }

        let session = V2Session(
            deviceID: ownDevice.deviceID,
            currentEpoch: currentEpoch,
            epochKeys: epochKeys
        )
        v2SessionCache[scope.cacheKey] = session
        return session
    }

    /// Result of reconciling a chat's E2EE v2 epoch after a membership change (spec §30, §48).
    public enum EpochReconciliation: Equatable, Sendable {
        /// The chat has a current epoch wrapped for exactly the current members' devices.
        case current(epoch: Int)
        /// The chat has not been upgraded to v2 (legacy group keys are wrapped server-side).
        case notUpgraded
    }

    /// Re-reads membership devices and rotates the epoch when the device set changed, so a
    /// removed member's devices cannot read new messages and added members can. Throws when the
    /// new epoch could not be established — callers must not report the change as complete.
    public func reconcileMembershipEpoch(chatID: String, participantUserIDs: [String]) async throws -> EpochReconciliation {
        v2SessionCache[chatID] = nil
        guard let session = try await resolveV2Session(
            scope: .chat(chatID),
            participantUserIDs: participantUserIDs,
            allowUpgrade: true
        ) else {
            return .notUpgraded
        }
        return .current(epoch: session.currentEpoch)
    }

    private func discoverDevices(_ scope: V2Scope) async throws -> [DeviceRow] {
        let request = APIRequest(
            path: "\(scope.root)/devices",
            method: .get,
            queryItems: [URLQueryItem(name: scope.idField, value: scope.id)],
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)
        return try JSONDecoder().decode(DeviceResponse.self, from: data).devices
            .filter { $0.keyAlgorithm == "X25519" && $0.cryptoVersion == 2 }
    }

    private func fetchEpochState(_ scope: V2Scope, deviceID: String) async throws -> EpochState {
        let request = APIRequest(
            path: "\(scope.root)/epochs",
            method: .get,
            queryItems: [
                URLQueryItem(name: scope.idField, value: scope.id),
                URLQueryItem(name: "device_id", value: deviceID)
            ],
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)
        return try JSONDecoder().decode(EpochState.self, from: data)
    }

    private func createEpoch(
        _ scope: V2Scope,
        identity: DeviceIdentityVault.DeviceIdentity,
        devices: [DeviceRow],
        epoch: Int
    ) async throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let envelopes: [[String: Any]] = try devices.map { recipient in
            let wire = try ClickCryptoV2.wrapEpochKey(
                metadata: .init(
                    chatId: scope.id,
                    epoch: epoch,
                    senderDeviceId: identity.info.deviceID,
                    recipientDeviceId: recipient.deviceID
                ),
                epochKey: epochKey,
                recipientPublicKeySpkiBase64: recipient.identityPublicKey,
                replayGuard: wrapReplayGuard
            )
            return [
                "recipient_device_id": recipient.deviceID,
                "envelope": wire
            ]
        }

        let body = try JSONSerialization.data(
            withJSONObject: [
                scope.idField: scope.id,
                "epoch": epoch,
                "sender_device_id": identity.info.deviceID,
                "membership_fingerprint": membershipFingerprint(devices),
                "envelopes": envelopes
            ],
            options: []
        )
        let request = APIRequest(
            path: "\(scope.root)/epochs",
            method: .post,
            body: body,
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    private func membershipFingerprint(_ devices: [DeviceRow]) -> String {
        let canonical = devices
            .map { "\($0.userID ?? ""):\($0.deviceID)" }
            .sorted()
            .joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Fetch messages

    public func fetchMessages(
        conversation: ConversationIdentity,
        currentUserID: String,
        cursor: Int64?,
        limit: Int = 40
    ) async throws -> [ChatMessageItem] {
        try await fetchPage(conversation: conversation, currentUserID: currentUserID, cursor: cursor, around: nil, limit: limit)
    }

    public func fetchMessages(around messageID: String, conversation: ConversationIdentity, currentUserID: String, limit: Int) async throws -> [ChatMessageItem] {
        try await fetchPage(conversation: conversation, currentUserID: currentUserID, cursor: nil, around: messageID, limit: limit)
    }

    /// Latest page, an older page (`cursor`), or a window around one message (`around`).
    private func fetchPage(
        conversation: ConversationIdentity,
        currentUserID: String,
        cursor: Int64?,
        around: String?,
        limit: Int
    ) async throws -> [ChatMessageItem] {
        if let hubID = conversation.hubID {
            // The hub thread route returns the latest window (or an around window); no older cursor.
            guard cursor == nil else { return [] }
            return try await fetchHubMessages(hubID: hubID, currentUserID: currentUserID, limit: limit, around: around)
        }

        let canonicalChatID = try await canonicalChatID(conversation)
        var queryItems = [
            URLQueryItem(name: "chatId", value: canonicalChatID),
            URLQueryItem(name: "limit", value: String(limit)),
            // Opt-in "Message deleted" placeholders (older servers ignore it).
            URLQueryItem(name: "include_tombstones", value: "1")
        ]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if let around {
            queryItems.append(URLQueryItem(name: "aroundMessageId", value: around))
        }

        let request = APIRequest(
            path: "/api/chat/messages",
            method: .get,
            queryItems: queryItems,
            requiresAuth: true
        )
        // Keys and messages load concurrently; key setup never delays the fetch.
        let participantIDs = await participants(for: conversation, currentUserID: currentUserID)
        async let sessionTask = try? resolveV2Session(scope: .chat(canonicalChatID), participantUserIDs: participantIDs, allowUpgrade: false)
        let (data, _) = try await apiClient.executeRaw(request)
        let rawResponse = try JSONDecoder().decode(RawMessagesResponse.self, from: data)
        var metadataByID: [String: [String: Any]] = [:]
        var tombstones: [ChatMessageItem] = []
        if let root = try? JSONFields.object(data) {
            for row in JSONFields.rows(root["messages"]) {
                if let id = JSONFields.string(row["id"]), let meta = JSONFields.dictionary(row["metadata"]) {
                    metadataByID[id] = meta
                }
            }
            tombstones = JSONFields.rows(root["tombstones"]).compactMap { row in
                guard let id = JSONFields.string(row["message_id"]), let sender = JSONFields.string(row["user_id"]),
                      let created = JSONFields.double(row["time_created"]) else { return nil }
                var item = ChatMessageItem(id: id, chatID: canonicalChatID, senderID: sender,
                                           senderName: sender == currentUserID ? "You" : (conversation.isDirect ? conversation.peerDisplayName : "Click user"),
                                           content: "", createdAt: Date(timeIntervalSince1970: created / 1000),
                                           isOutgoing: sender == currentUserID)
                item.isDeleted = true
                return item
            }
        }

        let legacy = await legacyKeys(for: conversation, currentUserID: currentUserID)

        // Message history should remain readable even if v2 device transfer is not yet available.
        // A missing historical epoch is represented per-message instead of failing the whole thread.
        let v2Session = await sessionTask

        if !conversation.isDirect {
            await resolveNames(rawResponse.messages.filter { $0.senderName == nil }.map(\.userID))
        }

        return tombstones + rawResponse.messages.map {
            mapRawMessage(
                $0,
                canonicalChatID: canonicalChatID,
                currentUserID: currentUserID,
                fallbackSenderName: conversation.isDirect ? conversation.peerDisplayName : nil,
                metadata: metadataByID[$0.id],
                legacy: legacy,
                v2Session: v2Session
            )
        }
    }

    // MARK: - Send / edit

    public func sendMessage(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        content: String,
        replyToID: String?,
        replyToSnippet: String?,
        replyToSenderName: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem {
        if let hubID = conversation.hubID {
            return try await sendHubMessage(
                hubID: hubID,
                currentUserID: currentUserID,
                currentUserName: currentUserName,
                content: content,
                replyToID: replyToID,
                replyToSnippet: replyToSnippet,
                replyToSenderName: replyToSenderName,
                clientMessageID: clientMessageID
            )
        }

        let canonicalChatID = try await canonicalChatID(conversation)
        let encrypted = try await encryptText(
            content,
            chatID: canonicalChatID,
            conversation: conversation,
            currentUserID: currentUserID,
            clientMessageID: clientMessageID
        )

        var metadata = encrypted.metadata
        metadata["client_message_id"] = clientMessageID
        // Only the reply target's ID is sent. A plaintext excerpt in metadata would expose
        // encrypted text to the server; the quote is resolved on-device from the timeline.
        if let replyToID { metadata["reply_to_id"] = replyToID }

        var post: [String: Any] = [
            "chat_id": canonicalChatID,
            "content": encrypted.wireContent,
            "message_type": "text",
            "metadata": metadata,
            "local_sent_at": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if conversation.isDirect, let connectionID = conversation.connectionID, !connectionID.isEmpty {
            post["connection_id"] = connectionID
        }

        let request = APIRequest(
            path: "/api/chat/messages",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: post, options: []),
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)

        let rawInsert: RawMessageItem
        if let wrapped = try? JSONDecoder().decode(RawMessageInsertResponse.self, from: data),
           let message = wrapped.message {
            rawInsert = message
        } else if let direct = try? JSONDecoder().decode(RawMessageItem.self, from: data) {
            rawInsert = direct
        } else {
            throw ChatRepositoryError.invalidServerPayload
        }

        return ChatMessageItem(
            id: rawInsert.id,
            chatID: canonicalChatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: content,
            rawContent: encrypted.wireContent,
            messageType: .text,
            createdAt: Date(timeIntervalSince1970: Double(rawInsert.timeCreated) / 1000.0),
            deliveryStatus: .sent,
            isOutgoing: true,
            replyToID: replyToID,
            replyToSnippet: replyToSnippet,
            replyToSenderName: replyToSenderName,
            reactions: [],
            isEdited: false
        )
    }

    public func editMessage(
        message: ChatMessageItem,
        conversation: ConversationIdentity,
        currentUserID: String,
        newContent: String
    ) async throws {
        let clientMessageID = ClickCryptoV2.generateClientMessageId()

        if let hubID = conversation.hubID {
            let encrypted = try await encryptHubText(newContent, hubID: hubID, clientMessageID: clientMessageID)
            var metadata = encrypted.metadata
            if let value = message.replyToID { metadata["reply_to_id"] = value }
            if encrypted.isPlaintext, let value = message.replyToSnippet { metadata["reply_to_content"] = value }
            var body = await hubLocationFields(camelCase: true)
            body["hubId"] = hubID
            body["body"] = encrypted.wireContent
            body["metadata"] = metadata
            try await hubRequest(path: "/api/hub/messages/\(message.id)", method: .patch, body: body)
            return
        }

        let canonicalChatID = try await resolveCanonicalChatID(
            chatID: message.chatID,
            connectionID: conversation.connectionID
        )
        let encrypted = try await encryptText(
            newContent,
            chatID: canonicalChatID,
            conversation: conversation,
            currentUserID: currentUserID,
            clientMessageID: clientMessageID
        )

        var metadata = encrypted.metadata
        metadata["client_message_id"] = clientMessageID
        if let value = message.replyToID { metadata["reply_to_id"] = value }
        metadata["is_edited"] = true

        let body: [String: Any] = [
            "messageId": message.id,
            "chat_id": canonicalChatID,
            "content": encrypted.wireContent,
            "metadata": metadata
        ]
        let request = APIRequest(
            path: "/api/chat/messages",
            method: .patch,
            body: try JSONSerialization.data(withJSONObject: body, options: []),
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    private func encryptText(
        _ plaintext: String,
        chatID: String,
        conversation: ConversationIdentity,
        currentUserID: String,
        clientMessageID: String
    ) async throws -> (wireContent: String, metadata: [String: Any]) {
        guard !currentUserID.isEmpty, conversation.isDirect ? !conversation.peerUserID.isEmpty : true else {
            throw ChatRepositoryError.missingConversationIdentity
        }

        if let session = try await resolveV2Session(
            scope: .chat(chatID),
            participantUserIDs: await participants(for: conversation, currentUserID: currentUserID, fresh: true),
            allowUpgrade: true
        ) {
            return try encryptV2(plaintext, chatID: chatID, session: session, clientMessageID: clientMessageID)
        }

        switch await legacyKeys(for: conversation, currentUserID: currentUserID) {
        case .direct(let keys):
            return (try ClickCryptoV1.encryptContent(plaintext, keys: keys), [:])
        case .group(let master):
            return (try ClickCryptoV1.encryptGroupContent(plaintext, groupMasterKey32: master), [:])
        case .hub, nil:
            throw ChatRepositoryError.encryptionUnavailable
        }
    }

    private func encryptV2(
        _ plaintext: String,
        chatID: String,
        session: V2Session,
        clientMessageID: String
    ) throws -> (wireContent: String, metadata: [String: Any]) {
        guard let epochKey = session.epochKeys[session.currentEpoch] else {
            throw ChatRepositoryError.currentEpochKeyUnavailable
        }
        let metadata = ClickCryptoV2.MessageMetadata(
            chatId: chatID,
            epoch: session.currentEpoch,
            senderDeviceId: session.deviceID,
            clientMessageId: clientMessageID
        )
        return (
            try ClickCryptoV2.encryptMessage(
                metadata: metadata,
                epochKey: epochKey,
                plaintext: plaintext,
                replayGuard: messageReplayGuard
            ),
            [
                "crypto_version": 2,
                "epoch": session.currentEpoch,
                "sender_device_id": session.deviceID,
                "client_message_id": clientMessageID
            ]
        )
    }

    // MARK: - Message operations

    public func deleteMessage(messageID: String, conversation: ConversationIdentity) async throws {
        if let hubID = conversation.hubID {
            var body = await hubLocationFields(camelCase: true)
            body["hubId"] = hubID
            try await hubRequest(path: "/api/hub/messages/\(messageID)", method: .delete, body: body)
            return
        }
        let request = APIRequest(
            path: "/api/chat/messages",
            method: .delete,
            queryItems: [URLQueryItem(name: "messageId", value: messageID)],
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    public func setReaction(messageID: String, reactionType: String, adding: Bool, conversation: ConversationIdentity) async throws {
        if let hubID = conversation.hubID {
            var body = await hubLocationFields(camelCase: true)
            body["hubId"] = hubID
            body["messageId"] = messageID
            body["reactionType"] = reactionType
            try await hubRequest(path: "/api/hub/reactions", method: adding ? .post : .delete, body: body)
            return
        }
        let body = try JSONSerialization.data(
            withJSONObject: [
                "messageId": messageID,
                "reactionType": reactionType
            ],
            options: []
        )
        let request = APIRequest(
            path: "/api/chat/reactions",
            method: adding ? .post : .delete,
            body: body,
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    /// Marks the latest peer message unread (spec §34.3; `PATCH /api/chat/messages/unread`),
    /// so server unread state matches the inbox badge on every device.
    public func markUnread(chatID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["chat_id": chatID])
        _ = try await apiClient.executeRaw(APIRequest(path: "/api/chat/messages/unread", method: .patch, body: body))
    }

    public func markRead(chatID: String, messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        let request = APIRequest(
            path: "/api/chat/messages/read",
            method: .patch,
            body: try JSONSerialization.data(
                withJSONObject: ["chatId": chatID, "messageIds": messageIDs],
                options: []
            ),
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    public func markDelivered(chatID: String, messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        let request = APIRequest(
            path: "/api/chat/messages/delivered",
            method: .patch,
            body: try JSONSerialization.data(
                withJSONObject: ["chatId": chatID, "messageIds": messageIDs],
                options: []
            ),
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    // MARK: - Realtime decoding

    public func decodeRealtimeMessage(
        _ payload: RealtimeMessagePayload,
        conversation: ConversationIdentity,
        currentUserID: String
    ) async throws -> ChatMessageItem {
        let isOutgoing = payload.senderID == currentUserID

        if let hubID = conversation.hubID {
            let v2Session = ClickCryptoV2.isEncrypted(payload.content)
                ? try? await resolveV2Session(scope: .hub(hubID), participantUserIDs: hubParticipants[hubID] ?? [], allowUpgrade: false)
                : nil
            await resolveNames([payload.senderID])
            let metadata = payload.metadata ?? [:]
            return ChatMessageItem(
                id: payload.id,
                chatID: hubID,
                senderID: payload.senderID,
                senderName: isOutgoing ? "You" : senderName(payload.senderID, fallback: nil),
                senderAvatarURL: senderNames[payload.senderID]?.avatarURL,
                content: decryptWireContent(payload.content, legacy: .hub(ClickCryptoV1.deriveKeysForHub(hubID: hubID)), v2Session: v2Session),
                rawContent: payload.content,
                messageType: MessageType(rawValue: payload.messageType) ?? .text,
                createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
                deliveryStatus: .sent,
                isOutgoing: isOutgoing,
                replyToID: string(metadata["reply_to_id"]),
                replyToSnippet: string(metadata["reply_to_content"]) ?? string(metadata["reply_to_snippet"]),
                replyToSenderName: string(metadata["reply_to_sender_name"]),
                reactions: [],
                isEdited: payload.isEdited,
                clientMessageID: string(metadata["client_message_id"])
            )
        }

        let canonicalChatID = try await resolveCanonicalChatID(
            chatID: payload.chatID,
            connectionID: conversation.connectionID
        )
        let legacy = await legacyKeys(for: conversation, currentUserID: currentUserID)

        let v2Session: V2Session?
        if ClickCryptoV2.isEncrypted(payload.content) {
            v2Session = try await resolveV2Session(
                scope: .chat(canonicalChatID),
                participantUserIDs: await participants(for: conversation, currentUserID: currentUserID),
                allowUpgrade: false
            )
        } else {
            v2Session = v2SessionCache[canonicalChatID]
        }

        if !conversation.isDirect { await resolveNames([payload.senderID]) }
        let decrypted = decryptWireContent(payload.content, legacy: legacy, v2Session: v2Session)

        return ChatMessageItem(
            id: payload.id,
            chatID: canonicalChatID,
            senderID: payload.senderID,
            senderName: isOutgoing ? "You" : senderName(payload.senderID, fallback: conversation.isDirect ? conversation.peerDisplayName : nil),
            senderAvatarURL: conversation.isDirect ? conversation.peerAvatarURL : senderNames[payload.senderID]?.avatarURL,
            content: decrypted,
            rawContent: payload.content,
            messageType: MessageType(rawValue: payload.messageType) ?? .text,
            createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
            deliveryStatus: isOutgoing
                ? (payload.isRead ? .read : (payload.deliveredAt == nil ? .sent : .delivered))
                : .delivered,
            isOutgoing: isOutgoing,
            replyToID: string(payload.metadata?["reply_to_id"]),
            replyToSnippet: string(payload.metadata?["reply_to_content"]) ?? string(payload.metadata?["reply_to_snippet"]),
            replyToSenderName: string(payload.metadata?["reply_to_sender_name"]),
            reactions: [],
            isEdited: bool(payload.metadata?["is_edited"]) ?? payload.isEdited,
            media: MessageMedia.parse(messageType: payload.messageType, metadata: payload.metadata, decryptedContent: decrypted, chatID: canonicalChatID),
            beacon: SharedBeacon.parse(messageType: payload.messageType, metadata: payload.metadata, content: decrypted),
            clientMessageID: string(payload.metadata?["client_message_id"])
        )
    }

    // MARK: - Inbox previews

    /// Decrypts an inbox preview using only key material already on this device: derived v1
    /// keys, or a v2 session cached since the conversation was last opened. Never fetches keys,
    /// so rendering the inbox costs no network work. Returns `nil` when the text can't be read
    /// yet; the inbox then shows a neutral label. The result must stay in memory only.
    public func inboxPreviewText(
        _ content: String,
        chatID: String?,
        connectionID: String,
        peerUserID: String,
        currentUserID: String
    ) -> String? {
        if ClickCryptoV2.isEncrypted(content) {
            return chatID.flatMap { cachedV2Preview(content, cacheKey: $0) }
        }

        if ClickCryptoV1.isEncrypted(content) {
            guard let keys = directKeys(
                connectionID: connectionID,
                peerUserID: peerUserID,
                currentUserID: currentUserID
            ) else { return nil }
            let decrypted = ClickCryptoV1.decryptContent(content, keys: keys)
            return ClickCryptoV1.isEncrypted(decrypted) ? nil : decrypted
        }

        return content
    }

    /// Group inbox preview from keys already held in memory (legacy master or cached v2 session).
    public func groupPreviewText(_ content: String, chatID: String, groupID: String) -> String? {
        if ClickCryptoV2.isEncrypted(content) {
            return cachedV2Preview(content, cacheKey: chatID)
        }
        if ClickCryptoV1.isGroupEncrypted(content) {
            guard let master = groupMasterCache[groupID] else { return nil }
            let decrypted = ClickCryptoV1.decryptGroupContent(content, groupMasterKey32: master)
            return ClickCryptoV1.isAnyV1WireContent(decrypted) ? nil : decrypted
        }
        return ClickCryptoV1.isAnyV1WireContent(content) ? nil : content
    }

    private func cachedV2Preview(_ content: String, cacheKey: String) -> String? {
        guard
            let session = v2SessionCache[cacheKey],
            let envelope = try? ClickCryptoV2.parseMessageEnvelope(wire: content),
            let key = session.epochKeys[envelope.epoch]
        else { return nil }
        // Reusing the timeline's replay guard is safe: re-reserving the same envelope and
        // nonce is idempotent, so opening the chat later decrypts this message normally.
        return try? ClickCryptoV2.decryptMessage(
            metadata: ClickCryptoV2.MessageMetadata(
                chatId: envelope.chatId,
                epoch: envelope.epoch,
                senderDeviceId: envelope.senderDeviceId,
                clientMessageId: envelope.clientMessageId
            ),
            epochKey: key,
            envelope: content,
            replayGuard: messageReplayGuard
        )
    }

    // MARK: - Media (spec §37; wire-compatible with KMP `SupabaseChatRepositoryMedia`)

    public func sendMedia(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        draft: MediaDraft,
        replyToID: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem {
        try await sendMedia(conversation: conversation, currentUserID: currentUserID, currentUserName: currentUserName,
                            draft: draft, replyToID: replyToID, clientMessageID: clientMessageID, progress: nil)
    }

    public func sendMedia(
        conversation: ConversationIdentity,
        currentUserID: String,
        currentUserName: String,
        draft: MediaDraft,
        replyToID: String?,
        clientMessageID: String,
        progress: (@Sendable (MediaUploadProgress) -> Void)?
    ) async throws -> ChatMessageItem {
        guard conversation.hubID == nil else { throw ChatRepositoryError.mediaUnsupported }
        switch MediaValidator.validate(draft) {
        case .tooLarge?: throw ChatRepositoryError.mediaTooLarge
        case .typeNotAllowed?, .empty?: throw ChatRepositoryError.mediaTypeNotAllowed
        case nil: break
        }
        progress?(.encrypting)
        let chatID = try await canonicalChatID(conversation)
        let fileName = draft.fileName ?? "\(draft.kind.rawValue).\(MessageMedia.fileExtension(forMIME: draft.mimeType))"

        var metadata: [String: Any] = [:]
        let content: String
        let wire: String

        if let session = try await resolveV2Session(
            scope: .chat(chatID),
            participantUserIDs: await participants(for: conversation, currentUserID: currentUserID, fresh: true),
            allowUpgrade: true
        ) {
            guard let epochKey = session.epochKeys[session.currentEpoch] else { throw ChatRepositoryError.currentEpochKeyUnavailable }
            // The media authorization and the message envelope share one client message ID;
            // the server rejects a media message whose IDs differ.
            let encrypted = try ClickCryptoV2.encryptMedia(
                metadata: .init(chatId: chatID, epoch: session.currentEpoch, senderDeviceId: session.deviceID,
                                clientMessageId: clientMessageID, mediaCiphertextSha256: ""),
                epochKey: epochKey,
                plaintext: draft.data,
                replayGuard: messageReplayGuard
            )
            let v2Fields: [String: Any] = [
                "e2ee_v2_envelope": encrypted.authorizationEnvelope,
                "media_ciphertext_sha256": encrypted.mediaCiphertextSha256,
                "epoch": session.currentEpoch,
                "sender_device_id": session.deviceID,
                "client_message_id": clientMessageID
            ]
            let uploaded = try await upload(draft, progress: progress, bytes: encrypted.uploadedBytes, chatID: chatID, fileName: fileName, extra: v2Fields)
            guard let path = uploaded.path else { throw ChatRepositoryError.invalidServerPayload }
            metadata = [
                "media_chat_id": chatID,
                "media_epoch": session.currentEpoch,
                "media_sender_device_id": session.deviceID,
                "media_client_message_id": clientMessageID,
                "media_ciphertext_sha256": encrypted.mediaCiphertextSha256,
                "media_authorization_envelope": encrypted.authorizationEnvelope,
                "media_path": path
            ]
            switch draft.kind {
            case .image, .audio:
                if let url = uploaded.url { metadata["media_url"] = url }
                content = " "
            case .file:
                content = try AttachmentEnvelope(
                    version: 2, name: fileName, mime: draft.mimeType, size: draft.data.count,
                    path: path, key: nil, sha256: encrypted.mediaCiphertextSha256
                ).encoded()
            }
            let body = try encryptV2(content, chatID: chatID, session: session, clientMessageID: clientMessageID)
            wire = body.wireContent
            metadata.merge(body.metadata) { current, _ in current }
        } else {
            guard let legacy = await legacyKeys(for: conversation, currentUserID: currentUserID) else {
                throw ChatRepositoryError.encryptionUnavailable
            }
            switch draft.kind {
            case .image, .audio:
                let cipher = try ClickCryptoV1.encryptMediaBytes(draft.data, keys: try Self.mediaKeys(legacy))
                let uploaded = try await upload(draft, progress: progress, bytes: cipher, chatID: chatID, fileName: fileName, extra: [:])
                guard let url = uploaded.url else { throw ChatRepositoryError.invalidServerPayload }
                metadata["media_url"] = url
                content = " "
            case .file:
                let fileKey = GroupRepository.randomMasterKey()
                let cipher = try ClickCryptoV1.encryptMediaBytes(
                    draft.data,
                    keys: try ClickCryptoV1.deriveKeysFromGroupMaster(groupMasterKey32: fileKey)
                )
                let uploaded = try await upload(draft, progress: progress, bytes: cipher, chatID: chatID, fileName: fileName, extra: [:])
                guard let path = uploaded.path else { throw ChatRepositoryError.invalidServerPayload }
                content = try AttachmentEnvelope(
                    version: 1, name: fileName, mime: draft.mimeType, size: draft.data.count, path: path,
                    key: fileKey.base64EncodedString(),
                    sha256: Data(SHA256.hash(data: draft.data)).base64EncodedString()
                ).encoded()
            }
            switch legacy {
            case .direct(let keys): wire = try ClickCryptoV1.encryptContent(content, keys: keys)
            case .group(let master): wire = try ClickCryptoV1.encryptGroupContent(content, groupMasterKey32: master)
            case .hub: throw ChatRepositoryError.mediaUnsupported
            }
        }

        switch draft.kind {
        case .image, .audio:
            metadata["original_mime_type"] = draft.mimeType
            metadata["is_encrypted_media"] = true
            if draft.isClickDrop {
                // KMP Click Drop: reveal is always 24 hours after send.
                metadata["disposable_roll"] = true
                metadata["collaboration_ttl"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
                if let encounterID = draft.encounterID { metadata["encounter_id"] = encounterID }
            }
            if let duration = draft.durationSeconds { metadata["duration_seconds"] = duration }
            if draft.kind == .audio, let waveform = draft.waveform { metadata["waveform"] = VoiceWaveform.wire(waveform) }
        case .file:
            if let path = metadata["media_path"] as? String ?? AttachmentEnvelope.decode(content)?.path {
                metadata["attachment_path"] = path
            }
            metadata["attachment_name"] = fileName
            metadata["attachment_mime"] = draft.mimeType
            metadata["attachment_size"] = draft.data.count
        }
        metadata["client_message_id"] = clientMessageID
        if let replyToID { metadata["reply_to_id"] = replyToID }

        var post: [String: Any] = [
            "chat_id": chatID,
            "content": wire,
            "message_type": draft.kind.rawValue,
            "metadata": metadata,
            "local_sent_at": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if conversation.isDirect, let connectionID = conversation.connectionID, !connectionID.isEmpty {
            post["connection_id"] = connectionID
        }
        let (data, _) = try await apiClient.executeRaw(APIRequest(
            path: "/api/chat/messages",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: post)
        ))
        let root = try JSONFields.object(data)
        let row = JSONFields.dictionary(root["message"]) ?? root
        guard let id = JSONFields.string(row["id"]) else { throw ChatRepositoryError.invalidServerPayload }
        let media = MessageMedia.parse(messageType: draft.kind.rawValue, metadata: metadata, decryptedContent: content, chatID: chatID)
        let local = try? await ChatMediaVault.shared.store(
            draft.data,
            messageID: id,
            fileExtension: media?.fileExtension ?? MessageMedia.fileExtension(forMIME: draft.mimeType)
        )
        return ChatMessageItem(
            id: id,
            chatID: chatID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: draft.kind == .file ? fileName : "",
            rawContent: wire,
            messageType: MessageType(rawValue: draft.kind.rawValue) ?? .file,
            createdAt: JSONFields.date(row["time_created"]) ?? .now,
            deliveryStatus: .sent,
            isOutgoing: true,
            replyToID: replyToID,
            media: media,
            localMediaURL: local
        )
    }

    public func sendBeacon(conversation: ConversationIdentity, currentUserID: String, currentUserName: String, beacon: MapBeacon, clientMessageID: String) async throws -> ChatMessageItem {
        guard conversation.hubID == nil else { throw ChatRepositoryError.mediaUnsupported }
        let chatID = try await canonicalChatID(conversation)
        let metadata = Self.beaconMetadata(beacon, clientMessageID: clientMessageID)
        let content = "Beacon: \(beacon.title)"
        var post: [String: Any] = [
            "chat_id": chatID, "content": content, "message_type": "beacon", "metadata": metadata,
            "local_sent_at": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if conversation.isDirect, let connectionID = conversation.connectionID, !connectionID.isEmpty {
            post["connection_id"] = connectionID
        }
        let (data, _) = try await apiClient.executeRaw(APIRequest(
            path: "/api/chat/messages", method: .post, body: try JSONSerialization.data(withJSONObject: post)
        ))
        let root = try JSONFields.object(data)
        let row = JSONFields.dictionary(root["message"]) ?? root
        guard let id = JSONFields.string(row["id"]) else { throw ChatRepositoryError.invalidServerPayload }
        return ChatMessageItem(
            id: id, chatID: chatID, senderID: currentUserID, senderName: currentUserName, content: content,
            messageType: .beacon, createdAt: .now, deliveryStatus: .sent, isOutgoing: true,
            beacon: SharedBeacon.parse(messageType: "beacon", metadata: metadata, content: content)
        )
    }

    /// Mirrors KMP `MapBeacon.toBeaconChatMetadata`.
    static func beaconMetadata(_ beacon: MapBeacon, clientMessageID: String) -> [String: Any] {
        var meta: [String: Any] = [
            "beacon_id": beacon.id, "beacon_type": beacon.rawType, "title": beacon.title,
            "lat": beacon.latitude, "lng": beacon.longitude,
            "share_url": "https://joinclick.co/e/\(beacon.id)", "client_message_id": clientMessageID
        ]
        if let description = beacon.description, description != beacon.title { meta["description"] = description }
        if let schedule = beacon.schedule {
            meta["schedule_label"] = EventFormatting.when(schedule)
            meta["event_start_at"] = Int64(schedule.start.timeIntervalSince1970 * 1000)
            meta["event_end_at"] = Int64(schedule.end.timeIntervalSince1970 * 1000)
        }
        if let image = beacon.imageURL { meta["album_art_url"] = image }
        if let place = beacon.formattedAddress ?? beacon.locationName, place.lowercased() != "current location" {
            meta["location_name"] = beacon.locationName ?? place
        }
        if let expires = beacon.expiresAt { meta["expires_at"] = Int64(expires.timeIntervalSince1970 * 1000) }
        return meta
    }

    public func loadMedia(for message: ChatMessageItem, conversation: ConversationIdentity, currentUserID: String) async throws -> URL {
        guard let media = message.media else { throw ChatRepositoryError.mediaUnavailable }
        if let local = message.localMediaURL, FileManager.default.fileExists(atPath: local.path) { return local }
        if let cached = await ChatMediaVault.shared.cachedURL(messageID: message.id, fileExtension: media.fileExtension) {
            return cached
        }
        guard conversation.hubID == nil else { throw ChatRepositoryError.mediaUnsupported }

        let plain: Data
        if let v2 = media.v2 {
            guard v2.chatId == message.chatID else { throw ChatRepositoryError.mediaUnavailable }
            guard
                let session = try await resolveV2Session(
                    scope: .chat(message.chatID),
                    participantUserIDs: await participants(for: conversation, currentUserID: currentUserID),
                    allowUpgrade: false
                ),
                let key = session.epochKeys[v2.epoch]
            else { throw ChatRepositoryError.currentEpochKeyUnavailable }
            let raw = try await downloadMedia(media)
            plain = try ClickCryptoV2.decryptMedia(metadata: v2, epochKey: key, uploadedBytes: raw, replayGuard: messageReplayGuard)
        } else if media.kind == .file {
            guard let keyB64 = media.fileKey, let fileKey = Data(base64Encoded: keyB64), fileKey.count == 32 else {
                throw ChatRepositoryError.mediaUnavailable
            }
            let raw = try await downloadMedia(media)
            plain = try ClickCryptoV1.decryptMediaBytes(raw, keys: try ClickCryptoV1.deriveKeysFromGroupMaster(groupMasterKey32: fileKey))
            if let expected = media.plaintextSha256, Data(SHA256.hash(data: plain)).base64EncodedString() != expected {
                throw ChatRepositoryError.mediaUnavailable
            }
        } else {
            guard let legacy = await legacyKeys(for: conversation, currentUserID: currentUserID) else {
                throw ChatRepositoryError.encryptionUnavailable
            }
            let raw = Self.normalizedMediaPayload(try await downloadMedia(media))
            plain = try ClickCryptoV1.decryptMediaBytes(raw, keys: try Self.mediaKeys(legacy))
        }
        return try await ChatMediaVault.shared.store(plain, messageID: message.id, fileExtension: media.fileExtension)
    }

    private static func mediaKeys(_ legacy: LegacyKeys) throws -> ClickCryptoV1.DerivedKeys {
        switch legacy {
        case .direct(let keys), .hub(let keys): keys
        case .group(let master): try ClickCryptoV1.deriveKeysFromGroupMaster(groupMasterKey32: master)
        }
    }

    private struct UploadResult {
        let url: String?
        let path: String?
    }

    /// Images and voice notes use `/api/chat/media`; files use `/api/chat/attachments`.
    private func upload(_ draft: MediaDraft, progress: (@Sendable (MediaUploadProgress) -> Void)?, bytes: Data, chatID: String, fileName: String, extra: [String: Any]) async throws -> UploadResult {
        var body = extra
        body["chat_id"] = chatID
        body["mime_type"] = draft.mimeType
        body["file_b64"] = bytes.base64EncodedString()
        let path: String
        if draft.kind == .file {
            body["file_name"] = fileName
            path = "/api/chat/attachments"
        } else {
            path = "/api/chat/media"
        }
        progress?(.uploading(fraction: 0))
        let (data, _) = try await apiClient.executeRaw(
            APIRequest(path: path, method: .post, body: try JSONSerialization.data(withJSONObject: body)),
            uploadProgress: progress.map { report in { @Sendable fraction in report(.uploading(fraction: fraction)) } }
        )
        let root = try JSONFields.object(data)
        return UploadResult(url: JSONFields.string(root["url"]), path: JSONFields.string(root["path"]))
    }

    /// Tries the stored signed URL, then re-signs the storage path (signed URLs expire).
    private func downloadMedia(_ media: MessageMedia) async throws -> Data {
        if let remote = media.remoteURL, let url = URL(string: remote), let data = try? await Self.fetch(url) {
            return data
        }
        guard let path = media.storagePath else { throw ChatRepositoryError.mediaUnavailable }
        let (data, _) = try await apiClient.executeRaw(APIRequest(
            path: "/api/chat/attachments/sign",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: ["path": path])
        ))
        guard let signed = JSONFields.string(try JSONFields.object(data)["url"]), let url = URL(string: signed) else {
            throw ChatRepositoryError.mediaUnavailable
        }
        return try await Self.fetch(url)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw ChatRepositoryError.mediaUnavailable
        }
        return data
    }

    /// Some legacy uploads stored the ciphertext base64-encoded (KMP `normalizeEncryptedMediaPayload`).
    static func normalizedMediaPayload(_ raw: Data) -> Data {
        let sample = raw.prefix(512)
        let printable = sample.filter { (0x20...0x7E).contains($0) || $0 == 0x0A || $0 == 0x0D }.count
        guard !sample.isEmpty, Double(printable) / Double(sample.count) > 0.95,
              var text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return raw
        }
        if let comma = text.range(of: "base64,") { text = String(text[comma.upperBound...]) }
        let compact = text.filter { !$0.isWhitespace }
        return Data(base64Encoded: compact) ?? Data(base64Encoded: compact.padding(toLength: (compact.count + 3) / 4 * 4, withPad: "=", startingAt: 0)) ?? raw
    }

    /// Maps stored `messages` rows (e.g. a profile's shared media tab) into timeline items
    /// with media and decrypted descriptors, using the same keys as the conversation.
    public func items(fromRows data: Data, conversation: ConversationIdentity, currentUserID: String) async -> [ChatMessageItem] {
        guard let raws = try? JSONDecoder().decode([RawMessageItem].self, from: data), !raws.isEmpty else { return [] }
        var metadataByID: [String: [String: Any]] = [:]
        for row in (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? [] {
            if let id = JSONFields.string(row["id"]), let meta = JSONFields.dictionary(row["metadata"]) { metadataByID[id] = meta }
        }
        let chatID = raws.first?.chatID ?? conversation.chatID
        let legacy = await legacyKeys(for: conversation, currentUserID: currentUserID)
        let session = try? await resolveV2Session(
            scope: .chat(chatID),
            participantUserIDs: await participants(for: conversation, currentUserID: currentUserID),
            allowUpgrade: false
        )
        return raws.map {
            mapRawMessage($0, canonicalChatID: chatID, currentUserID: currentUserID, fallbackSenderName: conversation.peerDisplayName,
                          metadata: metadataByID[$0.id], legacy: legacy, v2Session: session)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Hub transport (spec §61, §62)

    private func fetchHubMessages(hubID: String, currentUserID: String, limit: Int, around: String? = nil) async throws -> [ChatMessageItem] {
        let data: Data
        do {
            (data, _) = try await apiClient.executeRaw(APIRequest(
                path: "/api/hub/messages",
                method: .get,
                queryItems: [
                    URLQueryItem(name: "hubId", value: hubID),
                    URLQueryItem(name: "limit", value: String(min(max(limit, 1), 120)))
                ] + (around.map { [URLQueryItem(name: "aroundMessageId", value: $0)] } ?? [])
            ))
        } catch {
            throw HubChatError.map(error)
        }
        let root = try JSONFields.object(data)
        guard root["messages"] != nil else { throw ChatRepositoryError.invalidServerPayload }
        hubParticipants[hubID] = JSONFields.stringArray(root["participant_ids"])

        var reactionsByMessage: [String: [String: [String]]] = [:]
        for row in JSONFields.rows(root["reactions"]) {
            guard
                let messageID = JSONFields.string(row, "hub_message_id", "message_id"),
                let type = JSONFields.string(row, "reaction_type", "reactionType"),
                let user = JSONFields.string(row["user_id"])
            else { continue }
            reactionsByMessage[messageID, default: [:]][type, default: []].append(user)
        }

        let rows = JSONFields.rows(root["messages"])
        let hasV2 = rows.contains { ClickCryptoV2.isEncrypted(JSONFields.string($0["body"]) ?? "") }
        let v2Session = hasV2
            ? try? await resolveV2Session(scope: .hub(hubID), participantUserIDs: hubParticipants[hubID] ?? [], allowUpgrade: false)
            : nil
        await resolveNames(rows.compactMap { JSONFields.string($0["user_id"]) })
        let legacy = LegacyKeys.hub(ClickCryptoV1.deriveKeysForHub(hubID: hubID))

        return rows.compactMap { row in
            mapHubRow(
                row,
                hubID: hubID,
                currentUserID: currentUserID,
                reactions: reactionsByMessage,
                legacy: legacy,
                v2Session: v2Session
            )
        }
    }

    private func sendHubMessage(
        hubID: String,
        currentUserID: String,
        currentUserName: String,
        content: String,
        replyToID: String?,
        replyToSnippet: String?,
        replyToSenderName: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem {
        let encrypted = try await encryptHubText(content, hubID: hubID, clientMessageID: clientMessageID)
        var metadata = encrypted.metadata
        if let replyToID { metadata["reply_to_id"] = replyToID }
        // Plaintext reply excerpts would leak upgraded-hub text to the server; only send them
        // for hubs that are not v2 (where the body itself is plaintext anyway).
        if encrypted.isPlaintext, let replyToSnippet { metadata["reply_to_content"] = replyToSnippet }

        var body = await hubLocationFields(camelCase: false)
        body["hub_id"] = hubID
        body["body"] = encrypted.wireContent
        body["message_type"] = "text"
        body["metadata"] = metadata

        let data: Data
        do {
            (data, _) = try await apiClient.executeRaw(APIRequest(
                path: "/api/hub/messages",
                method: .post,
                body: try JSONSerialization.data(withJSONObject: body)
            ))
        } catch {
            throw HubChatError.map(error)
        }
        let root = try JSONFields.object(data)
        let row = JSONFields.dictionary(root["message"]) ?? root
        guard let id = JSONFields.string(row["id"]) else { throw ChatRepositoryError.invalidServerPayload }
        return ChatMessageItem(
            id: id,
            chatID: hubID,
            senderID: currentUserID,
            senderName: currentUserName,
            content: content,
            rawContent: encrypted.wireContent,
            messageType: .text,
            createdAt: JSONFields.date(row["created_at"]) ?? .now,
            deliveryStatus: .sent,
            isOutgoing: true,
            replyToID: replyToID,
            replyToSnippet: replyToSnippet,
            replyToSenderName: replyToSenderName,
            reactions: [],
            isEdited: false
        )
    }

    /// v2 when the hub is (or can now be) upgraded; plaintext only for never-upgraded hubs.
    /// A v2 hub whose key this device lacks throws rather than falling back.
    private func encryptHubText(
        _ plaintext: String,
        hubID: String,
        clientMessageID: String
    ) async throws -> (wireContent: String, metadata: [String: Any], isPlaintext: Bool) {
        if let session = try await resolveV2Session(
            scope: .hub(hubID),
            participantUserIDs: hubParticipants[hubID] ?? [],
            allowUpgrade: true
        ) {
            let encrypted = try encryptV2(plaintext, chatID: hubID, session: session, clientMessageID: clientMessageID)
            return (encrypted.wireContent, encrypted.metadata, false)
        }
        return (plaintext, ["client_message_id": clientMessageID], true)
    }

    /// Geofence coordinates for standalone hubs. Event hubs authorize by RSVP/check-in, so the
    /// fields are omitted (not faked) when no fix is available and the server decides.
    private func hubLocationFields(camelCase: Bool) async -> [String: Any] {
        guard let fix = await hubCoordinates?() else { return [:] }
        return camelCase
            ? ["userLat": fix.latitude, "userLong": fix.longitude]
            : ["user_lat": fix.latitude, "user_long": fix.longitude]
    }

    private func hubRequest(path: String, method: HTTPMethod, body: [String: Any]) async throws {
        do {
            _ = try await apiClient.executeRaw(APIRequest(
                path: path,
                method: method,
                body: try JSONSerialization.data(withJSONObject: body)
            ))
        } catch {
            throw HubChatError.map(error)
        }
    }

    private func mapHubRow(
        _ row: [String: Any],
        hubID: String,
        currentUserID: String,
        reactions: [String: [String: [String]]],
        legacy: LegacyKeys,
        v2Session: V2Session?
    ) -> ChatMessageItem? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        let sender = JSONFields.string(row["user_id"]) ?? ""
        let body = row["body"] as? String ?? ""
        let metadata = JSONFields.dictionary(row["metadata"]) ?? [:]
        let isOutgoing = sender == currentUserID
        let summaries = (reactions[id] ?? [:]).map { type, users in
            ReactionSummary(reactionType: type, count: users.count, userReacted: users.contains(currentUserID), userIDs: users)
        }
        .sorted { $0.reactionType < $1.reactionType }
        return ChatMessageItem(
            id: id,
            chatID: hubID,
            senderID: sender,
            senderName: isOutgoing ? "You" : senderName(sender, fallback: nil),
            senderAvatarURL: senderNames[sender]?.avatarURL,
            content: decryptWireContent(body, legacy: legacy, v2Session: v2Session),
            rawContent: body,
            messageType: MessageType(rawValue: JSONFields.string(row["message_type"]) ?? "text") ?? .text,
            createdAt: JSONFields.date(row["created_at"]) ?? .distantPast,
            deliveryStatus: .sent,
            isOutgoing: isOutgoing,
            replyToID: string(metadata["reply_to_id"]),
            replyToSnippet: string(metadata["reply_to_content"]) ?? string(metadata["reply_to_snippet"]),
            replyToSenderName: string(metadata["reply_to_sender_name"]),
            reactions: summaries,
            isEdited: JSONFields.string(row["edited_at"]) != nil
        )
    }

    // MARK: - Participants and names

    /// Users whose v2 devices must hold the epoch. Groups re-read membership from the server on
    /// writes so a stale route can never wrap keys for a removed member.
    private func participants(for conversation: ConversationIdentity, currentUserID: String, fresh: Bool = false) async -> [String] {
        switch conversation.kind {
        case .direct:
            return [currentUserID, conversation.peerUserID]
        case .group(let groupID):
            if fresh, let members = try? await groupMemberIDs(groupID: groupID), !members.isEmpty {
                return members
            }
            return conversation.participantUserIDs.isEmpty ? [currentUserID] : conversation.participantUserIDs
        case .hub(let hubID):
            return hubParticipants[hubID] ?? []
        }
    }

    private func groupMemberIDs(groupID: String) async throws -> [String] {
        try await restRows("group_members", [
            URLQueryItem(name: "select", value: "user_id"),
            URLQueryItem(name: "group_id", value: "eq.\(groupID)")
        ]).compactMap { JSONFields.string($0["user_id"]) }
    }

    private func resolveNames(_ userIDs: [String]) async {
        let missing = userIDs.filter { !$0.isEmpty && senderNames[$0] == nil }
        guard !missing.isEmpty else { return }
        for (id, identity) in await identities.resolve(missing) {
            guard let name = identity.name else { continue }
            senderNames[id] = (name, identity.avatarURL)
        }
    }

    private func senderName(_ userID: String, fallback: String?) -> String {
        senderNames[userID]?.name ?? fallback ?? "Click user"
    }

    // MARK: - Mapping / decryption

    private enum LegacyKeys: Sendable {
        case direct(ClickCryptoV1.DerivedKeys)
        case group(Data)
        case hub(ClickCryptoV1.DerivedKeys)
    }

    private func mapRawMessage(
        _ raw: RawMessageItem,
        canonicalChatID: String,
        currentUserID: String,
        fallbackSenderName: String?,
        metadata: [String: Any]?,
        legacy: LegacyKeys?,
        v2Session: V2Session?
    ) -> ChatMessageItem {
        let isOutgoing = raw.userID == currentUserID
        let content = decryptWireContent(raw.content, legacy: legacy, v2Session: v2Session)
        var reactions: [ReactionSummary] = []
        if let reactionMap = raw.reactions {
            reactions = reactionMap.map { emoji, entries in
                ReactionSummary(
                    reactionType: emoji,
                    count: entries.count,
                    userReacted: entries.contains { $0.userID == currentUserID },
                    userIDs: entries.map(\.userID)
                )
            }
            .sorted { $0.reactionType < $1.reactionType }
        }

        let deliveryStatus: MessageDeliveryStatus
        if isOutgoing {
            if raw.isRead == true {
                deliveryStatus = .read
            } else if raw.deliveredAt != nil {
                deliveryStatus = .delivered
            } else {
                deliveryStatus = .sent
            }
        } else {
            deliveryStatus = .delivered
        }

        let isEdited = raw.metadata?.isEdited == true || raw.timeEdited != nil

        return ChatMessageItem(
            id: raw.id,
            chatID: canonicalChatID,
            senderID: raw.userID,
            senderName: isOutgoing ? "You" : (raw.senderName ?? senderName(raw.userID, fallback: fallbackSenderName)),
            senderAvatarURL: raw.senderAvatarURL ?? senderNames[raw.userID]?.avatarURL,
            content: content,
            rawContent: raw.content,
            messageType: MessageType(rawValue: raw.messageType ?? "text") ?? .text,
            createdAt: Date(timeIntervalSince1970: Double(raw.timeCreated) / 1000.0),
            deliveryStatus: deliveryStatus,
            isOutgoing: isOutgoing,
            replyToID: raw.metadata?.replyToID,
            replyToSnippet: raw.metadata?.replyToContent ?? raw.metadata?.replyToSnippet,
            replyToSenderName: raw.metadata?.replyToSenderName,
            reactions: reactions,
            isEdited: isEdited,
            media: MessageMedia.parse(messageType: raw.messageType ?? "text", metadata: metadata, decryptedContent: content, chatID: canonicalChatID),
            beacon: SharedBeacon.parse(messageType: raw.messageType ?? "text", metadata: metadata, content: content),
            clientMessageID: raw.metadata?.clientMessageID
        )
    }

    private func decryptWireContent(
        _ content: String,
        legacy: LegacyKeys?,
        v2Session: V2Session?
    ) -> String {
        if ClickCryptoV2.isEncrypted(content) {
            guard let session = v2Session,
                  let envelope = try? ClickCryptoV2.parseMessageEnvelope(wire: content),
                  let key = session.epochKeys[envelope.epoch] else {
                return "Encrypted message unavailable on this device"
            }

            let metadata = ClickCryptoV2.MessageMetadata(
                chatId: envelope.chatId,
                epoch: envelope.epoch,
                senderDeviceId: envelope.senderDeviceId,
                clientMessageId: envelope.clientMessageId
            )
            guard let decrypted = try? ClickCryptoV2.decryptMessage(
                metadata: metadata,
                epochKey: key,
                envelope: content,
                replayGuard: messageReplayGuard
            ) else {
                return "Encrypted message could not be verified"
            }
            return decrypted
        }

        if ClickCryptoV1.isGroupEncrypted(content) {
            guard case .group(let master) = legacy else { return "Encrypted message unavailable on this device" }
            let decrypted = ClickCryptoV1.decryptGroupContent(content, groupMasterKey32: master)
            return ClickCryptoV1.isAnyV1WireContent(decrypted)
                ? "Encrypted message could not be verified"
                : decrypted
        }

        if ClickCryptoV1.isEncrypted(content) {
            let keys: ClickCryptoV1.DerivedKeys
            switch legacy {
            case .direct(let value), .hub(let value): keys = value
            case .group, nil: return "Encrypted message unavailable on this device"
            }
            let decrypted = ClickCryptoV1.decryptContent(content, keys: keys)
            return ClickCryptoV1.isEncrypted(decrypted)
                ? "Encrypted message could not be verified"
                : decrypted
        }

        return content
    }

    private func legacyKeys(for conversation: ConversationIdentity, currentUserID: String) async -> LegacyKeys? {
        switch conversation.kind {
        case .direct:
            return directKeys(
                connectionID: conversation.connectionID,
                peerUserID: conversation.peerUserID,
                currentUserID: currentUserID
            ).map(LegacyKeys.direct)
        case .group(let groupID):
            return await groupMasterKey(groupID: groupID, currentUserID: currentUserID).map(LegacyKeys.group)
        case .hub(let hubID):
            return .hub(ClickCryptoV1.deriveKeysForHub(hubID: hubID))
        }
    }

    private func directKeys(
        connectionID: String?,
        peerUserID: String,
        currentUserID: String
    ) -> ClickCryptoV1.DerivedKeys? {
        guard let connectionID,
              !connectionID.isEmpty,
              !peerUserID.isEmpty,
              !currentUserID.isEmpty else {
            return nil
        }
        if let cached = v1KeyCache[connectionID] {
            return cached
        }
        let keys = ClickCryptoV1.deriveKeysForConnection(
            connectionID: connectionID,
            userIDs: [currentUserID, peerUserID]
        )
        v1KeyCache[connectionID] = keys
        return keys
    }

    /// Legacy v1 group master (KMP `unwrapGroupMasterKeyFromDb`): the viewer's
    /// `group_members.encrypted_group_key` is v1-wrapped with the pairwise key between the viewer
    /// and the wrap peer (the creator, or the key anchor when the viewer is the creator).
    private func groupMasterKey(groupID: String, currentUserID: String) async -> Data? {
        if let cached = groupMasterCache[groupID] { return cached }
        guard
            let group = try? await restRows("groups", [
                URLQueryItem(name: "select", value: "created_by,key_anchor_user_id"),
                URLQueryItem(name: "id", value: "eq.\(groupID)"),
                URLQueryItem(name: "limit", value: "1")
            ]).first,
            let member = try? await restRows("group_members", [
                URLQueryItem(name: "select", value: "encrypted_group_key"),
                URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                URLQueryItem(name: "user_id", value: "eq.\(currentUserID)"),
                URLQueryItem(name: "limit", value: "1")
            ]).first,
            let wrapped = JSONFields.string(member["encrypted_group_key"])
        else { return nil }
        let creator = JSONFields.string(group["created_by"])
        guard let wrapPeer = currentUserID == creator ? JSONFields.string(group["key_anchor_user_id"]) : creator else {
            return nil
        }
        let connections = (try? await restRows("connections", [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "user_ids", value: "cs.{\(currentUserID),\(wrapPeer)}"),
            URLQueryItem(name: "limit", value: "5")
        ])) ?? []
        for row in connections {
            guard let connectionID = JSONFields.string(row["id"]) else { continue }
            let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: connectionID, userIDs: [currentUserID, wrapPeer])
            let plain = ClickCryptoV1.decryptContent(wrapped, keys: keys)
            // A failed HMAC returns the wire string unchanged; never base64-decode it.
            guard !ClickCryptoV1.isEncrypted(plain),
                  let master = Data(base64Encoded: plain.trimmingCharacters(in: .whitespacesAndNewlines)),
                  master.count == ClickCryptoV1.groupMasterKeyBytes else { continue }
            groupMasterCache[groupID] = master
            return master
        }
        return nil
    }

    private func restRows(_ table: String, _ query: [URLQueryItem]) async throws -> [[String: Any]] {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        let (data, _) = try await apiClient.executeRaw(APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/\(table)",
            method: .get,
            queryItems: query,
            headers: ["apikey": supabaseAnonKey]
        ))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.decoding
        }
        return rows
    }

    private func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    // MARK: - DTOs

    private struct ChatResolutionResponse: Decodable {
        let chatId: String
    }

    private struct V2Session: Sendable {
        let deviceID: String
        let currentEpoch: Int
        let epochKeys: [Int: Data]
    }

    private struct DeviceResponse: Decodable {
        let devices: [DeviceRow]
    }

    private struct DeviceRow: Decodable, Sendable {
        let id: String
        let userID: String?
        let deviceID: String
        let identityPublicKey: String
        let keyAlgorithm: String
        let cryptoVersion: Int

        enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id"
            case deviceID = "device_id"
            case identityPublicKey = "identity_public_key"
            case keyAlgorithm = "key_algorithm"
            case cryptoVersion = "crypto_version"
        }
    }

    /// Chat and hub epoch responses share a shape; hubs key it by `hub_id`.
    private struct EpochState: Decodable, Sendable {
        let currentEpoch: Int?
        let membershipFingerprint: String?
        let envelopes: [EpochEnvelopeRow]

        enum CodingKeys: String, CodingKey {
            case currentEpoch = "current_epoch"
            case membershipFingerprint = "membership_fingerprint"
            case envelopes
        }
    }

    private struct EpochEnvelopeRow: Decodable, Sendable {
        let epoch: Int
        let recipientDeviceID: String
        let senderDeviceID: String
        let envelope: String

        enum CodingKeys: String, CodingKey {
            case epoch
            case recipientDeviceID = "recipient_device_id"
            case senderDeviceID = "sender_device_id"
            case envelope
        }
    }

    private struct RawMessagesResponse: Decodable {
        let messages: [RawMessageItem]
    }

    private struct RawMessageInsertResponse: Decodable {
        let message: RawMessageItem?
    }

    private struct RawMessageItem: Decodable {
        let id: String
        let chatID: String
        let userID: String
        let content: String
        let messageType: String?
        let timeCreated: Int64
        let isRead: Bool?
        let readAt: Int64?
        let deliveredAt: Int64?
        let timeEdited: Int64?
        let senderName: String?
        let senderAvatarURL: String?
        let metadata: RawMessageMetadata?
        let reactions: [String: [RawReactionEntry]]?

        enum CodingKeys: String, CodingKey {
            case id
            case chatID = "chat_id"
            case userID = "user_id"
            case content
            case messageType = "message_type"
            case timeCreated = "time_created"
            case isRead = "is_read"
            case readAt = "read_at"
            case deliveredAt = "delivered_at"
            case timeEdited = "time_edited"
            case senderName = "sender_name"
            case senderAvatarURL = "sender_avatar_url"
            case metadata
            case reactions
        }
    }

    private struct RawMessageMetadata: Decodable {
        let replyToID: String?
        let replyToSnippet: String?
        let replyToContent: String?
        let replyToSenderName: String?
        let senderDeviceID: String?
        let clientMessageID: String?
        let epoch: Int?
        let cryptoVersion: Int?
        let isEdited: Bool?

        enum CodingKeys: String, CodingKey {
            case replyToID = "reply_to_id"
            case replyToSnippet = "reply_to_snippet"
            case replyToContent = "reply_to_content"
            case replyToSenderName = "reply_to_sender_name"
            case senderDeviceID = "sender_device_id"
            case clientMessageID = "client_message_id"
            case epoch
            case cryptoVersion = "crypto_version"
            case isEdited = "is_edited"
        }
    }

    private struct RawReactionEntry: Decodable {
        let userID: String
        let createdAt: Int64?

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case createdAt = "created_at"
        }
    }
}
