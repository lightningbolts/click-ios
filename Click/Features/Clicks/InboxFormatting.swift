import Foundation

/// Pure presentation rules for Clicks inbox rows.
enum InboxFormatting {
    /// The one-line preview for a conversation row.
    /// - Parameter decryptedText: memory-only plaintext for encrypted text messages, if readable.
    static func preview(for item: ConnectionItem, decryptedText: String?) -> String {
        guard let message = item.lastMessage else {
            if item.sayHiDeadline != nil { return "New Click · say hi" }
            if !item.encounterLocation.isEmpty { return "Met at \(item.encounterLocation)" }
            return "New Click"
        }
        if message.isDisposable { return "Click Drop" }

        switch message.messageType.lowercased() {
        case "image", "photo":
            return "Photo"
        case "video":
            return "Video"
        case "audio", "voice", "voice_note":
            return "Voice note"
        case "file", "document":
            return "File"
        case "beacon", "event", "event_share", "beacon_share":
            return "Shared an event"
        case "call_log":
            return "Call"
        default:
            if let decryptedText {
                return decryptedText.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
            let isEncrypted = ClickCryptoV1.isEncrypted(message.content) || ClickCryptoV2.isEncrypted(message.content)
            return isEncrypted ? "Message" : message.content
        }
    }

    /// WhatsApp-style row timestamp: time today, "Yesterday", weekday this week, else a date.
    static func timestamp(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days == 1 { return "Yesterday" }

        var style = Date.FormatStyle(locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        if (2...6).contains(days) {
            return date.formatted(style.weekday(.abbreviated))
        }
        return date.formatted(style.month(.defaultDigits).day())
    }

    /// Remaining time in the 48-hour "say hi" window, e.g. "36h left".
    static func sayHiRemaining(until deadline: Date, now: Date = Date()) -> String? {
        let seconds = deadline.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let hours = Int((seconds / 3600).rounded(.up))
        return hours <= 1 ? "<1h left" : "\(hours)h left"
    }
}
