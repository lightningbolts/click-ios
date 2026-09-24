import Foundation

/// A hub or event chat the user has opened on this device (KMP `ActiveHubEntry`). The server
/// has no "my hubs" listing, so membership shown in Groups is remembered locally and
/// pruned whenever the server reports the hub gone or inaccessible.
public struct JoinedHub: Codable, Equatable, Identifiable, Sendable {
    public let hubID: String
    public var name: String
    public var category: String?
    public var eventBeaconID: String?
    public var joinedAt: Date
    public var lastMessage: String?
    public var lastSenderName: String?
    public var lastActivityAt: Date?

    public var id: String { hubID }
    public var isEvent: Bool { eventBeaconID != nil || category?.lowercased() == "event" }
}

public actor JoinedHubStore {
    private let cache: CacheStore

    public init(cache: CacheStore = .shared) {
        self.cache = cache
    }

    public func hubs(userID: String) async -> [JoinedHub] {
        await cache.load([JoinedHub].self, key: "joined-hubs", userID: userID) ?? []
    }

    public func upsert(_ hub: JoinedHub, userID: String) async {
        var all = await hubs(userID: userID)
        if let index = all.firstIndex(where: { $0.hubID == hub.hubID }) {
            var merged = hub
            merged.joinedAt = all[index].joinedAt
            merged.lastMessage = hub.lastMessage ?? all[index].lastMessage
            merged.lastSenderName = hub.lastSenderName ?? all[index].lastSenderName
            merged.lastActivityAt = hub.lastActivityAt ?? all[index].lastActivityAt
            all[index] = merged
        } else {
            all.append(hub)
        }
        await cache.save(all, key: "joined-hubs", userID: userID)
    }

    public func replaceAll(_ hubs: [JoinedHub], userID: String) async {
        await cache.save(hubs, key: "joined-hubs", userID: userID)
    }

    public func remove(hubID: String, userID: String) async {
        let all = await hubs(userID: userID).filter { $0.hubID != hubID }
        await cache.save(all, key: "joined-hubs", userID: userID)
    }
}
