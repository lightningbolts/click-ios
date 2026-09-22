import UserNotifications

/// Handles background push notification interception and secure preview decryption.
public final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    public override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let userInfo = request.content.userInfo
        let category = userInfo["category"] as? String ?? userInfo["type"] as? String

        switch category {
        case "chat_message":
            // Fallback copy when encrypted payload cannot be decrypted immediately in extension
            bestAttemptContent.title = bestAttemptContent.title.isEmpty ? "Click Message" : bestAttemptContent.title
            if bestAttemptContent.body.isEmpty {
                bestAttemptContent.body = "Open Click to view message"
            }
        case "event_reminder":
            bestAttemptContent.title = "Event Reminder"
        case "reconnect_nudge":
            bestAttemptContent.title = "Reconnect"
        default:
            break
        }

        contentHandler(bestAttemptContent)
    }

    public override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
