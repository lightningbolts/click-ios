import Foundation

/// Pre-flight checks that mirror the server's limits (`/api/chat/media`, `/api/chat/attachments`)
/// so an oversized or disallowed attachment is rejected with a clear message before any
/// encryption or upload work starts.
public enum MediaValidator {
    public enum Rejection: Error, Equatable, LocalizedError, Sendable {
        case tooLarge(limitMB: Int)
        case typeNotAllowed
        case empty

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let limit): "This is too large to send. The limit is \(limit) MB."
            case .typeNotAllowed: "This type of file can't be sent in chat."
            case .empty: "This file is empty."
            }
        }
    }

    /// MIME types `/api/chat/media` accepts (images and voice notes).
    public static let allowedMediaMIMEs: Set<String> = [
        "image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/heif",
        "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/mpeg", "audio/wav",
        "audio/x-wav", "audio/ogg", "audio/webm"
    ]

    public nonisolated static func validate(_ draft: MediaDraft) -> Rejection? {
        guard !draft.data.isEmpty else { return .empty }
        let mime = draft.mimeType.lowercased()
        switch draft.kind {
        case .file:
            guard MediaDraft.allowedFileMIMEs.contains(mime) else { return .typeNotAllowed }
            guard draft.data.count <= MediaDraft.maxFileBytes else { return .tooLarge(limitMB: MediaDraft.maxFileBytes / 1_048_576) }
        case .image, .audio:
            guard allowedMediaMIMEs.contains(mime) else { return .typeNotAllowed }
            guard draft.data.count <= MediaDraft.maxMediaBytes else { return .tooLarge(limitMB: MediaDraft.maxMediaBytes / 1_048_576) }
        }
        return nil
    }
}

/// Upload stage shown over an outgoing attachment bubble.
public enum MediaUploadProgress: Hashable, Sendable {
    case encrypting
    case uploading(fraction: Double)
}
