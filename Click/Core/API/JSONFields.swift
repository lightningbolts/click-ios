import Foundation

/// Lenient field readers for Click BFF payloads whose historical rows use mixed JSON types
/// (numbers as strings, epoch seconds vs. milliseconds, ISO vs. Postgres timestamps).
///
/// Repositories use these to map transport dictionaries into typed domain models; views never
/// see raw dictionaries.
enum JSONFields {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding
        }
        return value
    }

    static func rows(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        // Some historical columns were JSON-encoded as a string, some twice
        // (e.g. `weather_snapshot` written as "\"{...}\"").
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            if let object = parsed as? [String: Any] { return object }
            if let inner = parsed as? String, inner != text { return dictionary(inner) }
        }
        return nil
    }

    /// An encounter place string, without the server's former "no location" placeholder.
    static func place(_ value: Any?) -> String? {
        string(value).flatMap { $0 == "A new city" ? nil : $0 }
    }

    /// A trimmed, non-empty string.
    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first non-empty string among `keys`.
    static func string(_ dictionary: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = string(dictionary[key]) { return value }
        }
        return nil
    }

    static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { string($0) }
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let value = value as? NSNumber { return value.doubleValue.isFinite ? value.doubleValue : nil }
        if let value = value as? String, let parsed = Double(value.trimmingCharacters(in: .whitespaces)) {
            return parsed.isFinite ? parsed : nil
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Parses epoch seconds/milliseconds (number or numeric string), ISO-8601 with or without
    /// fractional seconds, and Postgres `timestamptz` text (`2026-09-22 19:00:00.123+00`).
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            return epoch(number.doubleValue)
        }
        guard let raw = string(value) else { return nil }
        if let numeric = Double(raw) {
            return epoch(numeric)
        }
        return ClickDateParser.parse(raw)
    }

    private static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }
}

/// One parser for every server timestamp shape (spec §78).
enum ClickDateParser {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: iso) { return date }
        if let date = try? Date(text, strategy: isoFractional) { return date }

        // Postgres text form: space separator and an hour-only offset such as `+00`.
        var normalized = text.replacingOccurrences(of: " ", with: "T")
        if let range = normalized.range(of: #"[+-]\d{2}$"#, options: .regularExpression) {
            normalized.replaceSubrange(range, with: normalized[range] + ":00")
        }
        if !normalized.hasSuffix("Z"), normalized.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil {
            normalized += "Z"
        }
        if let date = try? Date(normalized, strategy: iso) { return date }
        return try? Date(normalized, strategy: isoFractional)
    }

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
