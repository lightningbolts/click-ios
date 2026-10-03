import CoreLocation
import Foundation

/// Errors from the Places API, keyed on the server's `code` (§5.4–§5.5). The API client drops
/// response bodies for 403/404/429, so those map by status in the context of the call.
public enum PlaceError: Error, Equatable, Sendable {
    case notFound
    case noLocation
    case lowAccuracy
    case outOfBounds(distance: Double?)
    case invalidAnchor
    case notPresent
    case cooldown(until: Date?)
    case managerPulseNotAllowed
    case emptyPulse
    case notEditable
    case network

    /// §6.7 copy.
    public var message: String {
        switch self {
        case .noLocation: "Turn on location to check in."
        case .lowAccuracy: "We couldn't get a precise location. Step outside or near a window and try again."
        case .outOfBounds(let distance): Self.outOfBoundsCopy(distance)
        case .invalidAnchor: "This code is no longer active. Ask staff for the current one."
        case .notFound: "This Place isn't available."
        case .notPresent: "Check in here to share the Pulse."
        case .cooldown: "You can update your Pulse a little later."
        case .managerPulseNotAllowed: "You manage this Place, so you can't Pulse it."
        default: "Something went wrong. Try again."
        }
    }

    /// "You're about {d rounded to 50 m / 0.1 mi} away."
    static func outOfBoundsCopy(_ distance: Double?) -> String {
        guard let distance, distance.isFinite, distance > 0 else { return "You're not here yet. Check in when you're here." }
        let usesMetric = Locale.current.measurementSystem == .metric
        let away: String
        if usesMetric {
            let rounded = max(50, (distance / 50).rounded() * 50)
            away = rounded >= 1000 ? String(format: "%.1f km", rounded / 1000) : "\(Int(rounded)) m"
        } else {
            let miles = max(0.1, (distance / 1609.344 * 10).rounded() / 10)
            away = String(format: "%.1f mi", miles)
        }
        return "You're about \(away) away. Check in when you're here."
    }

    /// 400/422 bodies arrive as the validation message: `{ "error", "code", "distance_meters"? }`.
    static func fromValidation(_ message: String?) -> PlaceError? {
        guard let message, let data = message.data(using: .utf8),
              let body = try? JSONFields.object(data), let code = JSONFields.string(body["code"]) else { return nil }
        switch code {
        case "no_location": return .noLocation
        case "low_accuracy": return .lowAccuracy
        case "out_of_bounds": return .outOfBounds(distance: JSONFields.double(body["distance_meters"]))
        case "invalid_anchor": return .invalidAnchor
        case "empty_pulse": return .emptyPulse
        case "place_not_found": return .notFound
        default: return nil
        }
    }

    static func map(_ error: Error, forbidden: PlaceError) -> Error {
        if error.isCancellation { return error }
        switch error as? APIError {
        case .validation(_, let message): return fromValidation(message) ?? PlaceError.network
        case .notFound: return PlaceError.notFound
        case .forbidden: return forbidden
        case .rateLimited: return PlaceError.cooldown(until: nil)
        case .conflict: return PlaceError.notEditable
        case .some: return PlaceError.network
        case nil: return error
        }
    }
}

/// The Places API surface, so screens can be tested with a stub.
public protocol PlaceRepositoryProtocol: Sendable {
    func nearby(around: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [PlaceSummary]
    func detail(idOrSlug: String, source: String?) async throws -> PlaceDetail
    func checkIn(placeID: String, coordinate: CLLocationCoordinate2D?, accuracy: Double?, anchorToken: String?, shareWithConnections: Bool) async throws -> PlaceCheckInState
    func checkInStatus(placeID: String) async throws -> PlaceCheckInState?
    func checkOut(placeID: String) async throws -> Bool
    func submitPulse(placeID: String, energy: Int?, talkable: Int?, categoryAnswer: Int?, wouldReturn: Int?) async throws -> (pulseID: String, editableUntil: Date?, summary: PulseSummary)
    func updatePulse(placeID: String, pulseID: String, talkable: Int?, categoryAnswer: Int?) async throws -> PulseSummary
    func myPlaces() async throws -> [MyPlaceVisit]
    /// The last detail loaded this session for this ID or slug, so a Place reopens filled.
    func cachedDetail(idOrSlug: String) async -> PlaceDetail?
}

extension PlaceRepositoryProtocol {
    public func cachedDetail(idOrSlug: String) async -> PlaceDetail? { nil }

    public func detail(idOrSlug: String) async throws -> PlaceDetail {
        try await detail(idOrSlug: idOrSlug, source: nil)
    }
}

/// Click Places reads and writes (`/api/places/*`, `/api/me/places`). Location is passed in once
/// per action by the caller; nothing here reads location or runs in the background.
public actor PlaceRepository: PlaceRepositoryProtocol {
    private let api: ClickAPIClient
    /// Details seen this session, by the key they were opened with, their ID and their slug.
    private var details: [String: PlaceDetail] = [:]

    public init(api: ClickAPIClient) {
        self.api = api
    }

    private func path(_ idOrSlug: String) -> String {
        "/api/places/\(idOrSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? idOrSlug)"
    }

    private func object(_ request: APIRequest, forbidden: PlaceError = .notPresent) async throws -> [String: Any] {
        do {
            let (data, _) = try await api.executeRaw(request)
            return try JSONFields.object(data)
        } catch {
            throw PlaceError.map(error, forbidden: forbidden)
        }
    }

    private func json(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body)
    }

    /// Filtering is client-side (§6.6), so no filter params are sent.
    public func nearby(around: CLLocationCoordinate2D, radiusMeters: Int) async throws -> [PlaceSummary] {
        let root = try await object(APIRequest(path: "/api/places/nearby", queryItems: [
            URLQueryItem(name: "lat", value: String(around.latitude)),
            URLQueryItem(name: "lon", value: String(around.longitude)),
            URLQueryItem(name: "radius_meters", value: String(radiusMeters))
        ]))
        return JSONFields.rows(root["places"]).compactMap(PlaceSummary.decode)
    }

    public func detail(idOrSlug: String, source: String?) async throws -> PlaceDetail {
        let query = source.map { [URLQueryItem(name: "source", value: $0)] } ?? []
        let root = try await object(APIRequest(path: path(idOrSlug), queryItems: query))
        guard let detail = PlaceDetail.decode(JSONFields.dictionary(root["place"])) else { throw PlaceError.network }
        for key in [idOrSlug, detail.summary.id, detail.summary.slug] { details[key] = detail }
        return detail
    }

    public func cachedDetail(idOrSlug: String) async -> PlaceDetail? { details[idOrSlug] }

    /// On sign-out: nothing from one account paints for the next.
    public func clearCache() { details.removeAll() }

    public func checkIn(
        placeID: String,
        coordinate: CLLocationCoordinate2D?,
        accuracy: Double?,
        anchorToken: String?,
        shareWithConnections: Bool
    ) async throws -> PlaceCheckInState {
        var body: [String: Any] = ["share_with_connections": shareWithConnections, "platform": "ios"]
        if let coordinate {
            body["latitude"] = coordinate.latitude
            body["longitude"] = coordinate.longitude
        }
        if let accuracy { body["accuracy_meters"] = accuracy }
        if let anchorToken { body["anchor_token"] = anchorToken }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            body["app_version"] = version
        }
        let root = try await object(APIRequest(path: path(placeID) + "/check-in", method: .post, body: try json(body)))
        guard let state = PlaceCheckInState.decode(root) else { throw PlaceError.network }
        return state
    }

    public func checkInStatus(placeID: String) async throws -> PlaceCheckInState? {
        PlaceCheckInState.decode(try await object(APIRequest(path: path(placeID) + "/check-in")))
    }

    /// Returns whether to ask "Come back at this time?".
    public func checkOut(placeID: String) async throws -> Bool {
        let root = try await object(APIRequest(path: path(placeID) + "/check-in", method: .delete, idempotent: true))
        return JSONFields.bool(root["ask_would_return"]) ?? false
    }

    public func submitPulse(
        placeID: String,
        energy: Int?,
        talkable: Int?,
        categoryAnswer: Int?,
        wouldReturn: Int?
    ) async throws -> (pulseID: String, editableUntil: Date?, summary: PulseSummary) {
        var body: [String: Any] = ["question_version": 1]
        if let energy { body["energy"] = energy }
        if let talkable { body["talkable"] = talkable }
        if let categoryAnswer { body["category_answer"] = categoryAnswer }
        if let wouldReturn { body["would_return"] = wouldReturn }
        let root = try await object(APIRequest(path: path(placeID) + "/pulse", method: .post, body: try json(body)))
        let pulse = JSONFields.dictionary(root["pulse"]) ?? [:]
        guard let id = JSONFields.string(pulse["id"]) else { throw PlaceError.network }
        return (id, JSONFields.date(pulse["editable_until"]), PulseSummary.decode(JSONFields.dictionary(root["summary"])))
    }

    public func updatePulse(placeID: String, pulseID: String, talkable: Int?, categoryAnswer: Int?) async throws -> PulseSummary {
        var body: [String: Any] = [:]
        if let talkable { body["talkable"] = talkable }
        if let categoryAnswer { body["category_answer"] = categoryAnswer }
        let root = try await object(APIRequest(path: path(placeID) + "/pulse/\(pulseID)", method: .patch, body: try json(body)), forbidden: .notPresent)
        return PulseSummary.decode(JSONFields.dictionary(root["summary"]))
    }

    public func myPlaces() async throws -> [MyPlaceVisit] {
        let root = try await object(APIRequest(path: "/api/me/places"))
        return JSONFields.rows(root["places"]).compactMap(MyPlaceVisit.decode)
    }
}
