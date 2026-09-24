import Foundation

/// A resolved display identity for a user ID.
public struct UserIdentity: Equatable, Sendable {
    public let name: String?
    public let avatarURL: String?
}

/// Shared display-name/avatar resolver (`POST /api/users/display-names`), replacing the three
/// separate lookups the group, chat and hub repositories used to make.
///
/// Entries live for `CachePolicy.displayNames`; unknown IDs are fetched in concurrent chunks of
/// 100 and concurrent requests for the same IDs share one call.
public actor IdentityCache {
    private let api: ClickAPIClient
    private let maxAge: TimeInterval
    private var entries: [String: (identity: UserIdentity, storedAt: Date)] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    public init(api: ClickAPIClient, maxAge: TimeInterval = CachePolicy.displayNames) {
        self.api = api
        self.maxAge = maxAge
    }

    /// Cached identity only; never fetches.
    public func cached(_ userID: String) -> UserIdentity? {
        entries[userID]?.identity
    }

    /// Resolves identities for `userIDs`, fetching only missing or expired ones. Lookup failures
    /// leave IDs unresolved (callers fall back to a generic label); they are never cached.
    @discardableResult
    public func resolve(_ userIDs: [String], now: Date = .now) async -> [String: UserIdentity] {
        let unique = Array(Set(userIDs.filter { !$0.isEmpty }))
        let missing = unique.filter { id in
            guard let entry = entries[id] else { return true }
            return now.timeIntervalSince(entry.storedAt) >= maxAge
        }
        var waits: [Task<Void, Never>] = []
        var toFetch: [String] = []
        for id in missing {
            if let running = inFlight[id] { waits.append(running) } else { toFetch.append(id) }
        }
        let chunks = stride(from: 0, to: toFetch.count, by: 100).map { Array(toFetch[$0..<min($0 + 100, toFetch.count)]) }
        for chunk in chunks {
            let task = Task { await self.fetch(chunk) }
            for id in chunk { inFlight[id] = task }
            waits.append(task)
        }
        for wait in waits { await wait.value }
        var result: [String: UserIdentity] = [:]
        for id in unique {
            if let identity = entries[id]?.identity { result[id] = identity }
        }
        return result
    }

    public func removeAll() {
        entries.removeAll()
    }

    private func fetch(_ chunk: [String]) async {
        defer { for id in chunk { inFlight[id] = nil } }
        guard
            let body = try? JSONSerialization.data(withJSONObject: ["userIds": chunk]),
            let (data, _) = try? await api.executeRaw(APIRequest(path: "/api/users/display-names", method: .post, body: body, idempotent: true)),
            let root = try? JSONFields.object(data)
        else { return }
        let names = root["names"] as? [String: Any] ?? [:]
        let images = root["images"] as? [String: Any] ?? [:]
        let now = Date()
        for id in chunk where names[id] != nil || images[id] != nil {
            entries[id] = (UserIdentity(name: JSONFields.string(names[id]), avatarURL: JSONFields.string(images[id])), now)
        }
    }
}
