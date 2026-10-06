import Foundation

/// Weather at an event's location (`GET /api/geo/weather`): right now, and for an event up to a
/// week out, the forecast for the hour it starts.
public struct PlaceWeather: Equatable, Sendable {
    public struct Reading: Equatable, Sendable {
        public let temperatureCelsius: Double
        public let condition: String
        /// Server icon key: clear, cloudy, fog, drizzle, rain, snow, thunder.
        public let icon: String
        public let isDay: Bool
        public let precipitationChance: Int?

        public var systemImage: String {
            switch icon {
            case "cloudy": isDay ? "cloud.sun.fill" : "cloud.moon.fill"
            case "fog": "cloud.fog.fill"
            case "drizzle": "cloud.drizzle.fill"
            case "rain": "cloud.rain.fill"
            case "snow": "cloud.snow.fill"
            case "thunder": "cloud.bolt.rain.fill"
            default: isDay ? "sun.max.fill" : "moon.stars.fill"
            }
        }

        /// "64°" / "18°" in the reader's own unit.
        public var temperature: String {
            Measurement(value: temperatureCelsius, unit: UnitTemperature.celsius)
                .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
        }

        static func decode(_ row: [String: Any]?) -> Reading? {
            guard let row, let temperature = JSONFields.double(row["temperature_c"]) else { return nil }
            return Reading(
                temperatureCelsius: temperature,
                condition: JSONFields.string(row["condition"]) ?? "Clear",
                icon: JSONFields.string(row["icon"]) ?? "clear",
                isDay: JSONFields.bool(row["is_day"]) ?? true,
                precipitationChance: JSONFields.int(row["precipitation_probability"])
            )
        }
    }

    public let now: Reading?
    public let atStart: Reading?

    /// "64° Cloudy now · 58° Rain at 7 PM, 70% chance": now first (what it's like there), then
    /// the start-time forecast when there is one.
    public func summary(start: Date?) -> String? {
        var parts: [String] = []
        if let now { parts.append("\(now.temperature) \(now.condition) now") }
        if let atStart, let start {
            var line = "\(atStart.temperature) \(atStart.condition) at \(start.formatted(date: .omitted, time: .shortened))"
            if let chance = atStart.precipitationChance, chance >= 30 { line += ", \(chance)% chance of rain" }
            parts.append(line)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The symbol for the reading that matters most: the start forecast when there is one.
    public var systemImage: String? { (atStart ?? now)?.systemImage }
}

/// Session cache in front of the weather route: the same event reopened within 10 minutes (or
/// another event at the same spot and hour) reuses the answer.
@MainActor
final class WeatherStore {
    static let shared = WeatherStore()

    private var entries: [String: (weather: PlaceWeather, at: Date)] = [:]
    private static let freshFor: TimeInterval = 600

    func cached(latitude: Double, longitude: Double, start: Date?) -> PlaceWeather? {
        entries[Self.key(latitude, longitude, start)].flatMap { Date().timeIntervalSince($0.at) < Self.freshFor ? $0.weather : nil }
    }

    func weather(latitude: Double, longitude: Double, start: Date?, api: ClickAPIClient) async -> PlaceWeather? {
        if let cached = cached(latitude: latitude, longitude: longitude, start: start) { return cached }
        var query = [URLQueryItem(name: "lat", value: String(latitude)), URLQueryItem(name: "lng", value: String(longitude))]
        if let start, start > .now { query.append(URLQueryItem(name: "at", value: ISO8601DateFormatter().string(from: start))) }
        guard let response = try? await api.executeRaw(APIRequest(path: "/api/geo/weather", queryItems: query, requiresAuth: false)),
              let root = try? JSONFields.object(response.0) else { return nil }
        let weather = PlaceWeather(now: .decode(JSONFields.dictionary(root["now"])), atStart: .decode(JSONFields.dictionary(root["at"])))
        guard weather.now != nil || weather.atStart != nil else { return nil }
        entries[Self.key(latitude, longitude, start)] = (weather, Date())
        return weather
    }

    private static func key(_ latitude: Double, _ longitude: Double, _ start: Date?) -> String {
        let hour = start.map { Int($0.timeIntervalSince1970 / 3600) } ?? 0
        return String(format: "%.3f,%.3f,%d", latitude, longitude, hour)
    }
}
