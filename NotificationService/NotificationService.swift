import UserNotifications
import Foundation

/// Handles background push notification interception and secure E2EE preview decryption.
/// Satisfies §36 and `click/iosApp/NotificationService/NotificationService.swift` parity.
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
        case "chat_message", "new_message":
            bestAttemptContent.title = bestAttemptContent.title.isEmpty ? "Click Message" : bestAttemptContent.title
            let resolvedBody = resolveChatMessageBody(userInfo: userInfo, originalBody: bestAttemptContent.body)
            bestAttemptContent.body = resolvedBody
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

    // MARK: - Decryption Resolver

    private func resolveChatMessageBody(userInfo: [AnyHashable: Any], originalBody: String) -> String {
        let fallback = originalBody.isEmpty ? "Open Click to view message" : originalBody
        let previewFromServer = (userInfo["preview_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let encrypted = (userInfo["encrypted_content"] as? String) ?? ""
        let connectionId = (userInfo["connection_id"] as? String) ?? ""
        let senderUserId = (userInfo["sender_user_id"] as? String) ?? ""
        let recipientUserId = (userInfo["recipient_user_id"] as? String) ?? ""

        guard !encrypted.isEmpty else {
            return previewFromServer ?? fallback
        }

        // 1. Plaintext fallback
        if !ClickCryptoV1.isEncrypted(encrypted) && !encrypted.hasPrefix("e2e2:") {
            return String(encrypted.prefix(120))
        }

        // 2. Legacy v1 direct decryption
        if ClickCryptoV1.isEncrypted(encrypted) &&
            !connectionId.isEmpty && !senderUserId.isEmpty && !recipientUserId.isEmpty {
            let keys = ClickCryptoV1.deriveKeysForConnection(
                connectionID: connectionId,
                userIDs: [senderUserId, recipientUserId]
            )
            let decrypted = ClickCryptoV1.decryptContent(encrypted, keys: keys)
            if !ClickCryptoV1.isEncrypted(decrypted) {
                return String(decrypted.prefix(120))
            }
        }

        // 3. Fallback to server preview or default
        return previewFromServer ?? fallback
    }
}
