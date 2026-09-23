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
    }

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environment(environment)
                // Preserve the existing Click appearance preference across the KMP -> native
                // in-place upgrade instead of silently falling back to the simulator/system theme.
                .preferredColorScheme(environment.settings.darkModeEnabled ? .dark : .light)
                .task {
                    if CommandLine.arguments.contains("-preview-profile-basics") {
                        environment.session.requireProfileBasics(userId: "usr_preview_99")
                    } else if CommandLine.arguments.contains("-preview-shell")
                        || CommandLine.arguments.contains("-preview-home")
                        || CommandLine.arguments.contains("-preview-clicks")
                        || CommandLine.arguments.contains("-preview-profile") {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_active",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if CommandLine.arguments.contains(where: { $0.hasPrefix("-preview-onboarding") }) {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_onboarding",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if CommandLine.arguments.contains("-preview-signup")
                        || CommandLine.arguments.contains("-preview-signin") {
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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Realtime owns in-app timeline updates. System presentation remains available while the
        // user is elsewhere; duplicate open-thread suppression can be decided synchronously by
        // the coordinator once a full notification state service is introduced.
        completionHandler([.banner, .sound, .badge])
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
            tokenVault.writeUserScope(session.userId)
        } catch {
            // Keep the token securely queued. The next session/foreground registration retries it.
        }
    }

    func handleNotificationTap(_ payload: [String: String]) async {
        guard let environment else { return }

        let type = payload["type"] ?? payload["category"] ?? ""
        switch type {
        case "chat_message", "new_message":
            await routeChat(payload, environment: environment)

        case "event_reminder", "event_teaser", "shared_upcoming_event":
            if let beaconID = firstValue(payload, keys: ["beacon_id", "event_id"]), !beaconID.isEmpty {
                environment.handleIncomingRoute(.event(beaconID: beaconID))
            }

        case "hub_message":
            if let hubID = firstValue(payload, keys: ["hub_id", "venue_id"]), !hubID.isEmpty {
                environment.handleIncomingRoute(.hub(hubID: hubID))
            }

        case "archive_warning", "reconnect_nudge":
            await routeConnectionContext(payload, environment: environment)

        case "disposable_reveal":
            await routeChat(payload, environment: environment)

        case "availability_match":
            environment.router.selectedTab = .connections
            environment.router.connectionsPath.removeAll()

        default:
            // Unknown future categories intentionally fall back to the current/root app state.
            break
        }
    }

    private func routeChat(_ payload: [String: String], environment: AppEnvironment) async {
        let chatID = firstValue(payload, keys: ["chat_id", "chatId"])
        let connectionID = firstValue(payload, keys: ["connection_id", "connectionId"])
        let senderUserID = firstValue(payload, keys: ["sender_user_id", "user_id", "peer_user_id"])

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
            let displayName =
                firstValue(payload, keys: ["sender_name", "peer_name", "title"])
                ?? "Click"

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

    private func routeConnectionContext(
        _ payload: [String: String],
        environment: AppEnvironment
    ) async {
        let connectionID = firstValue(payload, keys: ["connection_id", "connectionId"])
        let userID = firstValue(payload, keys: ["user_id", "peer_user_id", "sender_user_id"])

        if let userID, !userID.isEmpty {
            environment.handleIncomingRoute(
                .userProfile(userID: userID, connectionID: connectionID)
            )
        } else {
            environment.router.selectedTab = .connections
            environment.router.connectionsPath.removeAll()
        }
    }

    private func firstValue(_ payload: [String: String], keys: [String]) -> String? {
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
