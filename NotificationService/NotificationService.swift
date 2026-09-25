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
            // Messages-style: the sender is the title, the message (or its kind) the body.
            if let sender = (userInfo["sender_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
                bestAttemptContent.title = sender
            } else if bestAttemptContent.title.isEmpty {
                bestAttemptContent.title = "Click"
            }
            bestAttemptContent.body = resolveChatMessageBody(userInfo: userInfo)
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

    private func resolveChatMessageBody(userInfo: [AnyHashable: Any]) -> String {
        // Attachments and shared events never show their (descriptor) content.
        switch (userInfo["message_type"] as? String)?.lowercased() {
        case "image", "photo": return "📷 Photo"
        case "audio", "voice", "voice_note": return "🎤 Voice message"
        case "file", "document": return "📎 File"
        case "beacon": return "📍 Shared an event"
        default: break
        }

        // Private copy whenever the text can't be decrypted here (the title names the sender).
        let fallback = "Sent you a message"

        let encrypted = (userInfo["encrypted_content"] as? String) ?? ""
        let connectionId = (userInfo["connection_id"] as? String) ?? ""
        let senderUserId = (userInfo["sender_user_id"] as? String) ?? ""
        let recipientUserId = (userInfo["recipient_user_id"] as? String) ?? ""

        guard !encrypted.isEmpty else {
            return fallback
        }

        // V2 epoch keys are app-owned and may not be available to this extension process. Never
        // trust a server-provided plaintext preview for E2EE v2; use deterministic private copy.
        if encrypted.hasPrefix("e2e2:") {
            return fallback
        }

        // Legacy v1 direct decryption
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

        // Unknown/invalid wire content is privacy-safe by default.
        return fallback
    }
}
