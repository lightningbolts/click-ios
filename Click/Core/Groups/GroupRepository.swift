import Foundation
import Security

/// A verified group (clique) member.
public struct GroupMember: Codable, Equatable, Identifiable, Sendable {
    public let userID: String
    public let name: String
    public let avatarURL: String?

    public var id: String { userID }
    public var initials: String { Phase3Repository.initials(from: name) }
}

/// Verified group reads and management (spec §30, §48).
///
/// Reads use the same RLS-scoped tables the KMP and web clients read (`group_members`, `chats`,
/// `groups`, `messages`); mutations use the server RPCs / BFF routes that own authorization and
/// server-side key wrapping. The client never decides membership.
public actor GroupRepository {
    private let api: ClickAPIClient
    private let supabaseURL: URL?
    private let supabaseAnonKey: String

    public init(api: ClickAPIClient, supabaseURL: URL?, supabaseAnonKey: String) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    /// Every group the user belongs to that has a chat, with members, latest message, and unread.
    public func groups(userID: String) async throws -> [CliqueItem] {
        let memberships = try await rest("group_members", [
            .init(name: "select", value: "group_id"),
            .init(name: "user_id", value: "eq.\(userID)"),
            .init(name: "limit", value: "500")
        ])
        let groupIDs = Array(Set(memberships.compactMap { JSONFields.string($0["group_id"]) })).sorted()
        guard !groupIDs.isEmpty else { return [] }
        let idList = "in.(\(groupIDs.joined(separator: ",")))"

        // Fetched concurrently as raw bytes (Sendable), parsed after.
        async let chatsTask = restData("chats", [.init(name: "select", value: "id,group_id,updated_at"), .init(name: "group_id", value: idList)])
        async let groupsTask = groupRowsData(idList)
        async let membersTask = restData("group_members", [
            .init(name: "select", value: "group_id,user_id"),
            .init(name: "group_id", value: idList),
            .init(name: "limit", value: "5000")
        ])
        let (chatsData, groupsData, membersData) = try await (chatsTask, groupsTask, membersTask)
        let chats = try Self.rows(chatsData)
        let groups = try Self.rows(groupsData)
        let members = try Self.rows(membersData)

        let chatByGroup = Dictionary(chats.compactMap { row -> (String, [String: Any])? in
            guard let groupID = JSONFields.string(row["group_id"]) else { return nil }
            return (groupID, row)
        }, uniquingKeysWith: { first, _ in first })
        var memberIDsByGroup: [String: [String]] = [:]
        for row in members {
            guard let groupID = JSONFields.string(row["group_id"]), let user = JSONFields.string(row["user_id"]) else { continue }
            memberIDsByGroup[groupID, default: []].append(user)
        }
        let chatIDs = chatByGroup.values.compactMap { JSONFields.string($0["id"]) }
        let allMemberIDs = Array(Set(memberIDsByGroup.values.flatMap { $0 }))

        async let namesTask = identities(allMemberIDs)
        async let latestTask = latestMessages(chatIDs: chatIDs, currentUserID: userID)
        async let unreadTask = unreadCounts(chatIDs: chatIDs, currentUserID: userID)
        let (names, latest, unread) = await (namesTask, latestTask, unreadTask)

        return groups.compactMap { row -> CliqueItem? in
            guard
                let groupID = JSONFields.string(row["id"]),
                let chat = chatByGroup[groupID],
                let chatID = JSONFields.string(chat["id"])
            else { return nil }
            let memberIDs = Array(Set(memberIDsByGroup[groupID] ?? [userID])).sorted()
            let groupMembers = memberIDs.map { id in
                GroupMember(userID: id, name: names[id]?.name ?? "Click user", avatarURL: names[id]?.avatarURL)
            }
            var preview = latest[chatID]
            if let sender = preview?.senderID, sender != userID, let name = names[sender]?.name {
                preview?.message.senderName = name.split(separator: " ").first.map(String.init) ?? name
            }
            let activity = preview?.date ?? JSONFields.date(chat["updated_at"])
            return CliqueItem(
                id: groupID,
                chatID: chatID,
                name: JSONFields.string(row["name"]) ?? "Group",
                memberCount: memberIDs.count,
                lastActiveRelative: "",
                createdBy: JSONFields.string(row["created_by"]),
                avatarURL: JSONFields.string(row["avatar_url"]),
                members: groupMembers,
                lastActivityAt: activity,
                lastMessage: preview?.message,
                unreadCount: unread[chatID] ?? 0
            )
        }
        .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    /// The group that owns a chat, for routes that carry only a chat ID.
    public func groupID(forChatID chatID: String) async throws -> String? {
        let rows = try await rest("chats", [.init(name: "select", value: "group_id"), .init(name: "id", value: "eq.\(chatID)")])
        return rows.first.flatMap { JSONFields.string($0["group_id"]) }
    }

    // MARK: - Management (server-authorized)

    /// Creates a verified group (KMP `VerifiedCliqueCreation`): a random 32-byte master is sealed
    /// for every member with the pairwise v1 key between that member and their wrap peer (the
    /// creator, or the anchor for the creator's own row). The server RPC validates the graph.
    /// - Parameter connectionIDs: the creator's active connection ID for each other member.
    public func create(creatorID: String, connectionIDs: [String: String], name: String) async throws -> String {
        let payload = try Self.createPayload(
            creatorID: creatorID,
            connectionIDs: connectionIDs,
            name: name,
            masterKey: Self.randomMasterKey()
        )
        let data = try await rpcData("create_verified_clique", payload)
        if let id = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String { return id }
        if let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any], let id = rows.first as? String { return id }
        throw APIError.decoding
    }

    static func randomMasterKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: ClickCryptoV1.groupMasterKeyBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func createPayload(creatorID: String, connectionIDs: [String: String], name: String, masterKey: Data) throws -> [String: Any] {
        let members = Array(Set(connectionIDs.keys).union([creatorID])).sorted()
        guard members.count >= 2, let anchor = members.first(where: { $0 != creatorID }) else {
            throw APIError.validation(code: nil, message: "Pick at least one other person")
        }
        let wrapped = masterKey.base64EncodedString()
        var encrypted: [String: String] = [:]
        for member in members {
            let peer = member == creatorID ? anchor : creatorID
            let other = member == creatorID ? anchor : member
            guard let connectionID = connectionIDs[other] else {
                throw APIError.validation(code: nil, message: "Missing verified connection for a member")
            }
            let keys = ClickCryptoV1.deriveKeysForConnection(connectionID: connectionID, userIDs: [member, peer])
            encrypted[member] = try ClickCryptoV1.encryptContent(wrapped, keys: keys)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "target_user_ids": members,
            "encrypted_keys": encrypted,
            "initial_group_name": trimmed.isEmpty ? "Clique" : trimmed
        ]
    }

    public func rename(groupID: String, to name: String) async throws {
        try await rpc("rename_clique", ["target_group_id": groupID, "new_name": name])
    }

    public func leave(groupID: String) async throws {
        try await rpc("leave_clique", ["target_group_id": groupID])
    }

    public func delete(groupID: String) async throws {
        try await rpc("delete_clique", ["target_group_id": groupID])
    }

    public func addMember(groupID: String, userID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["group_id": groupID, "new_member_user_id": userID])
        _ = try await api.executeRaw(APIRequest(path: "/api/cliques/members", method: .post, body: body))
    }

    public func removeMember(groupID: String, userID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["group_id": groupID, "member_user_id": userID])
        _ = try await api.executeRaw(APIRequest(path: "/api/cliques/members", method: .delete, body: body))
    }

    /// `POST /api/groups/{id}/avatar` (server enforces authorization and its change cooldown).
    public func uploadAvatar(groupID: String, jpeg: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["file_b64": jpeg.base64EncodedString(), "mime_type": "image/jpeg"])
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/groups/\(groupID)/avatar", method: .post, body: body))
        guard let url = JSONFields.string(try JSONFields.object(data)["image"]) else { throw APIError.decoding }
        return url
    }

    // MARK: - Private

    /// `avatar_url` is optional on older schemas; never let it block listing (KMP note).
    private func groupRowsData(_ idList: String) async throws -> Data {
        do {
            return try await restData("groups", [.init(name: "select", value: "id,name,created_by,avatar_url"), .init(name: "id", value: idList)])
        } catch {
            return try await restData("groups", [.init(name: "select", value: "id,name,created_by"), .init(name: "id", value: idList)])
        }
    }

    private struct Latest: Sendable {
        var message: InboxLastMessage
        let date: Date?
        let senderID: String?
    }

    private func latestMessages(chatIDs: [String], currentUserID: String) async -> [String: Latest] {
        guard !chatIDs.isEmpty, let rows = try? await rest("messages", [
            .init(name: "select", value: "chat_id,user_id,content,message_type,time_created,is_read,metadata"),
            .init(name: "chat_id", value: "in.(\(chatIDs.joined(separator: ",")))"),
            .init(name: "order", value: "time_created.desc"),
            .init(name: "limit", value: String(max(50, chatIDs.count * 10)))
        ]) else { return [:] }
        var result: [String: Latest] = [:]
        for row in rows {
            guard let chatID = JSONFields.string(row["chat_id"]), result[chatID] == nil else { continue }
            let metadata = JSONFields.dictionary(row["metadata"])
            result[chatID] = Latest(
                message: InboxLastMessage(
                    content: row["content"] as? String ?? "",
                    messageType: JSONFields.string(row["message_type"]) ?? "text",
                    isOutgoing: JSONFields.string(row["user_id"]) == currentUserID,
                    isRead: JSONFields.bool(row["is_read"]) ?? false,
                    isDisposable: JSONFields.bool(metadata?["disposable_roll"]) ?? false
                ),
                date: JSONFields.date(row["time_created"]),
                senderID: JSONFields.string(row["user_id"])
            )
        }
        return result
    }

    private func unreadCounts(chatIDs: [String], currentUserID: String) async -> [String: Int] {
        guard !chatIDs.isEmpty, let rows = try? await rest("messages", [
            .init(name: "select", value: "chat_id"),
            .init(name: "chat_id", value: "in.(\(chatIDs.joined(separator: ",")))"),
            .init(name: "is_read", value: "eq.false"),
            .init(name: "user_id", value: "neq.\(currentUserID)"),
            .init(name: "limit", value: "10000")
        ]) else { return [:] }
        var counts: [String: Int] = [:]
        for row in rows {
            if let chatID = JSONFields.string(row["chat_id"]) { counts[chatID, default: 0] += 1 }
        }
        return counts
    }

    private func identities(_ userIDs: [String]) async -> [String: (name: String?, avatarURL: String?)] {
        var result: [String: (name: String?, avatarURL: String?)] = [:]
        for start in stride(from: 0, to: userIDs.count, by: 100) {
            let chunk = Array(userIDs[start..<min(start + 100, userIDs.count)])
            guard
                let body = try? JSONSerialization.data(withJSONObject: ["userIds": chunk]),
                let (data, _) = try? await api.executeRaw(APIRequest(path: "/api/users/display-names", method: .post, body: body)),
                let root = try? JSONFields.object(data)
            else { continue }
            let names = root["names"] as? [String: Any] ?? [:]
            let images = root["images"] as? [String: Any] ?? [:]
            for id in chunk {
                result[id] = (JSONFields.string(names[id]), JSONFields.string(images[id]))
            }
        }
        return result
    }

    private func rest(_ table: String, _ query: [URLQueryItem]) async throws -> [[String: Any]] {
        try Self.rows(try await restData(table, query))
    }

    private func restData(_ table: String, _ query: [URLQueryItem]) async throws -> Data {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        let (data, _) = try await api.executeRaw(APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/\(table)",
            method: .get,
            queryItems: query,
            headers: ["apikey": supabaseAnonKey]
        ))
        return data
    }

    private static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw APIError.decoding }
        return rows
    }

    private func rpc(_ name: String, _ body: [String: String]) async throws {
        _ = try await rpcData(name, body)
    }

    private func rpcData(_ name: String, _ body: [String: Any]) async throws -> Data {
        guard let supabaseURL, !supabaseAnonKey.isEmpty else { throw APIError.invalidURL }
        return try await api.executeRaw(APIRequest(
            baseURL: supabaseURL,
            path: "/rest/v1/rpc/\(name)",
            method: .post,
            headers: ["apikey": supabaseAnonKey],
            body: try JSONSerialization.data(withJSONObject: body)
        )).0
    }
}
