import Foundation

/// Media carried by a chat message (spec §37). Built from the server metadata plus the
/// decrypted body (file descriptors travel inside the encrypted content).
public struct MessageMedia: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case image
        case audio
        case file
    }

    public let kind: Kind
    public let mimeType: String
    public let fileName: String?
    public let sizeBytes: Int?
    public let durationSeconds: Int?
    /// Legacy signed URL (`media_url`); may have expired, in which case the path is re-signed.
    public let remoteURL: String?
    /// Storage object path (`chatId/userId/...`) for signing.
    public let storagePath: String?
    /// E2EE v2 media authorization metadata, when the upload was v2.
    public let v2: ClickCryptoV2.MediaMetadata?
    /// Legacy file master key (base64) and plaintext SHA-256, from a `ccx:v1:` descriptor.
    public let fileKey: String?
    public let plaintextSha256: String?
    public let isDisposable: Bool
    /// Click Drop reveal time (`collaboration_ttl`); the photo stays pixelated until then.
    public var revealAt: Date? = nil
    /// Voice-note amplitude envelope (`metadata.waveform`, 0...1). iOS-written and additive;
    /// clients that don't know it (KMP) ignore it, and bubbles without it draw a flat bar.
    public var waveform: [Double]? = nil

    public func isLocked(now: Date = .now) -> Bool {
        guard isDisposable else { return false }
        return (revealAt ?? .distantFuture) > now
    }

    public var displayName: String {
        if let fileName, !fileName.isEmpty { return fileName }
        switch kind {
        case .image: return "Photo"
        case .audio: return "Voice note"
        case .file: return "File"
        }
    }

    public var fileExtension: String {
        if let fileName, let ext = fileName.split(separator: ".").last, fileName.contains("."), ext.count <= 5 {
            return String(ext).lowercased()
        }
        return Self.fileExtension(forMIME: mimeType)
    }

    static func fileExtension(forMIME mime: String) -> String {
        let m = mime.lowercased()
        if m.contains("jpeg") || m.contains("jpg") { return "jpg" }
        if m.contains("png") { return "png" }
        if m.contains("heic") { return "heic" }
        if m.contains("gif") { return "gif" }
        if m.contains("webp") { return "webp" }
        if m.contains("m4a") || m.contains("mp4") || m.contains("aac") { return "m4a" }
        if m.contains("mpeg") || m.contains("mp3") { return "mp3" }
        if m.contains("wav") { return "wav" }
        if m.contains("pdf") { return "pdf" }
        if m.contains("zip") { return "zip" }
        if m.contains("csv") { return "csv" }
        if m.contains("plain") { return "txt" }
        if m.contains("quicktime") { return "mov" }
        if m.contains("wordprocessingml") { return "docx" }
        return "bin"
    }

    /// Parses media from a message's type, server metadata, and decrypted content.
    /// Returns nil for non-media messages or media without any retrievable location.
    static func parse(messageType: String, metadata: [String: Any]?, decryptedContent: String, chatID: String) -> MessageMedia? {
        let type = messageType.lowercased()
        let meta = metadata ?? [:]
        let v2 = v2Metadata(meta, chatID: chatID)
        let v2Path = JSONFields.string(meta, "media_path", "mediaPath")
        switch type {
        case "image", "photo", "audio", "voice", "voice_note":
            let url = JSONFields.string(meta, "media_url", "mediaUrl")
            // Hub photos store only a path in the `hub-media` bucket (signed on demand).
            let isHubPath = v2Path != nil && JSONFields.string(meta["media_bucket"]) == "hub-media"
            guard url != nil || (v2 != nil && v2Path != nil) || isHubPath else { return nil }
            let isImage = type == "image" || type == "photo"
            return MessageMedia(
                kind: isImage ? .image : .audio,
                mimeType: JSONFields.string(meta, "original_mime_type", "mime_type") ?? (isImage ? "image/jpeg" : "audio/mp4"),
                fileName: nil,
                sizeBytes: nil,
                durationSeconds: JSONFields.int(meta["duration_seconds"]),
                remoteURL: url,
                storagePath: v2Path ?? url.flatMap(Self.storagePath(fromSignedURL:)),
                v2: v2,
                fileKey: nil,
                plaintextSha256: nil,
                isDisposable: JSONFields.bool(meta["disposable_roll"]) ?? false,
                revealAt: JSONFields.date(meta["collaboration_ttl"]),
                waveform: isImage ? nil : VoiceWaveform.parse(meta["waveform"])
            )
        case "file", "document":
            let descriptor = AttachmentEnvelope.decode(decryptedContent)
            let path = v2Path ?? descriptor?.path ?? JSONFields.string(meta, "attachment_path", "path", "storage_path", "object_path")
            guard let path else { return nil }
            return MessageMedia(
                kind: .file,
                mimeType: JSONFields.string(meta, "attachment_mime", "mime_type", "content_type") ?? descriptor?.mime ?? "application/octet-stream",
                fileName: JSONFields.string(meta, "attachment_name", "file_name", "filename", "name") ?? descriptor?.name,
                sizeBytes: JSONFields.int(meta["attachment_size"]) ?? JSONFields.int(meta["file_size"]) ?? descriptor?.size,
                durationSeconds: nil,
                remoteURL: nil,
                storagePath: path,
                v2: v2,
                fileKey: descriptor?.key ?? JSONFields.string(meta, "file_key", "file_master_key"),
                plaintextSha256: descriptor?.sha256,
                isDisposable: false
            )
        default:
            return nil
        }
    }

    static func v2Metadata(_ meta: [String: Any], chatID: String) -> ClickCryptoV2.MediaMetadata? {
        guard
            let digest = JSONFields.string(meta, "media_ciphertext_sha256", "mediaCiphertextSha256"),
            let epoch = JSONFields.int(meta["media_epoch"]) ?? JSONFields.int(meta["mediaEpoch"]) ?? JSONFields.int(meta["epoch"]),
            let device = JSONFields.string(meta, "media_sender_device_id", "mediaSenderDeviceId", "sender_device_id", "senderDeviceId"),
            let client = JSONFields.string(meta, "media_client_message_id", "mediaClientMessageId", "client_message_id", "clientMessageId")
        else { return nil }
        return ClickCryptoV2.MediaMetadata(
            chatId: JSONFields.string(meta, "media_chat_id", "mediaChatId") ?? chatID,
            epoch: epoch,
            senderDeviceId: device,
            clientMessageId: client,
            mediaCiphertextSha256: digest
        )
    }

    /// `.../storage/v1/object/sign/chat-attachments/<path>?token=...` → `<path>`.
    static func storagePath(fromSignedURL url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        let marker = "/chat-attachments/"
        guard let range = components.path.range(of: marker) else { return nil }
        let path = String(components.path[range.upperBound...]).removingPercentEncoding ?? ""
        return path.isEmpty || path.hasPrefix("/") || path.contains("..") ? nil : path
    }
}

/// Encrypted-attachment descriptors carried inside the (encrypted) message body
/// (KMP `AttachmentCrypto`: `ccx:v1:` with a per-file key, `ccx:v2:` for v2 uploads).
public struct AttachmentEnvelope: Equatable, Sendable {
    public static let v1Prefix = "ccx:v1:"
    public static let v2Prefix = "ccx:v2:"

    public let version: Int
    public let name: String
    public let mime: String
    public let size: Int
    public let path: String
    /// v1 only: base64 32-byte file master key.
    public let key: String?
    /// v1: SHA-256 of the plaintext; v2: SHA-256 of the uploaded ciphertext.
    public let sha256: String

    public static func decode(_ content: String) -> AttachmentEnvelope? {
        let version: Int
        let body: String
        if content.hasPrefix(v1Prefix) {
            version = 1
            body = String(content.dropFirst(v1Prefix.count))
        } else if content.hasPrefix(v2Prefix) {
            version = 2
            body = String(content.dropFirst(v2Prefix.count))
        } else {
            return nil
        }
        guard
            let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
            let name = JSONFields.string(root["name"]),
            let mime = JSONFields.string(root["mime"]),
            let path = JSONFields.string(root["path"]),
            !path.hasPrefix("/"), !path.contains("..")
        else { return nil }
        let sha = version == 2 ? JSONFields.string(root["mediaCiphertextSha256"]) : JSONFields.string(root["sha256"])
        guard let sha else { return nil }
        let key = JSONFields.string(root["key"])
        if version == 1, key == nil { return nil }
        return AttachmentEnvelope(
            version: version,
            name: name,
            mime: mime,
            size: JSONFields.int(root["size"]) ?? 0,
            path: path,
            key: version == 1 ? key : nil,
            sha256: sha
        )
    }

    public func encoded() throws -> String {
        var root: [String: Any] = ["v": version, "type": "file", "name": name, "mime": mime, "size": size, "path": path]
        if version == 2 {
            root["mediaCiphertextSha256"] = sha256
        } else {
            root["key"] = key ?? ""
            root["sha256"] = sha256
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        return (version == 2 ? Self.v2Prefix : Self.v1Prefix) + String(decoding: data, as: UTF8.self)
    }
}

/// Media picked or recorded for sending.
public struct MediaDraft: Sendable {
    public let kind: MessageMedia.Kind
    public let data: Data
    public let mimeType: String
    public let fileName: String?
    public let durationSeconds: Int?
    /// Voice-note envelope written to `metadata.waveform`.
    public var waveform: [Double]?
    /// A Click Drop photo: revealed to everyone 24 hours after it is taken.
    public var isClickDrop = false
    /// The in-person encounter a Click Drop belongs to (`metadata.encounter_id`), when one is active.
    public var encounterID: String?
    /// Re-sent from another chat (`metadata.forwarded`).
    public var isForwarded = false

    public init(kind: MessageMedia.Kind, data: Data, mimeType: String, fileName: String? = nil, durationSeconds: Int? = nil) {
        self.kind = kind
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.durationSeconds = durationSeconds
    }

    /// Server limits: `/api/chat/media` 25 MiB, `/api/chat/attachments` 2 MiB plaintext.
    public static let maxMediaBytes = 25 * 1024 * 1024
    public static let maxFileBytes = 2 * 1024 * 1024

    /// MIME types `/api/chat/attachments` accepts.
    public static let allowedFileMIMEs: Set<String> = [
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/plain", "image/png", "image/jpeg", "video/quicktime", "video/mp4",
        "application/zip", "application/x-zip-compressed", "text/csv", "application/csv"
    ]
}

/// Decrypted media on disk, keyed by message ID, so cells never re-download or re-decrypt on
/// scroll (spec §37.3). Lives in Caches with complete file protection; the OS may purge it.
public actor ChatMediaVault {
    public static let shared = ChatMediaVault()

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChatMedia", isDirectory: true)
    }()

    public func cachedURL(messageID: String, fileExtension: String) -> URL? {
        let url = fileURL(messageID: messageID, fileExtension: fileExtension)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func store(_ data: Data, messageID: String, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(messageID: messageID, fileExtension: fileExtension)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Removes every decrypted file (sign-out).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(messageID: String, fileExtension: String) -> URL {
        let safe = messageID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("\(safe).\(fileExtension)")
    }
}

/// Voice-note waveform helpers (40 bins, 0...1).
public enum VoiceWaveform {
    public static let binCount = 40
    public static let floor = 0.06

    /// Averages raw meter levels into `count` bins normalized to the loudest bin.
    public nonisolated static func bins(from levels: [Double], count: Int = binCount) -> [Double] {
        guard !levels.isEmpty, count > 0 else { return Array(repeating: floor, count: count) }
        var result: [Double] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            let slice = levels[min(start, levels.count - 1)..<min(end, levels.count)]
            result.append(slice.reduce(0, +) / Double(slice.count))
        }
        let peak = result.max() ?? 0
        guard peak > 0 else { return Array(repeating: floor, count: count) }
        return result.map { max(floor, min(1, $0 / peak)) }
    }

    /// Linear amplitude (0...1) from an `AVAudioRecorder` average power in dBFS.
    public nonisolated static func amplitude(fromDecibels power: Float) -> Double {
        guard power.isFinite else { return 0 }
        return Double(min(1, max(0, pow(10, power / 20))))
    }

    static func parse(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        let numbers = array.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard !numbers.isEmpty, numbers.count == array.count else { return nil }
        return numbers.map { min(1, max(0, $0)) }
    }

    /// Rounded for the wire (two decimals keeps metadata small).
    static func wire(_ bins: [Double]) -> [Double] {
        bins.map { ($0 * 100).rounded() / 100 }
    }
}
