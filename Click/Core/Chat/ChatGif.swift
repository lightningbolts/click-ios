import Foundation

/// A GIF sent from the KLIPY picker. Contract shared with click-web `lib/chat/gif.ts`:
///
/// - `message_type: text`; the (encrypted) content is the KLIPY media URL, so the server never
///   learns which GIF was sent and clients without GIF support still show a link.
/// - `metadata.gif = { provider: "klipy", width, height }`: layout hints only, no URL or slug.
///
/// KLIPY's terms require media to load straight from the URL its API returned (no re-hosting),
/// so GIFs are never uploaded to chat storage.
public struct ChatGif: Hashable, Sendable, Codable {
    public let url: URL
    public let width: Int
    public let height: Int

    public static let provider = "klipy"
    static let metadataKey = "gif"

    public init(url: URL, width: Int, height: Int) {
        self.url = url
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }

    /// The message text: the media URL.
    public var content: String { url.absoluteString }

    var wire: [String: Any] { ["provider": Self.provider, "width": width, "height": height] }

    /// KLIPY serves media from `static.klipy.com` and numbered shards (`static1`, `static2`, …).
    public static func isKlipyMediaURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host.wholeMatch(of: /static\d*\.klipy\.com/) != nil
    }

    /// The GIF a decrypted message carries. Needs both the metadata marker and a KLIPY URL body,
    /// so a GIF bubble can never be pointed at an arbitrary host.
    static func parse(messageType: String, metadata: [String: Any]?, content: String) -> ChatGif? {
        guard messageType.lowercased() == "text",
              let gif = metadata?[metadataKey] as? [String: Any],
              JSONFields.string(gif["provider"]) == provider,
              let width = JSONFields.int(gif["width"]), width > 0,
              let height = JSONFields.int(gif["height"]), height > 0 else { return nil }
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isKlipyMediaURL(body), let url = URL(string: body) else { return nil }
        return ChatGif(url: url, width: width, height: height)
    }

    /// Inbox / reply label for decrypted text that is only a GIF URL.
    static func previewLabel(for text: String) -> String? {
        isKlipyMediaURL(text) ? "GIF" : nil
    }
}
