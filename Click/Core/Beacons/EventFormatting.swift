import Foundation

/// Locale-aware event date/time copy shared by Home, Saved Events, Nearby, and Event Detail.
enum EventFormatting {
    /// "Today · 7:00 – 10:00 PM · Café Allegro", "Sat, Sep 26 · 7:00 PM · …".
    static func whenAndWhere(_ schedule: EventSchedule, place: String?, now: Date = .now, calendar: Calendar = .current) -> String {
        var parts = [when(schedule, now: now, calendar: calendar)]
        if let place, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    static func when(_ schedule: EventSchedule, now: Date = .now, calendar: Calendar = .current) -> String {
        let start = schedule.start.formatted(date: .omitted, time: .shortened)
        let range = calendar.isDate(schedule.start, inSameDayAs: schedule.end)
            ? "\(start) – \(schedule.end.formatted(date: .omitted, time: .shortened))"
            : start
        if calendar.isDate(schedule.start, inSameDayAs: now) { return "Today · \(range)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(schedule.start, inSameDayAs: tomorrow) {
            return "Tomorrow · \(range)"
        }
        let day = schedule.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) · \(range)"
    }

    /// Trailing status for list rows: "Live", "Today", or nothing when later/unscheduled.
    static func status(_ schedule: EventSchedule?, now: Date = .now) -> (text: String, isLive: Bool)? {
        guard let schedule else { return nil }
        if schedule.isLive(at: now) { return ("Live", true) }
        if schedule.startsToday(at: now) { return ("Today", false) }
        return nil
    }
}
