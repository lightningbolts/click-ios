import Foundation

/// Shared Places copy (click-web spec §4.11). Mirrors web `lib/places/labels.ts`; keep them
/// identical. No thresholds: one report reads "1 report".
enum PlaceCopy {
    static let noPulse = "No Pulse yet — be the first when you're here"

    static func reports(_ n: Int) -> String {
        n == 1 ? "1 report" : "\(n) reports"
    }

    static func age(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }

    /// "Lively · 1 report · 4 min ago" / "Last Pulse: Chill · 3 h ago" / no Pulse.
    static func pulseLine(_ pulse: PulseSummary, now: Date = .now) -> String {
        switch (pulse.state, pulse.label) {
        case (.live, let label?): "\(label.title) · \(reports(pulse.reportCount)) · \(age(pulse.newestAt, now: now))"
        case (.stale, let label?): "Last Pulse: \(label.title) · \(age(pulse.newestAt, now: now))"
        default: noPulse
        }
    }

    /// "1 report · 4 min ago" (the energy pill carries the label).
    static func liveDetail(_ pulse: PulseSummary, now: Date = .now) -> String {
        "\(reports(pulse.reportCount)) · \(age(pulse.newestAt, now: now))"
    }

    static func confidence(_ confidence: PulseSummary.Confidence?) -> String? {
        switch confidence {
        case .high: "Strong read"
        case .medium: "Fair read"
        case .low: "Early read"
        case nil: nil
        }
    }

    static func pattern(_ pattern: PlacePattern) -> String {
        "Usually \(pattern.label.title) around now · \(reports(pattern.reportCount)) over \(pattern.weeks) weeks"
    }

    /// nil hides the row.
    static func hereNow(_ count: Int) -> String? {
        count > 0 ? "\(count) here now" : nil
    }

    /// Short start time for pin badges and subtitles ("8 PM", "8:30 PM").
    static func shortTime(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        return date.formatted(minute == 0 ? .dateTime.hour() : .dateTime.hour().minute())
    }

    /// The map/Nearby subtitle: live Pulse, else next event, else the category.
    static func mapSubtitle(_ place: PlaceSummary, now: Date = .now) -> String {
        if place.pulse.state == .live, let label = place.pulse.label {
            return "\(label.title) · \(reports(place.pulse.reportCount))"
        }
        if let event = place.nextEvent {
            if event.isLive { return "Live: \(event.title)" }
            if let start = event.startsAt {
                let day = Calendar.current.isDateInToday(start) ? "Tonight" : start.formatted(.dateTime.weekday(.abbreviated))
                return "\(day) \(shortTime(start)) · \(event.title)"
            }
        }
        return place.category.label
    }

    /// Pin badge: "LIVE" for a live event, else a start time when there's an event today.
    static func pinBadge(_ place: PlaceSummary) -> String? {
        if place.nextEvent?.isLive == true { return "LIVE" }
        if place.eventsTodayCount > 0, let start = place.nextEvent?.startsAt { return shortTime(start) }
        return nil
    }

    /// "Maya, Jordan and 1 other" (names arrive sorted by name).
    static func names(_ names: [String], total: Int) -> String {
        let shown = Array(names.prefix(2))
        let others = max(0, total - shown.count)
        let joined = shown.count == 2 ? "\(shown[0]), \(shown[1])" : (shown.first ?? "")
        if others == 0 { return shown.count == 2 ? "\(shown[0]) and \(shown[1])" : joined }
        let tail = others == 1 ? "1 other" : "\(others) others"
        return joined.isEmpty ? tail : "\(joined) and \(tail)"
    }
}
