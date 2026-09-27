import Foundation
import CryptoKit

/// KLIPY GIF API (https://docs.klipy.com/gifs-api). KLIPY requires requests and media loads to
/// come from the user's device, so this talks to `api.klipy.com` directly with the app key.
/// Mirrors click-web `lib/chat/klipy.ts`.
public struct KlipyClient: Sendable {
    public struct Item: Identifiable, Hashable, Sendable {
        public let id: String
        public let slug: String
        public let title: String
        /// Grid thumbnail.
        public let preview: Rendition
        /// What gets sent: sharp at bubble size without the multi-MB `hd` GIF.
        public let send: Rendition
    }

    public struct Rendition: Hashable, Sendable {
        public let url: URL
        public let width: Int
        public let height: Int
    }

    public struct Page: Sendable {
        public let items: [Item]
        public let page: Int
        public let hasNext: Bool
    }

    public enum Failure: Error, LocalizedError {
        case notConfigured
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "GIF search isn't available."
            case .badResponse: "Couldn't load GIFs. Try again."
            }
        }
    }

    public static var isConfigured: Bool { AppConfig.shared.klipyAppKey != nil }

    private static let base = URL(string: "https://api.klipy.com/api/v1")!
    private static let perPage = 24
    private static let contentFilter = "medium"

    private let appKey: String?
    private let session: URLSession

    public init(appKey: String? = AppConfig.shared.klipyAppKey, session: URLSession = .shared) {
        self.appKey = appKey
        self.session = session
    }

    /// Stable, non-identifying per-user ID for KLIPY personalization (never the raw user ID).
    public static func customerID(userID: String) -> String {
        let digest = SHA256.hash(data: Data("click-klipy:\(userID)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Trending when `query` is blank, else search. Results keep KLIPY's order.
    public func gifs(query: String, page: Int, customerID: String) async throws -> Page {
        guard let appKey else { throw Failure.notConfigured }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = q.isEmpty ? "trending" : "search"
        var components = URLComponents(url: Self.base.appending(path: "\(appKey)/gifs/\(endpoint)"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(Self.perPage)),
            URLQueryItem(name: "customer_id", value: customerID),
            URLQueryItem(name: "content_filter", value: Self.contentFilter),
            URLQueryItem(name: "format_filter", value: "gif,webp")
        ]
        if !q.isEmpty { queryItems.append(URLQueryItem(name: "q", value: q)) }
        if let region = Locale.current.region?.identifier, region.count == 2 {
            queryItems.append(URLQueryItem(name: "locale", value: region.lowercased()))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw Failure.badResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.badResponse }
        return try Self.parsePage(data, requestedPage: page)
    }

    /// Share analytics (improves ranking). Fire-and-forget; never blocks a send.
    public func triggerShare(slug: String, customerID: String, query: String) {
        guard let appKey, !slug.isEmpty else { return }
        var request = URLRequest(url: Self.base.appending(path: "\(appKey)/gifs/share/\(slug)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "customer_id": customerID,
            "q": query.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
        let session = self.session
        Task.detached(priority: .utility) { _ = try? await session.data(for: request) }
    }

    static func parsePage(_ data: Data, requestedPage: Int) throws -> Page {
        let root = try JSONFields.object(data)
        guard let body = JSONFields.dictionary(root["data"]) else { throw Failure.badResponse }
        let items = JSONFields.rows(body["data"]).compactMap(parseItem)
        return Page(items: items,
                    page: JSONFields.int(body["current_page"]) ?? requestedPage,
                    hasNext: JSONFields.bool(body["has_next"]) ?? false)
    }

    static func parseItem(_ row: [String: Any]) -> Item? {
        guard let slug = JSONFields.string(row["slug"]),
              let file = JSONFields.dictionary(row["file"]),
              let preview = rendition(file, sizes: ["sm", "xs", "md"]),
              let send = rendition(file, sizes: ["md", "hd", "sm"]) else { return nil }
        let id = JSONFields.string(row["id"]) ?? JSONFields.int(row["id"]).map(String.init) ?? slug
        return Item(id: id, slug: slug, title: JSONFields.string(row["title"]) ?? "GIF", preview: preview, send: send)
    }

    /// Animated WebP is far smaller than GIF and ImageIO animates both.
    private static func rendition(_ file: [String: Any], sizes: [String]) -> Rendition? {
        for size in sizes {
            guard let formats = JSONFields.dictionary(file[size]) else { continue }
            for format in ["webp", "gif"] {
                guard let r = JSONFields.dictionary(formats[format]),
                      let raw = JSONFields.string(r["url"]), ChatGif.isKlipyMediaURL(raw),
                      let url = URL(string: raw),
                      let width = JSONFields.int(r["width"]), width > 0,
                      let height = JSONFields.int(r["height"]), height > 0 else { continue }
                return Rendition(url: url, width: width, height: height)
            }
        }
        return nil
    }
}
