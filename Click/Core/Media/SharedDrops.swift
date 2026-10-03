import Foundation
import UIKit

/// A shared Click Drop (spec F3): one photo to all your connections or only core ones, developing
/// an hour after it's posted, like a story. Not end-to-end encrypted like chat drops — only the people it's
/// shared with can see it, and the original stays on the server until it develops.
public struct SharedDrop: Identifiable, Sendable, Equatable, Codable {
    public enum Audience: String, Sendable, CaseIterable, Codable { case all, core }

    public let id: String
    public let userID: String
    public let userName: String
    public let avatarURL: String?
    public let isMine: Bool
    /// Only on your own drops.
    public let audience: Audience?
    /// The connection to reply in (others' drops).
    public let connectionID: String?
    public let createdAt: Date?
    public let revealAt: Date?
    public var developedAt: Date?
    public let previewURL: URL?
    /// Locket-style caption; the server sends it to others only once the drop develops.
    public var caption: String? = nil
    /// Signed URL for the original once this viewer has developed it (fresh from the server only;
    /// it expires, so a copy read back from disk is dropped).
    public var originalURL: URL? = nil
    /// Reactions, inline once this viewer has developed it, so the viewer opens filled.
    public var reactions: ReactionsState? = nil

    /// Captions are capped at this many characters (as people count them).
    public static let captionLimit = 100

    public func state(now: Date = .now) -> ClickDropDevelopState {
        .resolve(revealAt: revealAt, developedAt: developedAt, now: now)
    }

    static func parse(_ row: [String: Any]) -> SharedDrop? {
        guard let id = JSONFields.string(row["id"]) else { return nil }
        let user = JSONFields.dictionary(row["user"]) ?? [:]
        return SharedDrop(
            id: id,
            userID: JSONFields.string(user["id"]) ?? "",
            userName: JSONFields.string(user["name"]) ?? "Someone",
            avatarURL: JSONFields.string(user["avatar_url"]),
            isMine: JSONFields.bool(row["is_mine"]) ?? false,
            audience: JSONFields.string(row["audience"]).flatMap(Audience.init(rawValue:)),
            connectionID: JSONFields.string(row["connection_id"]),
            createdAt: JSONFields.date(row["created_at"]),
            revealAt: JSONFields.date(row["reveal_at"]),
            developedAt: JSONFields.date(row["developed_at"]),
            previewURL: JSONFields.string(row["preview_url"]).flatMap(URL.init(string:)),
            caption: JSONFields.string(row["caption"]).flatMap { $0.isEmpty ? nil : $0 },
            originalURL: JSONFields.string(row["original_url"]).flatMap(URL.init(string:)),
            reactions: JSONFields.dictionary(row["reactions"]).map(ReactionsState.parse)
        )
    }
}

public enum SharedDropPostError: Error, Equatable, LocalizedError {
    case capReached, invalidPhoto

    public var errorDescription: String? {
        switch self {
        case .capReached: "You've shared all your drops for today. Try again tomorrow."
        case .invalidPhoto: "That photo couldn't be used. Try another."
        }
    }
}

/// Developed shared-drop originals kept on disk per user (the bytes as downloaded), so the strip
/// and the viewer paint at once on every later open and launch instead of downloading again.
/// Pruned to the drops still in the strip.
enum SharedDropPhotoCache {
    private static func directory(_ userID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shared-drops-v2/\(userID)", isDirectory: true)
    }

    private static func file(_ dropID: String, userID: String) -> URL {
        directory(userID).appendingPathComponent("\(dropID).jpg")
    }

    /// Decoded at most `maxPixels` on its longest side (720 for tiles, more for the viewer).
    static func load(_ dropID: String, userID: String, maxPixels: CGFloat) -> UIImage? {
        guard let data = try? Data(contentsOf: file(dropID, userID: userID)) else { return nil }
        return ClickDropService.thumbnail(data, maxPixels: maxPixels)
    }

    static func save(_ data: Data, dropID: String, userID: String) {
        try? FileManager.default.createDirectory(at: directory(userID), withIntermediateDirectories: true)
        try? data.write(to: file(dropID, userID: userID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func prune(keeping dropIDs: Set<String>, userID: String) {
        let dir = directory(userID)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where !dropIDs.contains((file as NSString).deletingPathExtension) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
        // Thumbnails from the first version of this cache.
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared-drops"))
    }
}

extension ClickDropService {
    /// The bounded Home strip: your recent shared drops and the ones your connections shared with you.
    public func sharedDrops() async throws -> [SharedDrop] {
        let (data, _) = try await api.executeRaw(APIRequest(path: "/api/me/shared-drops"))
        return JSONFields.rows(try JSONFields.object(data)["drops"]).compactMap(SharedDrop.parse)
    }

    /// Shares one drop; retrying with the same `clientDropID` returns the drop already made.
    public func shareDrop(_ jpeg: Data, audience: SharedDrop.Audience, caption: String?, clientDropID: UUID) async throws -> SharedDrop {
        guard let preview = ClickDropPixelation.previewJPEG(from: jpeg), let image = UIImage(data: jpeg) else {
            throw SharedDropPostError.invalidPhoto
        }
        var body: [String: Any] = [
            "client_drop_id": clientDropID.uuidString.lowercased(),
            "audience": audience.rawValue,
            "mime_type": "image/jpeg",
            "original_b64": jpeg.base64EncodedString(),
            "preview_b64": preview.base64EncodedString(),
            "width": Int(image.size.width * image.scale),
            "height": Int(image.size.height * image.scale)
        ]
        if let caption, !caption.isEmpty { body["caption"] = caption }
        do {
            let (data, _) = try await api.executeRaw(APIRequest(
                path: "/api/me/shared-drops",
                method: .post,
                body: try JSONSerialization.data(withJSONObject: body),
                idempotent: true
            ))
            guard let drop = JSONFields.dictionary(try JSONFields.object(data)["drop"]).flatMap(SharedDrop.parse) else {
                throw APIError.decoding
            }
            return drop
        } catch APIError.conflict {
            throw SharedDropPostError.capReached
        }
    }

    public func deleteSharedDrop(id: String) async throws {
        _ = try await api.executeRaw(APIRequest(path: "/api/me/shared-drops/\(id)", method: .delete, idempotent: true))
    }

    /// A developed original's bytes from its develop-issued signed URL (event and shared drops are
    /// not E2EE: they're multi-recipient and protected by the server's access checks instead).
    public static func loadOriginalData(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw APIError.decoding }
        return data
    }

    public static func loadOriginal(_ url: URL, maxPixels: CGFloat = 1600) async throws -> UIImage {
        guard let image = thumbnail(try await loadOriginalData(url), maxPixels: maxPixels) else { throw APIError.decoding }
        return image
    }

    public nonisolated static func thumbnail(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixels / max(image.size.width, image.size.height))
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }
}
