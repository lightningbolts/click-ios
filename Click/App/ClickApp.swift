import SwiftUI
import UIKit
@preconcurrency import UserNotifications
import Security

@main
struct ClickApp: App {
    @UIApplicationDelegateAdaptor(ClickAppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment

    init() {
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        ClickFonts.registerFonts()
        // Root large titles use Click's Manrope display voice; inline titles stay system 17pt.
        // Only the font is customized so the platform keeps owning bar layout and material.
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: ClickTypography.largeTitleUIFont()]
        ClickNotificationCoordinator.shared.attach(environment: environment)
        EmojiKeyboardPicker.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environment(environment)
                // Preserve the existing Click appearance preference across the KMP -> native
                // in-place upgrade instead of silently falling back to the simulator/system theme.
                .preferredColorScheme(environment.settings.appearance.colorScheme)
                .task {
                    if DebugLaunch.has("-preview-profile-basics") {
                        environment.session.requireProfileBasics(userId: "usr_preview_99")
                    } else if DebugLaunch.has("-preview-shell")
                        || DebugLaunch.has("-preview-home")
                        || DebugLaunch.has("-preview-clicks")
                        || DebugLaunch.has("-preview-profile") {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_active",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if DebugLaunch.hasPrefix("-preview-onboarding") {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_onboarding",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if DebugLaunch.has("-preview-signup")
                        || DebugLaunch.has("-preview-signin") {
                        await environment.session.signOut()
                    } else {
                        await environment.bootstrap()
                    }

                    await ClickNotificationCoordinator.shared.sessionDidChange()
                }
                .onChange(of: environment.session.state) { _, _ in
                    Task {
                        await ClickNotificationCoordinator.shared.sessionDidChange()
                    }
                }
                .onOpenURL { url in
                    environment.handleIncomingURL(url)
                }
        }
    }
}

/// UIKit lifecycle bridge used only for platform callbacks SwiftUI does not surface directly.
final class ClickAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            await ClickNotificationCoordinator.shared.receivedAPNsToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Registration is recoverable. Do not surface a launch error for an optional channel.
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Realtime owns the open conversation's timeline: a push for it would only repeat the
        // message the reader is looking at. Everything else still shows while in the app.
        let payload = Self.stringPayload(notification.request.content.userInfo)
        let isOnScreen = await ClickNotificationCoordinator.shared.isForVisibleConversation(payload)
        return isOnScreen ? [] : [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = Self.stringPayload(response.notification.request.content.userInfo)
        completionHandler()

        Task { @MainActor in
            await ClickNotificationCoordinator.shared.handleNotificationTap(payload)
        }
    }

    nonisolated private static func stringPayload(_ source: [AnyHashable: Any]) -> [String: String] {
        var payload: [String: String] = [:]
        for (key, value) in source {
            guard let key = key as? String else { continue }
            if let string = value as? String {
                payload[key] = string
            } else if let number = value as? NSNumber {
                payload[key] = number.stringValue
            }
        }
        return payload
    }
}

/// Standard-APNs registration and typed notification routing.
///
/// Permission is never prompted merely because the app launched. An in-place KMP update that
/// already has authorization is re-registered automatically; a future Settings/permission
/// surface can call requestAuthorization() from explicit user intent.
@MainActor
final class ClickNotificationCoordinator {
    static let shared = ClickNotificationCoordinator()

    private weak var environment: AppEnvironment?
    private let tokenVault = PushTokenVault()
    private let installIDKey = "click.standard_apns.install_id"
    private var lastObservedUserID: String?
    private var uploadedTokenKey: String?
    private var uploadingTokenKey: String?

    private init() {}

    func attach(environment: AppEnvironment) {
        self.environment = environment
    }

    func requestAuthorization() async -> Bool {
        guard let environment,
              environment.settings.messageNotificationsEnabled else {
            return false
        }

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            return false
        }
    }

    func sessionDidChange() async {
        guard let environment else { return }
        let currentUserID = environment.session.currentSession?.userId

        if currentUserID != lastObservedUserID {
            lastObservedUserID = currentUserID

            if let pendingScope = tokenVault.readUserScope(),
               let currentUserID,
               pendingScope != currentUserID {
                // A failed upload from a previous account must never be replayed for the next one.
                tokenVault.clearPending()
            }
        }

        await refreshRegistrationForExistingPermission()
        await flushPendingTokenIfPossible()
    }

    func receivedAPNsToken(_ token: String) async {
        guard !token.isEmpty else { return }
        tokenVault.writeToken(token)
        tokenVault.writeUserScope(environment?.session.currentSession?.userId)
        await flushPendingTokenIfPossible()
    }

    private func refreshRegistrationForExistingPermission() async {
        guard let environment,
              environment.settings.messageNotificationsEnabled else {
            return
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined, .denied:
            break
        @unknown default:
            break
        }
    }

    private func flushPendingTokenIfPossible() async {
        guard let environment,
              let session = environment.session.currentSession,
              let token = tokenVault.readToken(),
              !token.isEmpty else {
            return
        }

        if let pendingScope = tokenVault.readUserScope(),
           pendingScope != session.userId {
            return
        }
        // Several launch triggers flush at once; one upload per user/token per launch is enough.
        let key = session.userId + "|" + token
        guard uploadedTokenKey != key, uploadingTokenKey != key else { return }
        uploadingTokenKey = key
        defer { uploadingTokenKey = nil }

        let body: [String: Any] = [
            "token": token,
            "platform": "ios",
            "token_type": "standard",
            "device_id": stableInstallID()
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }

        do {
            let request = APIRequest(
                path: "/api/user/push-tokens",
                method: .post,
                body: bodyData,
                requiresAuth: true
            )
            _ = try await environment.api.executeRaw(request)
            uploadedTokenKey = key
            tokenVault.writeUserScope(session.userId)
        } catch {
            // Keep the token securely queued. The next session/foreground registration retries it.
        }
    }

    /// What a notification tap should open, decided from the payload alone (unit-tested per `type`).
    enum TapRoute: Equatable {
        /// A direct chat; resolved against the cached inbox so the header has real identity.
        case chat(chatID: String?, connectionID: String?, senderUserID: String?, senderName: String?)
        case route(AppRoute)
        /// Clicks root (unknown identity, availability matches).
        case connections
        /// Unknown future categories keep the current app state.
        case none
    }

    nonisolated static func tapRoute(for payload: [String: String]) -> TapRoute {
        let value = { (keys: [String]) in firstValue(payload, keys: keys) }
        switch payload["type"] ?? payload["category"] ?? "" {
        case "chat_message", "new_message", "disposable_reveal":
            return .chat(chatID: value(["chat_id", "chatId"]), connectionID: value(["connection_id", "connectionId"]),
                         senderUserID: value(["sender_user_id", "user_id", "peer_user_id"]),
                         senderName: value(["sender_name", "peer_name", "title"]))
        case "event_reminder", "event_teaser", "shared_upcoming_event":
            return value(["beacon_id", "event_id"]).map { .route(.event(beaconID: $0)) } ?? .none
        case "hub_message":
            return value(["hub_id", "venue_id"]).map { .route(.hub(hubID: $0)) } ?? .none
        case "archive_warning", "reconnect_nudge", "anniversary", "memory_prompt", "hangout_confirm":
            // The profile carries the moment: friendship, story, and a hangout to confirm.
            guard let userID = value(["peer_user_id", "user_id", "sender_user_id"]) else { return .connections }
            return .route(.userProfile(userID: userID, connectionID: value(["connection_id", "connectionId"])))
        case "wave":
            return .chat(chatID: nil, connectionID: value(["connection_id", "connectionId"]),
                         senderUserID: value(["peer_user_id", "sender_user_id"]), senderName: nil)
        case "group_revival":
            return value(["chat_id", "chatId"]).map { .route(.conversation(chatID: $0, messageID: nil)) } ?? .connections
        case "availability_match":
            return .connections
        default:
            return .none
        }
    }

    /// True when the push is about the conversation currently on screen (direct chat, group
    /// or hub), matched by chat, connection or hub ID.
    func isForVisibleConversation(_ payload: [String: String]) -> Bool {
        guard let environment, UIApplication.shared.applicationState == .active else { return false }
        let onScreen = Set([environment.activeChatID, environment.activeConnectionID].compactMap { $0 })
        guard !onScreen.isEmpty else { return false }
        switch Self.tapRoute(for: payload) {
        case let .chat(chatID, connectionID, _, _):
            return [chatID, connectionID].contains { $0.map(onScreen.contains) ?? false }
        case .route(.hub(let hubID)):
            return onScreen.contains(hubID)
        default:
            return false
        }
    }

    func handleNotificationTap(_ payload: [String: String]) async {
        guard let environment else { return }
        switch Self.tapRoute(for: payload) {
        case let .chat(chatID, connectionID, senderUserID, senderName):
            await routeChat(chatID: chatID, connectionID: connectionID, senderUserID: senderUserID,
                            senderName: senderName, environment: environment)
        case .route(let route):
            environment.handleIncomingRoute(route)
        case .connections:
            environment.router.selectedTab = .connections
            environment.router.connectionsPath.removeAll()
        case .none:
            break
        }
    }

    private func routeChat(chatID: String?, connectionID: String?, senderUserID: String?, senderName: String?,
                           environment: AppEnvironment) async {

        if let connectionID,
           let currentUserID = environment.session.currentSession?.userId {
            let cachedSnapshot = await environment.phase3.cachedClicks(for: currentUserID)
            let snapshot: ClicksSnapshot?
            if let cachedSnapshot {
                snapshot = cachedSnapshot
            } else {
                snapshot = try? await environment.phase3.refreshClicks(for: currentUserID)
            }

            if let connection = snapshot?.connections.first(where: { $0.connectionID == connectionID }) {
                environment.handleIncomingRoute(
                    .chat(
                        DirectChatRoute(
                            chatID: chatID,
                            connectionID: connectionID,
                            peerUserID: connection.userID,
                            peerDisplayName: connection.displayName,
                            peerHandle: connection.handle,
                            peerAvatarURL: connection.avatarUrl,
                            isOnline: connection.isOnline,
                            lastActiveText: connection.lastActiveRelative
                        )
                    )
                )
                return
            }
        }

        if let chatID,
           let senderUserID,
           !chatID.isEmpty,
           !senderUserID.isEmpty {
            let displayName = senderName ?? "Click"

            environment.handleIncomingRoute(
                .chat(
                    DirectChatRoute(
                        chatID: chatID,
                        connectionID: connectionID,
                        peerUserID: senderUserID,
                        peerDisplayName: displayName
                    )
                )
            )
            return
        }

        // Do not fabricate participant identity. Land safely in Clicks so the user can resolve the
        // conversation from authenticated data.
        environment.router.selectedTab = .connections
        environment.router.connectionsPath.removeAll()
    }

    nonisolated private static func firstValue(_ payload: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func stableInstallID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }

        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installIDKey)
        return created
    }
}

/// Tiny Keychain record for a token that can arrive before authentication completes.
private final class PushTokenVault: @unchecked Sendable {
    private let service = "com.click.push.standard"
    private let tokenAccount = "pending_token"
    private let scopeAccount = "pending_user_scope"

    func readToken() -> String? {
        read(account: tokenAccount)
    }

    func writeToken(_ token: String) {
        write(token, account: tokenAccount)
    }

    func readUserScope() -> String? {
        read(account: scopeAccount)
    }

    func writeUserScope(_ userID: String?) {
        guard let userID, !userID.isEmpty else {
            delete(account: scopeAccount)
            return
        }
        write(userID, account: scopeAccount)
    }

    func clearPending() {
        delete(account: tokenAccount)
        delete(account: scopeAccount)
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        if SecItemUpdate(identity as CFDictionary, update as CFDictionary) != errSecSuccess {
            var add = identity
            add.merge(update) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
