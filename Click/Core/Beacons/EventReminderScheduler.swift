import Foundation
import UserNotifications

/// A local reminder an hour before an event the user RSVP'd to or saved (spec §59).
/// Honors the Alerts "Event reminders" preference, never prompts for permission on its own,
/// and uses the same `event_reminder` payload as server pushes so taps route to the event.
enum EventReminderScheduler {
    static let offsets: [Int] = [60]
    /// Offsets no longer scheduled; their pending requests are still cancelled.
    private static let retiredOffsets: [Int] = [15]

    /// Fire dates still in the future, by minutes-before.
    nonisolated static func triggers(start: Date, now: Date = .now) -> [(minutes: Int, date: Date)] {
        offsets.compactMap { minutes in
            let date = start.addingTimeInterval(-Double(minutes) * 60)
            return date > now ? (minutes, date) : nil
        }
    }

    nonisolated static func identifier(_ beaconID: String, minutes: Int) -> String {
        "event-reminder.\(beaconID).\(minutes)"
    }

    static func schedule(beaconID: String, title: String, start: Date, place: String?, enabled: Bool) async {
        await cancel(beaconID: beaconID)
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for trigger in triggers(start: start) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Starts in an hour" + (place.map { " · \($0)" } ?? "")
            content.sound = .click
            content.userInfo = ["type": "event_reminder", "beacon_id": beaconID]
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: trigger.date)
            let request = UNNotificationRequest(
                identifier: identifier(beaconID, minutes: trigger.minutes),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    static func cancel(beaconID: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (offsets + retiredOffsets).map { identifier(beaconID, minutes: $0) }
        )
    }

    /// Removes reminders scheduled by earlier versions at retired offsets (the 15-minute one).
    static func pruneRetired() async {
        let center = UNUserNotificationCenter.current()
        let suffixes = retiredOffsets.map { ".\($0)" }
        let retired = await center.pendingNotificationRequests().map(\.identifier)
            .filter { id in id.hasPrefix("event-reminder.") && suffixes.contains { id.hasSuffix($0) } }
        if !retired.isEmpty { center.removePendingNotificationRequests(withIdentifiers: retired) }
    }

    /// Alerts → Event reminders turned off, or sign-out.
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("event-reminder.") }
        )
    }
}
