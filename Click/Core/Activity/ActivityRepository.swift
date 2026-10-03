import Foundation

/// One entry in the activity inbox (`GET /api/activity`): an alert the person got, whether or
/// not push was allowed. `data` is the push payload, so a tap routes exactly like the push.
public struct ActivityItem: Identifiable, Equatable, Sendable, Codable {
    public struct Actor: Equatable, Sendable, Codable {
        public let id: String
        public let name: String
        public let avatarURL: String?
    }

    public let id: String
    public let type: String
    public let title: String
    public let body: String
    public let data: [String: String]
    public let createdAt: Date
    /// The server's exact timestamp (microseconds), sent back verbatim as the "seen" mark.
    public let createdAtRaw: String
    public let actor: Actor?
}

/// A page of activity, newest first, with the viewer's "seen" mark.
public struct ActivityPage: Equatable, Sendable, Codable {
    public var items: [ActivityItem]
    public var seenAt: Date?
    /// The cursor for the next page (the server's raw timestamp); nil on the last page.
    public var nextBefore: String?
}

/// The activity inbox: pages of `GET /api/activity` and `POST /api/activity/seen`.
public actor ActivityRepository {
    private let api: ClickAPIClient
    private let cache: CacheStore

    public init(api: ClickAPIClient, cache: CacheStore = .shared) {
        self.api = api
        self.cache = cache
    }

    /// The first page as last shown, so the inbox (and the Home dot) paints at launch.
    public func cachedFirstPage(userID: String) async -> ActivityPage? {
        await cache.load(ActivityPage.self, key: "activity", userID: userID)
    }

    public func saveFirstPage(_ page: ActivityPage, userID: String) async {
        await cache.save(page, key: "activity", userID: userID)
    }

    public func page(before: String? = nil) async throws -> ActivityPage {
        let query = before.map { [URLQueryItem(name: "before", value: $0)] } ?? []
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/activity", queryItems: query))
        return Self.decode(try JSONFields.object(data))
    }

    public func markSeen(_ rawTimestamp: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["seen_at": rawTimestamp])
        _ = try await api.executeRaw(APIRequest(path: "/api/activity/seen", method: .post, body: body))
    }

    nonisolated static func decode(_ root: [String: Any]) -> ActivityPage {
        let items = JSONFields.rows(root["items"]).compactMap { row -> ActivityItem? in
            guard let id = JSONFields.string(row["id"]),
                  let type = JSONFields.string(row["type"]),
                  let title = JSONFields.string(row["title"]),
                  let raw = JSONFields.string(row["created_at"]),
                  let createdAt = ClickDateParser.parse(raw) else { return nil }
            let actor = JSONFields.dictionary(row["actor"]).flatMap { actor -> ActivityItem.Actor? in
                guard let actorID = JSONFields.string(actor["id"]) else { return nil }
                return ActivityItem.Actor(id: actorID, name: JSONFields.string(actor["name"]) ?? "Someone",
                                          avatarURL: JSONFields.string(actor["avatar_url"]))
            }
            let data = (JSONFields.dictionary(row["data"]) ?? [:]).compactMapValues { value -> String? in
                if let string = value as? String { return string }
                return (value as? NSNumber)?.stringValue
            }
            return ActivityItem(id: id, type: type, title: title, body: JSONFields.string(row["body"]) ?? "",
                                data: data, createdAt: createdAt, createdAtRaw: raw, actor: actor)
        }
        return ActivityPage(items: items, seenAt: JSONFields.date(root["seen_at"]),
                            nextBefore: JSONFields.string(root["next_before"]))
    }
}
