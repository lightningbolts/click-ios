import Foundation
import Observation

/// What the App Clip was opened for, parsed from the invocation URL (QR code, NFC tag, App Clip
/// Code, Safari banner or Messages link). Mirrors the full app's universal-link paths.
enum ClipDestination: Equatable {
    case connect(userID: String)
    case event(beaconID: String)
    case place(slug: String)
    case home

    init(url: URL?) {
        let parts = url?.pathComponents.filter { $0 != "/" } ?? []
        guard parts.count > 1 else { self = .home; return }
        switch parts[0] {
        case "c", "connect": self = .connect(userID: parts[1])
        case "e": self = .event(beaconID: parts[1])
        case "p": self = .place(slug: parts[1])
        default: self = .home
        }
    }
}

/// `GET /api/users/{id}/public-profile`: the unauthenticated preview fields only.
struct ClipProfile: Decodable, Equatable {
    let displayName: String
    let avatarURL: URL?
    let auraColors: [String]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name", avatarURL = "avatar_url", auraColors = "aura_colors"
    }

    var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }
}

/// `GET /api/beacons/{id}/public`: the share-landing subset.
struct ClipEvent: Decodable, Equatable {
    let title: String?
    let description: String?
    let imageURL: URL?
    let hostName: String?
    let hostAvatarURL: URL?
    let startsAt: Date?
    let endsAt: Date?
    let locationName: String?
    let latitude: Double?
    let longitude: Double?
    let rsvpCount: Int?

    enum CodingKeys: String, CodingKey {
        case title, description, latitude, longitude
        case imageURL = "image_url", hostName = "host_name", hostAvatarURL = "host_avatar_url"
        case startsAt = "event_start_at", endsAt = "event_end_at", locationName = "location_name"
        case rsvpCount = "rsvp_count"
    }

    /// Quick events carry their text in the description only.
    var displayTitle: String {
        [title, description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Click event"
    }

    var directionsURL: URL? {
        guard let latitude, let longitude else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: locationName ?? displayTitle)
        ]
        return components?.url
    }
}

@MainActor
@Observable
final class ClipModel {
    enum Load<Value: Equatable>: Equatable {
        case loading, loaded(Value), failed
    }

    private(set) var destination: ClipDestination = .home
    private(set) var profile: Load<ClipProfile> = .loading
    private(set) var event: Load<ClipEvent> = .loading

    private static let baseURL = URL(string: "https://joinclick.co")!

    func open(_ url: URL?) async {
        let next = ClipDestination(url: url)
        guard next != destination || next == .home else { return }
        destination = next
        switch next {
        case .connect(let userID):
            profile = .loading
            profile = await fetch(ClipProfile.self, path: "api/users/\(userID)/public-profile")
        case .event(let beaconID):
            event = .loading
            event = await fetch(ClipEvent.self, path: "api/beacons/\(beaconID)/public")
        case .place, .home:
            break
        }
    }

    private func fetch<Value: Decodable & Equatable>(_ type: Value.Type, path: String) async -> Load<Value> {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else { return .failed }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let raw = try decoder.singleValueContainer().decode(String.self)
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
            }
            return .loaded(try decoder.decode(Value.self, from: data))
        } catch {
            return .failed
        }
    }
}
