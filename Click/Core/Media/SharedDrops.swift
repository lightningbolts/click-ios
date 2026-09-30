import Foundation
import UIKit

/// A shared Click Drop (spec F3): one photo to all your connections or only core ones, developing
/// 24 hours after it's posted. Not end-to-end encrypted like chat drops — only the people it's
/// shared with can see it, and the original stays on the server until it develops.
public struct SharedDrop: Identifiable, Sendable, Equatable {
    public enum Audience: String, Sendable, CaseIterable { case all, core }

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
            caption: JSONFields.string(row["caption"]).flatMap { $0.isEmpty ? nil : $0 }
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
