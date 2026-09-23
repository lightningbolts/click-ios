import Foundation
import CryptoKit

/// Protocol defining authenticated direct-chat operations.
///
/// The protocol intentionally owns wire/encryption concerns. Presentation models never decide
/// whether plaintext, v1, or v2 should be written.
public protocol ChatRepositoryProtocol: Sendable {
    func resolveCanonicalChatID(chatID: String, connectionID: String?) async throws -> String

    func fetchMessages(
        chatID: String,
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        cursor: Int64?,
        limit: Int
    ) async throws -> [ChatMessageItem]

    func sendMessage(
        chatID: String,
        connectionID: String?,
        peerUserID: String,
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
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        newContent: String
    ) async throws

    func deleteMessage(messageID: String) async throws
    func setReaction(messageID: String, reactionType: String, adding: Bool) async throws
    func markRead(chatID: String, messageIDs: [String]) async throws
    func markDelivered(chatID: String, messageIDs: [String]) async throws
    func registerDevice() async throws

    func decodeRealtimeMessage(
        _ payload: RealtimeMessagePayload,
        connectionID: String?,
        peerUserID: String,
        peerDisplayName: String,
        currentUserID: String
    ) async throws -> ChatMessageItem
}

public enum ChatRepositoryError: Error, LocalizedError, Sendable {
    case missingConversationIdentity
    case unresolvedChat
    case encryptionUnavailable
    case currentDeviceNotRegistered
    case currentEpochUnavailable
    case currentEpochKeyUnavailable
    case invalidServerPayload

    public var errorDescription: String? {
        switch self {
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

/// Authoritative repository for direct-chat transport and E2EE v1/v2 lifecycle.
///
/// Important invariant: user-authored text is never silently downgraded to plaintext. If neither
/// current v2 nor legacy v1 can securely write a direct message, the operation fails closed.
public actor ChatRepository: ChatRepositoryProtocol {
    private let apiClient: ClickAPIClient
    private let vault: DeviceIdentityVault
    private let messageReplayGuard = ClickCryptoV2.ReplayGuard()
    private let wrapReplayGuard = ClickCryptoV2.ReplayGuard()

    private var v1KeyCache: [String: ClickCryptoV1.DerivedKeys] = [:]
    private var v2SessionCache: [String: V2Session] = [:]

    public init(apiClient: ClickAPIClient, vault: DeviceIdentityVault = .shared) {
        self.apiClient = apiClient
        self.vault = vault
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

    // MARK: - Device registration / E2EE v2 session lifecycle

    public func registerDevice() async throws {
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
        } catch APIError.conflict {
            // Registration is idempotent from the client's perspective.
        }
    }

    private func resolveV2Session(
        chatID: String,
        participantUserIDs: [String],
        allowUpgrade: Bool
    ) async throws -> V2Session? {
        if !allowUpgrade, let cached = v2SessionCache[chatID] {
            return cached
        }

        let identity = try vault.loadOrCreate()
        try await registerDevice()

        var devices = try await discoverDevices(chatID: chatID)
        guard let ownDevice = devices.first(where: { $0.deviceID == identity.info.deviceID }) else {
            // Registration and discovery are separate authenticated requests. Refresh once in case
            // the just-created row was not visible to the first read.
            devices = try await discoverDevices(chatID: chatID)
            guard devices.contains(where: { $0.deviceID == identity.info.deviceID }) else {
                throw ChatRepositoryError.currentDeviceNotRegistered
            }
            return try await resolveV2Session(
                chatID: chatID,
                participantUserIDs: participantUserIDs,
                allowUpgrade: allowUpgrade
            )
        }

        var state = try await fetchEpochState(chatID: chatID, deviceID: identity.info.deviceID)
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
                try await createEpoch(
                    chatID: chatID,
                    identity: identity,
                    devices: devices,
                    epoch: 1
                )
            } catch APIError.conflict {
                // Another active device may have created epoch 1 concurrently.
            }
            state = try await fetchEpochState(chatID: chatID, deviceID: identity.info.deviceID)
        } else if allowUpgrade {
            guard allParticipantsHaveV2Devices else {
                // An already-upgraded conversation must never downgrade to v1 merely because an
                // active participant temporarily has no usable v2 device.
                throw ChatRepositoryError.encryptionUnavailable
            }

            let fingerprint = membershipFingerprint(devices)
            if let currentFingerprint = state.membershipFingerprint,
               currentFingerprint != fingerprint,
               let currentEpoch = state.currentEpoch {
                do {
                    try await createEpoch(
                        chatID: chatID,
                        identity: identity,
                        devices: devices,
                        epoch: currentEpoch + 1
                    )
                } catch APIError.conflict {
                    // A peer device can rotate first; fresh state below is authoritative.
                }
                state = try await fetchEpochState(chatID: chatID, deviceID: identity.info.deviceID)
            }
        }

        guard let currentEpoch = state.currentEpoch else {
            throw ChatRepositoryError.currentEpochUnavailable
        }

        var epochKeys: [Int: Data] = [:]
        for row in state.envelopes where row.recipientDeviceID == identity.info.deviceID {
            do {
                let key = try ClickCryptoV2.unwrapEpochKey(
                    metadata: .init(
                        chatId: row.chatID,
                        epoch: row.epoch,
                        senderDeviceId: row.senderDeviceID,
                        recipientDeviceId: row.recipientDeviceID
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
        v2SessionCache[chatID] = session
        return session
    }

    private func discoverDevices(chatID: String) async throws -> [DeviceRow] {
        let request = APIRequest(
            path: "/api/chat/devices",
            method: .get,
            queryItems: [URLQueryItem(name: "chat_id", value: chatID)],
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)
        return try JSONDecoder().decode(DeviceResponse.self, from: data).devices
            .filter { $0.keyAlgorithm == "X25519" && $0.cryptoVersion == 2 }
    }

    private func fetchEpochState(chatID: String, deviceID: String) async throws -> EpochState {
        let request = APIRequest(
            path: "/api/chat/epochs",
            method: .get,
            queryItems: [
                URLQueryItem(name: "chat_id", value: chatID),
                URLQueryItem(name: "device_id", value: deviceID)
            ],
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)
        return try JSONDecoder().decode(EpochState.self, from: data)
    }

    private func createEpoch(
        chatID: String,
        identity: DeviceIdentityVault.DeviceIdentity,
        devices: [DeviceRow],
        epoch: Int
    ) async throws {
        let epochKey = try ClickCryptoV2.generateEpochKey()
        let envelopes: [[String: Any]] = try devices.map { recipient in
            let wire = try ClickCryptoV2.wrapEpochKey(
                metadata: .init(
                    chatId: chatID,
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
                "chat_id": chatID,
                "epoch": epoch,
                "sender_device_id": identity.info.deviceID,
                "membership_fingerprint": membershipFingerprint(devices),
                "envelopes": envelopes
            ],
            options: []
        )
        let request = APIRequest(
            path: "/api/chat/epochs",
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
        chatID: String,
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        cursor: Int64?,
        limit: Int = 40
    ) async throws -> [ChatMessageItem] {
        let canonicalChatID = try await resolveCanonicalChatID(chatID: chatID, connectionID: connectionID)
        var queryItems = [
            URLQueryItem(name: "chatId", value: canonicalChatID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }

        let request = APIRequest(
            path: "/api/chat/messages",
            method: .get,
            queryItems: queryItems,
            requiresAuth: true
        )
        let (data, _) = try await apiClient.executeRaw(request)
        let rawResponse = try JSONDecoder().decode(RawMessagesResponse.self, from: data)

        let v1Keys = legacyKeys(
            connectionID: connectionID,
            peerUserID: peerUserID,
            currentUserID: currentUserID
        )

        // Message history should remain readable even if v2 device transfer is not yet available.
        // A missing historical epoch is represented per-message instead of failing the whole thread.
        let v2Session: V2Session?
        do {
            v2Session = try await resolveV2Session(
                chatID: canonicalChatID,
                participantUserIDs: [currentUserID, peerUserID],
                allowUpgrade: false
            )
        } catch {
            v2Session = nil
        }

        return rawResponse.messages.map {
            mapRawMessage(
                $0,
                canonicalChatID: canonicalChatID,
                currentUserID: currentUserID,
                peerDisplayName: $0.senderName ?? "User",
                v1Keys: v1Keys,
                v2Session: v2Session
            )
        }
    }

    // MARK: - Send / edit

    public func sendMessage(
        chatID: String,
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        currentUserName: String,
        content: String,
        replyToID: String?,
        replyToSnippet: String?,
        replyToSenderName: String?,
        clientMessageID: String
    ) async throws -> ChatMessageItem {
        let canonicalChatID = try await resolveCanonicalChatID(chatID: chatID, connectionID: connectionID)
        let encrypted = try await encryptText(
            content,
            chatID: canonicalChatID,
            connectionID: connectionID,
            peerUserID: peerUserID,
            currentUserID: currentUserID,
            clientMessageID: clientMessageID
        )

        var metadata = encrypted.metadata
        metadata["client_message_id"] = clientMessageID
        if let replyToID { metadata["reply_to_id"] = replyToID }
        if let replyToSnippet { metadata["reply_to_snippet"] = replyToSnippet }
        if let replyToSenderName { metadata["reply_to_sender_name"] = replyToSenderName }

        var post: [String: Any] = [
            "chat_id": canonicalChatID,
            "content": encrypted.wireContent,
            "message_type": "text",
            "metadata": metadata,
            "local_sent_at": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let connectionID, !connectionID.isEmpty {
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
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        newContent: String
    ) async throws {
        let canonicalChatID = try await resolveCanonicalChatID(
            chatID: message.chatID,
            connectionID: connectionID
        )
        let clientMessageID = ClickCryptoV2.generateClientMessageId()
        let encrypted = try await encryptText(
            newContent,
            chatID: canonicalChatID,
            connectionID: connectionID,
            peerUserID: peerUserID,
            currentUserID: currentUserID,
            clientMessageID: clientMessageID
        )

        var metadata = encrypted.metadata
        metadata["client_message_id"] = clientMessageID
        if let value = message.replyToID { metadata["reply_to_id"] = value }
        if let value = message.replyToSnippet { metadata["reply_to_snippet"] = value }
        if let value = message.replyToSenderName { metadata["reply_to_sender_name"] = value }
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
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        clientMessageID: String
    ) async throws -> (wireContent: String, metadata: [String: Any]) {
        guard !currentUserID.isEmpty, !peerUserID.isEmpty else {
            throw ChatRepositoryError.missingConversationIdentity
        }

        if let session = try await resolveV2Session(
            chatID: chatID,
            participantUserIDs: [currentUserID, peerUserID],
            allowUpgrade: true
        ) {
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

        guard let keys = legacyKeys(
            connectionID: connectionID,
            peerUserID: peerUserID,
            currentUserID: currentUserID
        ) else {
            throw ChatRepositoryError.encryptionUnavailable
        }
        return (try ClickCryptoV1.encryptContent(plaintext, keys: keys), [:])
    }

    // MARK: - Message operations

    public func deleteMessage(messageID: String) async throws {
        let request = APIRequest(
            path: "/api/chat/messages",
            method: .delete,
            queryItems: [URLQueryItem(name: "messageId", value: messageID)],
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    public func setReaction(messageID: String, reactionType: String, adding: Bool) async throws {
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
        connectionID: String?,
        peerUserID: String,
        peerDisplayName: String,
        currentUserID: String
    ) async throws -> ChatMessageItem {
        let canonicalChatID = try await resolveCanonicalChatID(
            chatID: payload.chatID,
            connectionID: connectionID
        )
        let v1Keys = legacyKeys(
            connectionID: connectionID,
            peerUserID: peerUserID,
            currentUserID: currentUserID
        )

        let v2Session: V2Session?
        if ClickCryptoV2.isEncrypted(payload.content) {
            v2Session = try await resolveV2Session(
                chatID: canonicalChatID,
                participantUserIDs: [currentUserID, peerUserID],
                allowUpgrade: false
            )
        } else {
            v2Session = v2SessionCache[canonicalChatID]
        }

        let isOutgoing = payload.senderID == currentUserID
        let decrypted = decryptWireContent(
            payload.content,
            v1Keys: v1Keys,
            v2Session: v2Session
        )

        return ChatMessageItem(
            id: payload.id,
            chatID: canonicalChatID,
            senderID: payload.senderID,
            senderName: isOutgoing ? "You" : peerDisplayName,
            content: decrypted,
            rawContent: payload.content,
            messageType: MessageType(rawValue: payload.messageType) ?? .text,
            createdAt: Date(timeIntervalSince1970: Double(payload.timeCreated) / 1000.0),
            deliveryStatus: isOutgoing
                ? (payload.isRead ? .read : (payload.deliveredAt == nil ? .sent : .delivered))
                : .delivered,
            isOutgoing: isOutgoing,
            replyToID: string(payload.metadata?["reply_to_id"]),
            replyToSnippet: string(payload.metadata?["reply_to_snippet"]),
            replyToSenderName: string(payload.metadata?["reply_to_sender_name"]),
            reactions: [],
            isEdited: bool(payload.metadata?["is_edited"]) ?? false
        )
    }

    // MARK: - Mapping / decryption

    private func mapRawMessage(
        _ raw: RawMessageItem,
        canonicalChatID: String,
        currentUserID: String,
        peerDisplayName: String,
        v1Keys: ClickCryptoV1.DerivedKeys?,
        v2Session: V2Session?
    ) -> ChatMessageItem {
        let isOutgoing = raw.userID == currentUserID
        var reactions: [ReactionSummary] = []
        if let reactionMap = raw.reactions {
            reactions = reactionMap.map { emoji, entries in
                ReactionSummary(
                    reactionType: emoji,
                    count: entries.count,
                    userReacted: entries.contains { $0.userID == currentUserID }
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

        return ChatMessageItem(
            id: raw.id,
            chatID: canonicalChatID,
            senderID: raw.userID,
            senderName: isOutgoing ? "You" : (raw.senderName ?? peerDisplayName),
            senderAvatarURL: raw.senderAvatarURL,
            content: decryptWireContent(raw.content, v1Keys: v1Keys, v2Session: v2Session),
            rawContent: raw.content,
            messageType: MessageType(rawValue: raw.messageType ?? "text") ?? .text,
            createdAt: Date(timeIntervalSince1970: Double(raw.timeCreated) / 1000.0),
            deliveryStatus: deliveryStatus,
            isOutgoing: isOutgoing,
            replyToID: raw.metadata?.replyToID,
            replyToSnippet: raw.metadata?.replyToSnippet,
            replyToSenderName: raw.metadata?.replyToSenderName,
            reactions: reactions,
            isEdited: raw.metadata?.isEdited ?? raw.timeEdited != nil
        )
    }

    private func decryptWireContent(
        _ content: String,
        v1Keys: ClickCryptoV1.DerivedKeys?,
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

        if ClickCryptoV1.isEncrypted(content) {
            guard let v1Keys else { return "Encrypted message unavailable on this device" }
            let decrypted = ClickCryptoV1.decryptContent(content, keys: v1Keys)
            return ClickCryptoV1.isEncrypted(decrypted)
                ? "Encrypted message could not be verified"
                : decrypted
        }

        return content
    }

    private func legacyKeys(
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

    private struct EpochState: Decodable, Sendable {
        let chatID: String
        let deviceID: String
        let currentEpoch: Int?
        let membershipFingerprint: String?
        let envelopes: [EpochEnvelopeRow]

        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case deviceID = "device_id"
            case currentEpoch = "current_epoch"
            case membershipFingerprint = "membership_fingerprint"
            case envelopes
        }
    }

    private struct EpochEnvelopeRow: Decodable, Sendable {
        let chatID: String
        let epoch: Int
        let recipientDeviceID: String
        let senderDeviceID: String
        let envelope: String

        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
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
        let replyToSenderName: String?
        let senderDeviceID: String?
        let clientMessageID: String?
        let epoch: Int?
        let cryptoVersion: Int?
        let isEdited: Bool?

        enum CodingKeys: String, CodingKey {
            case replyToID = "reply_to_id"
            case replyToSnippet = "reply_to_snippet"
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
