import Foundation

/// A song identified from a streaming link: name, artist, 30 s iTunes preview and artwork.
public struct SoundtrackMatch: Equatable, Sendable {
    public let trackName: String
    public let artistName: String?
    public let previewURL: String?
    public let artworkURL: String?
    /// The song's Apple Music link (search results), posted as the beacon's `music_url`.
    public var link: String? = nil
}

/// Resolves a soundtrack link on the device, mirroring click-web `beaconSoundtrackEnrichment`
/// (oEmbed / iTunes lookup for search terms, then the iTunes Search API). Running it here fills
/// the form before posting (title, artwork, playable preview) and doesn't depend on the
/// server's lookup, which cloud IPs sometimes get throttled on; the server still enriches too.
enum SoundtrackResolver {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    /// Songs matching `term` from the iTunes Search API. It's free and keyless, and each device
    /// calls it directly (its rate limit is per client), so it costs nothing and scales with
    /// users. Only results with a link are returned, since the link is what gets posted.
    static func search(_ term: String, limit: Int = 12) async -> [SoundtrackMatch] {
        let region = Locale.current.region?.identifier ?? ""
        let country = region.count == 2 && region.allSatisfy(\.isLetter) ? region : "US"
        guard let result = await json("https://itunes.apple.com/search?term=\(encoded(term))&entity=song&limit=\(limit)&country=\(country)"),
              let rows = result["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap(match).filter { $0.link != nil }
    }

    static func resolve(_ link: String) async -> SoundtrackMatch? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BeaconFormRules.isMusicLink(trimmed), let url = URL(string: trimmed) else { return nil }
        let host = url.host?.lowercased() ?? ""
        var terms: [String] = []
        // When the iTunes catalog has no match, the service's own title and cover still make a
        // recognizable soundtrack (no 30 s preview).
        var fallback: SoundtrackMatch?
        func remember(title: String?, thumbnail: Any?) {
            guard fallback == nil, let title = title.map(cleaned), title.count >= 2 else { return }
            let art = (thumbnail as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0.absoluteString : nil }
            fallback = SoundtrackMatch(trackName: title, artistName: nil, previewURL: nil, artworkURL: art ?? linkThumbnail(trimmed))
        }
        func push(_ term: String?) {
            guard let term = term?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces), term.count >= 2 else { return }
            for candidate in [term, cleaned(term)] where candidate.count >= 2 && !terms.contains(candidate) {
                terms.append(candidate)
            }
        }

        if host.hasSuffix("apple.com"), let id = appleCatalogID(url),
           let lookup = await json("https://itunes.apple.com/lookup?id=\(id)&entity=song"),
           let row = (lookup["results"] as? [[String: Any]])?.first(where: { $0["trackName"] is String }),
           let match = match(from: row) {
            return match   // exact catalog hit, no search needed
        }
        if host.contains("spotify") {
            let oembed = await json("https://open.spotify.com/oembed?url=\(encoded(trimmed))")
            push((oembed?["title"] as? String).map(spotifyTerm))
            remember(title: (oembed?["title"] as? String).map(spotifySongTitle), thumbnail: oembed?["thumbnail_url"])
        }
        if host.contains("youtu") {
            let watch = youtubeWatchURL(url) ?? trimmed
            if let oembed = await json("https://www.youtube.com/oembed?format=json&url=\(encoded(watch))"),
               let title = oembed["title"] as? String {
                let author = (oembed["author_name"] as? String)?
                    .replacingOccurrences(of: "\\s*-\\s*topic\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
                if let author, author.count > 1, !title.localizedCaseInsensitiveContains(author) {
                    push("\(author) \(title)")
                }
                push(title.replacingOccurrences(of: " - ", with: " "))
                remember(title: title, thumbnail: oembed["thumbnail_url"])
            }
        }
        if host.hasSuffix("apple.com"), let oembed = await json("https://embed.music.apple.com/oembed?url=\(encoded(trimmed))") {
            push(oembed["title"] as? String)
            remember(title: oembed["title"] as? String, thumbnail: oembed["thumbnail_url"])
        }

        for term in terms.prefix(4) {
            guard let search = await json("https://itunes.apple.com/search?term=\(encoded(term))&entity=song&limit=10"),
                  let rows = search["results"] as? [[String: Any]] else { continue }
            let preferred = rows.first { ($0["previewUrl"] as? String)?.isEmpty == false } ?? rows.first
            if let preferred, let match = match(from: preferred) { return match }
        }
        return fallback
    }

    /// Cover image derivable from the link alone (YouTube's video thumbnail), for soundtracks
    /// saved without album art.
    static func linkThumbnail(_ link: String?) -> String? {
        guard let link, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let id = youtubeVideoID(url) else { return nil }
        return "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }

    // MARK: Artwork and trusted hosts

    /// iTunes artwork comes as 100×100; the same path serves any size.
    static func artwork(_ raw: String?, size: Int = 600) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: #"/\d+x\d+(bb)?\.(jpg|png|webp)$"#, with: "/\(size)x\(size)bb.jpg", options: .regularExpression)
    }

    /// Only Apple's preview CDN is played (the URL comes from another user's beacon).
    static func isTrustedPreview(_ raw: String?) -> Bool {
        guard let raw, let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".apple.com") || host.hasSuffix(".mzstatic.com")
    }

    // MARK: Private

    private static func match(from row: [String: Any]) -> SoundtrackMatch? {
        guard let name = (row["trackName"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let preview = row["previewUrl"] as? String
        return SoundtrackMatch(
            trackName: name,
            artistName: row["artistName"] as? String,
            previewURL: isTrustedPreview(preview) ? preview : nil,
            artworkURL: artwork(row["artworkUrl100"] as? String),
            link: appleMusicLink(row["trackViewUrl"] as? String)
        )
    }

    /// The track's `music.apple.com` link without iTunes' affiliate tracking parameter.
    private static func appleMusicLink(_ raw: String?) -> String? {
        guard let raw, var components = URLComponents(string: raw), components.scheme == "https" else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name != "uo" }
        return components.url?.absoluteString
    }

    private static func json(_ string: String) async -> [String: Any]? {
        guard let url = URL(string: string),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func appleCatalogID(_ url: URL) -> String? {
        if let i = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value,
           i.allSatisfy(\.isNumber) { return i }
        return url.pathComponents.last { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) }.map { String($0.dropFirst(2)) }
    }

    private static func youtubeWatchURL(_ url: URL) -> String? {
        youtubeVideoID(url).map { "https://www.youtube.com/watch?v=\($0)" }
    }

    private static func youtubeVideoID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("youtu") else { return nil }
        let id = host == "youtu.be"
            ? url.pathComponents.dropFirst().first
            : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    /// "Song - song and lyrics by Artist | Spotify" → "Song".
    private static func spotifySongTitle(_ title: String) -> String {
        let t = title.replacingOccurrences(of: #"\s*\|\s*spotify\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.components(separatedBy: " - song").first ?? t
    }

    /// "Song - song and lyrics by Artist | Spotify" → "Artist Song".
    private static func spotifyTerm(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"\s*\|\s*spotify\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s*-\s*song and lyrics by\s+"#, with: " by ", options: [.regularExpression, .caseInsensitive])
        if let range = t.range(of: " by ", options: .caseInsensitive) {
            return "\(t[range.upperBound...]) \(t[..<range.lowerBound])"
        }
        return t
    }

    /// Drops "(Official Video)", "[Remastered]", "- Topic" noise.
    private static func cleaned(_ term: String) -> String {
        term.replacingOccurrences(of: #"\s*[\(\[](official|lyric|lyrics|audio|video|visualizer|remaster|live|feat|ft)[^\)\]]*[\)\]]"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
}
