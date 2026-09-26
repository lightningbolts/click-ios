import Foundation
import UserNotifications

/// On-device reminders for chat plans you're going to: an hour before (or sooner, if the plan
/// is closer than that). Local only; nothing about the plan leaves the device for this.
enum PlanReminders {
    static func identifier(_ messageID: String) -> String { "plan.\(messageID)" }

    static func update(messageID: String, plan: HangoutPlan, going: Bool, chatID: String, connectionID: String?, chatName: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(messageID)])
        guard going, plan.startsAt > Date().addingTimeInterval(5 * 60) else { return }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }

        let fireAt = max(plan.startsAt.addingTimeInterval(-3600), Date().addingTimeInterval(60))
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = "Starts at \(plan.startsAt.formatted(date: .omitted, time: .shortened))"
            + (plan.placeName.map { " · \($0)" } ?? "") + " with \(chatName)"
        content.sound = .default
        content.threadIdentifier = "plans"
        // Opens the chat the plan was made in (same routing as a message push).
        var info: [String: String] = ["type": "chat_message", "chat_id": chatID]
        if let connectionID { info["connection_id"] = connectionID }
        content.userInfo = info
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let request = UNNotificationRequest(identifier: identifier(messageID), content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try? await center.add(request)
    }
}
