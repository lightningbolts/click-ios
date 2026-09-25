import Foundation
import Observation
import UIKit

/// Snapshot of an active authenticated session.
public struct SessionSnapshot: Equatable, Sendable, Codable {
    public let userId: String
    public let jwt: String
    public let refreshToken: String
    public let expiresAt: Date?

    public init(
        userId: String,
        jwt: String,
        refreshToken: String,
        expiresAt: Date? = nil
    ) {
        self.userId = userId
        self.jwt = jwt
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Session controller protocol for dependency injection and view model interactions.
@MainActor
public protocol SessionControlling: AnyObject {
    var state: SessionState { get }
    var currentSession: SessionSnapshot? { get }
    func restoreSession() async
    func signInWithEmail(email: String, password: String) async throws
    func signUpWithEmail(email: String, password: String, firstName: String, lastName: String, birthday: Date) async throws -> SignUpResult
    func completeProfileBasics(firstName: String, lastName: String, birthday: Date) async throws
    func signOut() async
    func refreshSession() async throws -> SessionSnapshot
}

/// Represents the high-level authentication lifecycle of the client.
public enum SessionState: Equatable, Sendable {
    /// Which root screen the state shows; token refreshes don't change it.
    public enum Phase: Equatable, Sendable { case launching, signedOut, profileBasics, signedIn }

    public var phase: Phase {
        switch self {
        case .restoring: .launching
        case .unauthenticated, .terminalError: .signedOut
        case .profileBasicsRequired: .profileBasics
        case .authenticated, .refreshing, .offlineAuthenticated: .signedIn
        }
    }

    case restoring
    case unauthenticated
    case profileBasicsRequired(userId: String)
    case authenticated(SessionSnapshot)
    case refreshing(SessionSnapshot)
    case offlineAuthenticated(SessionSnapshot)
    case terminalError(String)
}

/// Orchestrates session persistence, migration from legacy KMP, and proactive token refresh.
@Observable
@MainActor
public final class SessionController: SessionControlling {
    public private(set) var state: SessionState = .restoring {
        didSet {
            #if DEBUG
            if oldValue != state { print("[auth] \(Self.label(oldValue)) → \(Self.label(state))") }
            #endif
            sessionTokenMayHaveChanged()
        }
    }

    /// The token realtime sockets were last told about, and the timer that refreshes ahead of
    /// expiry so long-lived sockets never outlive their JWT (Supabase closes the channel then).
    private var announcedJWT: String?
    private var proactiveRefreshTask: Task<Void, Never>?

    private func sessionTokenMayHaveChanged() {
        let session = currentSession
        guard session?.jwt != announcedJWT else { return }
        announcedJWT = session?.jwt
        proactiveRefreshTask?.cancel()
        proactiveRefreshTask = nil
        guard let session, !session.jwt.isEmpty else { return }
        ChatRealtimeManager.accessTokenDidChange(session.jwt)
        guard let expiresAt = session.expiresAt else { return }
        let delay = max(5, expiresAt.timeIntervalSinceNow - 120)
        proactiveRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.currentSession?.jwt == session.jwt else { return }
            _ = try? await self.refreshSession()
        }
    }

    nonisolated static func label(_ state: SessionState) -> String {
        switch state {
        case .restoring: "restoring"
        case .unauthenticated: "unauthenticated"
        case .profileBasicsRequired: "profileBasicsRequired"
        case .authenticated(let s): "authenticated(exp \(s.expiresAt.map { Int($0.timeIntervalSinceNow) } ?? -1)s)"
        case .refreshing: "refreshing"
        case .offlineAuthenticated: "offlineAuthenticated"
        case .terminalError(let m): "terminalError(\(m))"
        }
    }

    private let migrator: LegacyKMPStateMigrator
    private let vault: KeychainSessionVault
    private let authService: SupabaseAuthService
    private var refreshTask: Task<SessionSnapshot, Error>?
    /// The authenticated bearer session remains available while a blocking gate is visible.
    /// UI state must not destroy the credentials required to complete that gate.
    private var retainedSession: SessionSnapshot?

    /// The profile body the gate just read, so onboarding resolution doesn't fetch it again.
    private var recentProfile: (userId: String, data: Data, at: Date)?

    /// The gate's profile response for `userId` if it is under 10 seconds old (consumed once).
    public func takeRecentProfile(for userId: String) -> Data? {
        defer { recentProfile = nil }
        guard let recentProfile, recentProfile.userId == userId, Date().timeIntervalSince(recentProfile.at) < 10 else { return nil }
        return recentProfile.data
    }

    public var apiClient: ClickAPIClient?
    public var settingsStore: SettingsStore?
    public var onPostAuthResolved: (@MainActor () -> Void)?
    /// Clears session-scoped caches owned by the environment (identities, uploads, telemetry).
    public var onSignOut: (@MainActor () async -> Void)?

    public init(
        migrator: LegacyKMPStateMigrator = .shared,
        vault: KeychainSessionVault = .shared,
        authService: SupabaseAuthService = SupabaseAuthService(),
        apiClient: ClickAPIClient? = nil,
        settingsStore: SettingsStore? = nil
    ) {
        self.migrator = migrator
        self.vault = vault
        self.authService = authService
        self.apiClient = apiClient
        self.settingsStore = settingsStore
    }

    public var currentSession: SessionSnapshot? {
        switch state {
        case .authenticated(let snapshot),
             .refreshing(let snapshot),
             .offlineAuthenticated(let snapshot):
            return snapshot
        case .restoring, .profileBasicsRequired:
            return retainedSession
        case .unauthenticated, .terminalError:
            return nil
        }
    }

    /// Restores the existing session from Keychain or migrates from legacy KMP with full validation.
    public func restoreSession() async {
        retainedSession = nil
        state = .restoring

        if let settings = settingsStore {
            migrator.performFullMigration(settings: settings, vault: vault)
        }

        // 1. Check native Keychain vault first. A locked device (background launch before
        // first unlock) is not "signed out": wait for protected data and read again.
        switch vault.read() {
        case .found(let current):
            retainedSession = current
            await evaluateAndAdmitSession(current)
            return
        case .unavailable:
            await Self.waitForProtectedData()
            await restoreSession()
            return
        case .notFound:
            break
        }

        // 2. Attempt legacy KMP migration if available
        if let legacy = migrator.readLegacySession() {
            let derivedUserId = legacy.userId ?? LegacyKMPStateMigrator.extractSubFromJWT(legacy.jwt)
            guard let validUserId = derivedUserId, !validUserId.isEmpty, validUserId != "unknown_user", validUserId != "legacy_user" else {
                state = .unauthenticated
                return
            }

            let expiresAtDate: Date? = legacy.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let snapshot = SessionSnapshot(
                userId: validUserId,
                jwt: legacy.jwt,
                refreshToken: legacy.refreshToken,
                expiresAt: expiresAtDate
            )
            vault.saveSession(snapshot)
            retainedSession = snapshot
            await evaluateAndAdmitSession(snapshot)
            return
        }

        // 3. Default to unauthenticated
        retainedSession = nil
        state = .unauthenticated
    }

    private func evaluateAndAdmitSession(_ snapshot: SessionSnapshot) async {
        // Safe identity derivation validation
        guard !snapshot.userId.isEmpty && snapshot.userId != "unknown_user" && snapshot.userId != "legacy_user" else {
            vault.deleteSession()
            migrator.deleteLegacySession()
            retainedSession = nil
            state = .unauthenticated
            return
        }

        // Token freshness evaluation
        let isFresh: Bool
        if let expiresAt = snapshot.expiresAt {
            isFresh = expiresAt > Date().addingTimeInterval(60) // At least 60s margin
        } else {
            isFresh = true // Unknown expiration, admitted optimistically
        }

        if isFresh {
            retainedSession = snapshot
            if settingsStore?.onboardingState(for: snapshot.userId)?.completedAt != nil {
                // Returning user with a completed profile and onboarding on this device: admit
                // immediately and re-check the profile gate in the background.
                state = .authenticated(snapshot)
                onPostAuthResolved?()
                Task { [weak self] in await self?.resolveProfileGate(for: snapshot.userId) }
            } else {
                // Keep the root on the launch gate until server-backed profile requirements resolve.
                state = .restoring
                await resolveProfileGate(for: snapshot.userId)
                onPostAuthResolved?()
            }

            // Opportunistic background refresh if expiring in under 15 minutes
            if let exp = snapshot.expiresAt, exp < Date().addingTimeInterval(900) {
                Task { [weak self] in
                    _ = try? await self?.refreshSession()
                }
            }
        } else {
            // Expired: attempt single-flight refresh before admitting
            // Expired: go through the same single-flight refresh as every API call, so a
            // concurrent 401 retry can never spend the (single-use) refresh token twice.
            do {
                let refreshed = try await refreshSession()
                await resolveProfileGate(for: refreshed.userId)
                onPostAuthResolved?()
            } catch {
                // `refreshSession` already applied the state: signed out on a hard rejection,
                // offline identity otherwise.
                if case .unauthenticated = state { return }
                onPostAuthResolved?()
            }
        }
    }

    private static func waitForProtectedData() async {
        guard !UIApplication.shared.isProtectedDataAvailable else {
            try? await Task.sleep(for: .milliseconds(300))
            return
        }
        for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
            return
        }
    }

    /// Resolves profile completion requirements from server truth.
    public func resolveProfileGate(for userId: String) async {
        guard let api = apiClient else {
            state = .terminalError("Session infrastructure is unavailable.")
            return
        }

        struct ProfileGateResponse: Decodable {
            struct UserRow: Decodable {
                let id: String?
                let firstName: String?
                let lastName: String?
                let birthday: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case firstName = "first_name"
                    case lastName = "last_name"
                    case birthday
                }
            }
            let user: UserRow?
        }

        do {
            let request = APIRequest(path: "/api/users/\(userId)/profile", method: .get, requiresAuth: true)
            let (data, _) = try await api.executeRaw(request)
            recentProfile = (userId, data, .now)
            guard let res = try? JSONDecoder().decode(ProfileGateResponse.self, from: data) else { throw APIError.decoding }

            let firstName = res.user?.firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastName = res.user?.lastName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let birthday = res.user?.birthday?.trimmingCharacters(in: .whitespacesAndNewlines)

            if firstName == nil || firstName?.isEmpty == true ||
                lastName == nil || lastName?.isEmpty == true ||
                birthday == nil || birthday?.isEmpty == true {
                // A newly-created OAuth account has no explicit native signup hook. Seed an
                // empty onboarding state only when there is no legacy completion or per-user
                // state, so completing Profile Basics still leads to Welcome.
                if settingsStore?.hasCompletedOnboarding == false,
                   settingsStore?.onboardingState(for: userId) == nil {
                    settingsStore?.saveOnboardingState(OnboardingState(), for: userId)
                }
                state = .profileBasicsRequired(userId: userId)
            } else if let current = currentSession {
                retainedSession = current
                state = .authenticated(current)
            }
        } catch let apiError as APIError {
            // Never flash onboarding while profile truth is still being resolved. If the
            // profile endpoint is unavailable, keep the authenticated identity and let the
            // onboarding resolver use its durable/cache fallback policy.
            if let current = currentSession {
                retainedSession = current
                switch apiError {
                case .offline, .timeout:
                    state = .offlineAuthenticated(current)
                default:
                    state = .authenticated(current)
                }
            }
        } catch {
            if let current = currentSession {
                retainedSession = current
                state = .authenticated(current)
            }
        }
    }

    /// Signs in with email and password via backend.
    public func signInWithEmail(email: String, password: String) async throws {
        let snapshot = try await authService.signIn(email: email, password: password)
        vault.saveSession(snapshot)
        retainedSession = snapshot
        state = .restoring
        await resolveProfileGate(for: snapshot.userId)
        onPostAuthResolved?()
    }

    /// Signs up with email, password, and required personal details.
    @discardableResult
    public func signUpWithEmail(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        birthday: Date
    ) async throws -> SignUpResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let birthdayIso = formatter.string(from: birthday)

        let result = try await authService.signUp(
            email: email,
            password: password,
            firstName: firstName,
            lastName: lastName,
            birthdayIso: birthdayIso
        )

        switch result {
        case .authenticated(let snapshot):
            vault.saveSession(snapshot)
            retainedSession = snapshot
            // An explicitly fresh native signup must enter the native onboarding flow as new,
            // rather than being mistaken for a returning account from its populated profile.
            settingsStore?.saveOnboardingState(OnboardingState(), for: snapshot.userId)
            settingsStore?.hasCompletedOnboarding = false
            state = .restoring
            await resolveProfileGate(for: snapshot.userId)
            onPostAuthResolved?()
            return result
        case .verificationRequired:
            return result
        }
    }

    /// Completes the profile basics gate for accounts missing required profile fields.
    public func completeProfileBasics(firstName: String, lastName: String, birthday: Date) async throws {
        guard let current = currentSession else {
            state = .unauthenticated
            throw SessionError.noActiveSession
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let birthdayIso = formatter.string(from: birthday)

        let payload: [String: Any] = [
            "first_name": firstName.trimmingCharacters(in: .whitespacesAndNewlines),
            "last_name": lastName.trimmingCharacters(in: .whitespacesAndNewlines),
            "birthday": birthdayIso
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        guard let api = apiClient else {
            throw SessionError.missingAPIClient
        }
        let request = APIRequest(
            path: "/api/users/\(current.userId)/profile",
            method: .patch,
            body: bodyData,
            requiresAuth: true
        )
        _ = try await api.executeRaw(request)
        await resolveProfileGate(for: current.userId)

        // The PATCH itself is the durable write. If the follow-up profile fetch was
        // unavailable, do not strand the user on an already-satisfied blocking gate.
        if case .profileBasicsRequired = state {
            retainedSession = current
            state = .authenticated(current)
        }
        onPostAuthResolved?()
    }

    /// Signs in directly with a given snapshot (for testing or external OAuth coordinators).
    public func signIn(snapshot: SessionSnapshot) {
        vault.saveSession(snapshot)
        retainedSession = snapshot
        state = .restoring
        Task { [weak self] in
            await self?.resolveProfileGate(for: snapshot.userId)
            self?.onPostAuthResolved?()
        }
    }

    /// Triggers the ProfileBasics gate for accounts needing profile completion.
    public func requireProfileBasics(userId: String) {
        if retainedSession == nil {
            retainedSession = vault.readSession()
        }
        state = .profileBasicsRequired(userId: userId)
    }

    /// Signs out the active user and clears secure credentials.
    public func signOut() async {
        let signingOutUserId = currentSession?.userId
        if let session = currentSession {
            await authService.signOut(jwt: session.jwt)
        }
        vault.deleteSession()
        migrator.deleteLegacySession()
        if let userId = signingOutUserId {
            settingsStore?.clearOnboardingState(for: userId)
        }
        settingsStore?.resetSessionScopedData()
        // Decrypted chat media never outlives the session that decrypted it.
        await ChatMediaVault.shared.clear()
        await FreshnessCache.shared.removeAll()
        await onSignOut?()
        retainedSession = nil
        state = .unauthenticated
    }

    /// Seconds before expiry at which API calls proactively refresh.
    public nonisolated static let proactiveRefreshWindow: TimeInterval = 5 * 60

    public nonisolated static func needsProactiveRefresh(expiresAt: Date?, now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < proactiveRefreshWindow
    }

    /// The bearer token for an API call. Refreshes first (single-flight) when the token is within
    /// five minutes of expiry; if that refresh fails transiently the current token is still used
    /// and the server's 401 path decides.
    public func validAccessToken() async -> String? {
        guard let current = currentSession else { return nil }
        guard Self.needsProactiveRefresh(expiresAt: current.expiresAt) else { return current.jwt }
        if let refreshed = try? await refreshSession() { return refreshed.jwt }
        return currentSession?.jwt
    }

    /// Refreshes the session token proactively or on demand.
    public func refreshSession() async throws -> SessionSnapshot {
        guard let current = currentSession else {
            state = .unauthenticated
            throw SessionError.noActiveSession
        }

        // Single-flight refresh coordination
        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        let wasProfileGated: Bool
        if case .profileBasicsRequired = state {
            wasProfileGated = true
        } else {
            wasProfileGated = false
        }
        let wasResolvingProfile: Bool
        if case .restoring = state {
            wasResolvingProfile = true
        } else {
            wasResolvingProfile = false
        }

        if !wasProfileGated && !wasResolvingProfile {
            state = .refreshing(current)
        }

        let task = Task<SessionSnapshot, Error> {
            let refreshed = try await self.authService.refreshToken(current.refreshToken)
            return refreshed
        }

        refreshTask = task
        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            self.vault.saveSession(refreshed)
            self.retainedSession = refreshed
            if wasProfileGated {
                self.state = .profileBasicsRequired(userId: refreshed.userId)
            } else if wasResolvingProfile {
                self.state = .restoring
            } else {
                self.state = .authenticated(refreshed)
            }
            return refreshed
        } catch let apiErr as APIError {
            switch apiErr {
            case .offline, .timeout:
                self.retainedSession = current
                if wasProfileGated {
                    self.state = .profileBasicsRequired(userId: current.userId)
                } else {
                    self.state = .offlineAuthenticated(current)
                }
            case .unauthorized, .forbidden, .validation:
                // The token we sent may already have been rotated and saved by an earlier
                // refresh (e.g. one that finished just before the app was suspended). Adopt the
                // stored session instead of signing out.
                if let stored = self.vault.readSession(), stored.refreshToken != current.refreshToken {
                    self.retainedSession = stored
                    self.state = wasProfileGated ? .profileBasicsRequired(userId: stored.userId)
                        : wasResolvingProfile ? .restoring : .authenticated(stored)
                    return stored
                }
                self.vault.deleteSession()
                self.migrator.deleteLegacySession()
                self.retainedSession = nil
                self.state = .unauthenticated
            default:
                self.retainedSession = current
                if wasProfileGated {
                    self.state = .profileBasicsRequired(userId: current.userId)
                } else {
                    self.state = .offlineAuthenticated(current)
                }
            }
            throw apiErr
        } catch {
            self.retainedSession = current
            if wasProfileGated {
                self.state = .profileBasicsRequired(userId: current.userId)
            } else {
                self.state = .offlineAuthenticated(current)
            }
            throw error
        }
    }

    public enum SessionError: Error, Equatable {
        case noActiveSession
        case refreshFailed
        case missingAPIClient
    }
}
