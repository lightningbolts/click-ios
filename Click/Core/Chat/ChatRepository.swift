import Foundation
import CryptoKit

/// Protocol defining authenticated chat data operations.
public protocol ChatRepositoryProtocol: Sendable {
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

    func editMessage(messageID: String, newContent: String) async throws
    func deleteMessage(messageID: String) async throws
    func markRead(chatID: String, messageIDs: [String]) async throws
    func markDelivered(chatID: String, messageIDs: [String]) async throws
    func registerDevice() async throws
}

/// Authoritative repository managing direct chat communications and E2EE v1/v2 cryptography.
public actor ChatRepository: ChatRepositoryProtocol {

    private let apiClient: ClickAPIClient
    private let vault: DeviceIdentityVault
    private let replayGuard = ClickCryptoV2.ReplayGuard()

    // In-memory key caches
    private var v1KeyCache: [String: ClickCryptoV1.DerivedKeys] = [:]
    private var v2EpochCache: [String: Data] = [:] // chatID -> epochKey

    public init(apiClient: ClickAPIClient, vault: DeviceIdentityVault = .shared) {
        self.apiClient = apiClient
        self.vault = vault
    }

    // MARK: - Device Registration

    public func registerDevice() async throws {
        let identity = try vault.loadOrCreate()
        let bodyDict: [String: String] = [
            "device_id": identity.info.deviceID,
            "identity_public_key": identity.info.publicKeySpkiBase64
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        let request = APIRequest(
            path: "/api/chat/devices",
            method: .post,
            body: bodyData,
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    // MARK: - Fetch Messages

    public func fetchMessages(
        chatID: String,
        connectionID: String?,
        peerUserID: String,
        currentUserID: String,
        cursor: Int64?,
        limit: Int = 40
    ) async throws -> [ChatMessageItem] {
        var queryItems = [
            URLQueryItem(name: "chatId", value: chatID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }

        let request = APIRequest(
            path: "/api/chat/messages",
            method: .get,
            queryItems: queryItems,
            requiresAuth: true
        )

        let (data, response) = try await apiClient.executeRaw(request)
        guard response.statusCode == 200 else {
            throw mapHttpError(statusCode: response.statusCode, data: data)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let rawResponse = try decoder.decode(RawMessagesResponse.self, from: data)

        // Ensure v1 keys derived if connectionID present
        let v1Keys: ClickCryptoV1.DerivedKeys?
        if let connID = connectionID, !connID.isEmpty, !peerUserID.isEmpty, !currentUserID.isEmpty {
            v1Keys = getOrCreateV1Keys(connectionID: connID, userIDs: [currentUserID, peerUserID])
        } else {
            v1Keys = nil
        }

        var result: [ChatMessageItem] = []
        for raw in rawResponse.messages {
            let isOutgoing = raw.user_id == currentUserID
            let decrypted = decryptRawMessage(
                raw: raw,
                v1Keys: v1Keys,
                chatID: chatID
            )

            // Parse reactions
            var reactions: [ReactionSummary] = []
            if let reactionMap = raw.reactions {
                for (emoji, list) in reactionMap {
                    let userReacted = list.contains { $0.user_id == currentUserID }
                    reactions.append(ReactionSummary(reactionType: emoji, count: list.count, userReacted: userReacted))
                }
            }

            let deliveryStatus: MessageDeliveryStatus
            if isOutgoing {
                if raw.is_read == true {
                    deliveryStatus = .read
                } else if raw.delivered_at != nil {
                    deliveryStatus = .delivered
                } else {
                    deliveryStatus = .sent
                }
            } else {
                deliveryStatus = .delivered
            }

            let createdAtDate = Date(timeIntervalSince1970: Double(raw.time_created) / 1000.0)

            let item = ChatMessageItem(
                id: raw.id,
                chatID: chatID,
                senderID: raw.user_id,
                senderName: isOutgoing ? "You" : (raw.sender_name ?? "User"),
                senderAvatarURL: raw.sender_avatar_url,
                content: decrypted,
                rawContent: raw.content,
                messageType: MessageType(rawValue: raw.message_type ?? "text") ?? .text,
                createdAt: createdAtDate,
                deliveryStatus: deliveryStatus,
                isOutgoing: isOutgoing,
                replyToID: raw.metadata?.reply_to_id,
                replyToSnippet: raw.metadata?.reply_to_snippet,
                replyToSenderName: raw.metadata?.reply_to_sender_name,
                reactions: reactions,
                isEdited: raw.metadata?.is_edited ?? false
            )
            result.append(item)
        }

        return result
    }

    // MARK: - Send Message

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
        // Prepare encryption: try v2 if epoch exists, else v1
        let wireContent: String
        var metaDict: [String: Any] = [
            "client_message_id": clientMessageID
        ]
        if let replyToID = replyToID {
            metaDict["reply_to_id"] = replyToID
        }
        if let replyToSnippet = replyToSnippet {
            metaDict["reply_to_snippet"] = replyToSnippet
        }
        if let replyToSenderName = replyToSenderName {
            metaDict["reply_to_sender_name"] = replyToSenderName
        }

        if let epochKey = v2EpochCache[chatID] {
            let identity = try vault.loadOrCreate()
            let meta = ClickCryptoV2.MessageMetadata(
                chatId: chatID,
                epoch: 1,
                senderDeviceId: identity.info.deviceID,
                clientMessageId: clientMessageID
            )
            wireContent = try ClickCryptoV2.encryptMessage(
                metadata: meta,
                epochKey: epochKey,
                plaintext: content,
                replayGuard: replayGuard
            )
            metaDict["epoch"] = 1
            metaDict["sender_device_id"] = identity.info.deviceID
        } else if let connID = connectionID, !connID.isEmpty, !peerUserID.isEmpty {
            let keys = getOrCreateV1Keys(connectionID: connID, userIDs: [currentUserID, peerUserID])
            wireContent = try ClickCryptoV1.encryptContent(content, keys: keys)
        } else {
            wireContent = content
        }

        var postDict: [String: Any] = [
            "chat_id": chatID,
            "content": wireContent,
            "message_type": "text",
            "metadata": metaDict,
            "local_sent_at": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let connID = connectionID, !connID.isEmpty {
            postDict["connection_id"] = connID
        }

        let bodyData = try JSONSerialization.data(withJSONObject: postDict, options: [])
        let request = APIRequest(
            path: "/api/chat/messages",
            method: .post,
            body: bodyData,
            requiresAuth: true
        )

        let (data, response) = try await apiClient.executeRaw(request)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            throw mapHttpError(statusCode: response.statusCode, data: data)
        }

        let rawInsert: RawMessageItem
        if let decodedResponse = try? JSONDecoder().decode(RawMessageInsertResponse.self, from: data),
           let msg = decodedResponse.message {
            rawInsert = msg
        } else if let direct = try? JSONDecoder().decode(RawMessageItem.self, from: data) {
            rawInsert = direct
        } else {
            // Fallback: construct response with local echo
            rawInsert = RawMessageItem(
                id: clientMessageID,
                chat_id: chatID,
                user_id: currentUserID,
                content: wireContent,
                message_type: "text",
                time_created: Int64(Date().timeIntervalSince1970 * 1000),
                is_read: false,
                read_at: nil,
                delivered_at: nil,
                sender_name: currentUserName,
                sender_avatar_url: nil,
                metadata: RawMessageMetadata(
                    reply_to_id: replyToID,
                    reply_to_snippet: replyToSnippet,
                    reply_to_sender_name: replyToSenderName,
                    is_edited: false
                ),
                reactions: nil
            )
        }

        return ChatMessageItem(
            id: rawInsert.id,
            chatID: chatID,
            senderID: currentUserID,
            senderName: "You",
            content: content,
            rawContent: wireContent,
            messageType: .text,
            createdAt: Date(timeIntervalSince1970: Double(rawInsert.time_created) / 1000.0),
            deliveryStatus: .sent,
            isOutgoing: true,
            replyToID: replyToID,
            replyToSnippet: replyToSnippet,
            replyToSenderName: replyToSenderName,
            reactions: [],
            isEdited: false
        )
    }

    // MARK: - Message Operations

    public func editMessage(messageID: String, newContent: String) async throws {
        let body: [String: Any] = [
            "messageId": messageID,
            "content": newContent
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        let request = APIRequest(
            path: "/api/chat/messages",
            method: .patch,
            body: bodyData,
            requiresAuth: true
        )
        let (data, response) = try await apiClient.executeRaw(request)
        guard response.statusCode == 200 else {
            throw mapHttpError(statusCode: response.statusCode, data: data)
        }
    }

    public func deleteMessage(messageID: String) async throws {
        let queryItems = [URLQueryItem(name: "messageId", value: messageID)]
        let request = APIRequest(
            path: "/api/chat/messages",
            method: .delete,
            queryItems: queryItems,
            requiresAuth: true
        )
        let (data, response) = try await apiClient.executeRaw(request)
        guard response.statusCode == 200 else {
            throw mapHttpError(statusCode: response.statusCode, data: data)
        }
    }

    public func markRead(chatID: String, messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        let body: [String: Any] = [
            "chatId": chatID,
            "messageIds": messageIDs
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        let request = APIRequest(
            path: "/api/chat/messages/read",
            method: .patch,
            body: bodyData,
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    public func markDelivered(chatID: String, messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        let body: [String: Any] = [
            "chatId": chatID,
            "messageIds": messageIDs
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        let request = APIRequest(
            path: "/api/chat/messages/delivered",
            method: .patch,
            body: bodyData,
            requiresAuth: true
        )
        _ = try await apiClient.executeRaw(request)
    }

    // MARK: - Internal Decrypt Helpers

    private func getOrCreateV1Keys(connectionID: String, userIDs: [String]) -> ClickCryptoV1.DerivedKeys {
        if let existing = v1KeyCache[connectionID] {
            return existing
        }
        let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: connectionID, userIDs: userIDs)
        v1KeyCache[connectionID] = keys
        return keys
    }

    private func decryptRawMessage(raw: RawMessageItem, v1Keys: ClickCryptoV1.DerivedKeys?, chatID: String) -> String {
        let content = raw.content

        // Check v2 envelope
        if ClickCryptoV2.isEncrypted(content) {
            if let epochKey = v2EpochCache[chatID] {
                let metadata = ClickCryptoV2.MessageMetadata(
                    chatId: chatID,
                    epoch: 1,
                    senderDeviceId: raw.metadata?.sender_device_id ?? "unknown",
                    clientMessageId: raw.metadata?.client_message_id ?? raw.id
                )
                if let decrypted = try? ClickCryptoV2.decryptMessage(
                    metadata: metadata,
                    epochKey: epochKey,
                    envelope: content,
                    replayGuard: replayGuard
                ) {
                    return decrypted
                }
            }
            return "🔒 Encrypted Message"
        }

        // Check v1 envelope
        if ClickCryptoV1.isEncrypted(content) {
            if let keys = v1Keys {
                let decrypted = ClickCryptoV1.decryptContent(content, keys: keys)
                if !ClickCryptoV1.isEncrypted(decrypted) {
                    return decrypted
                }
            }
            return "🔒 Encrypted Message"
        }

        return content
    }

    // MARK: - DTO Serialization Schemas

    private struct RawMessagesResponse: Decodable {
        let messages: [RawMessageItem]
    }

    private struct RawMessageInsertResponse: Decodable {
        let message: RawMessageItem?
    }

    private struct RawMessageItem: Decodable {
        let id: String
        let chat_id: String
        let user_id: String
        let content: String
        let message_type: String?
        let time_created: Int64
        let is_read: Bool?
        let read_at: Int64?
        let delivered_at: Int64?
        let sender_name: String?
        let sender_avatar_url: String?
        let metadata: RawMessageMetadata?
        let reactions: [String: [RawReactionEntry]]?
    }

    private func mapHttpError(statusCode: Int, data: Data) -> APIError {
        switch statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        default:
            let msg = String(data: data, encoding: .utf8)
            return .server(status: statusCode, code: nil, message: msg)
        }
    }

    private struct RawMessageMetadata: Decodable {
        let reply_to_id: String?
        let reply_to_snippet: String?
        let reply_to_sender_name: String?
        let sender_device_id: String?
        let client_message_id: String?
        let is_edited: Bool?

        init(
            reply_to_id: String? = nil,
            reply_to_snippet: String? = nil,
            reply_to_sender_name: String? = nil,
            sender_device_id: String? = nil,
            client_message_id: String? = nil,
            is_edited: Bool? = nil
        ) {
            self.reply_to_id = reply_to_id
            self.reply_to_snippet = reply_to_snippet
            self.reply_to_sender_name = reply_to_sender_name
            self.sender_device_id = sender_device_id
            self.client_message_id = client_message_id
            self.is_edited = is_edited
        }
    }

    private struct RawReactionEntry: Decodable {
        let user_id: String
        let created_at: Int64?
    }
}
