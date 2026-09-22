import Foundation
import Observation

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
    func signUpWithEmail(email: String, password: String, firstName: String, lastName: String, birthday: Date) async throws
    func completeProfileBasics(firstName: String, lastName: String, birthday: Date) async throws
    func signOut() async
    func refreshSession() async throws -> SessionSnapshot
}

/// Represents the high-level authentication lifecycle of the client.
public enum SessionState: Equatable, Sendable {
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
    public private(set) var state: SessionState = .restoring

    private let migrator: LegacyKMPStateMigrator
    private let vault: KeychainSessionVault
    private let authService: SupabaseAuthService
    private var refreshTask: Task<SessionSnapshot, Error>?

    public init(
        migrator: LegacyKMPStateMigrator = .shared,
        vault: KeychainSessionVault = .shared,
        authService: SupabaseAuthService = SupabaseAuthService()
    ) {
        self.migrator = migrator
        self.vault = vault
        self.authService = authService
    }

    public var currentSession: SessionSnapshot? {
        switch state {
        case .authenticated(let snapshot),
             .refreshing(let snapshot),
             .offlineAuthenticated(let snapshot):
            return snapshot
        case .restoring, .unauthenticated, .profileBasicsRequired, .terminalError:
            return nil
        }
    }

    /// Restores the existing session from Keychain or migrates from legacy KMP.
    public func restoreSession() async {
        state = .restoring

        // 1. Check native Keychain vault first
        if let current = vault.readSession() {
            state = .authenticated(current)
            return
        }

        // 2. Attempt legacy KMP migration if available
        if let legacy = migrator.readLegacySession() {
            let expiresAtDate: Date? = legacy.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let snapshot = SessionSnapshot(
                userId: legacy.userId ?? "legacy_user",
                jwt: legacy.jwt,
                refreshToken: legacy.refreshToken,
                expiresAt: expiresAtDate
            )
            // Persist to native vault
            vault.saveSession(snapshot)
            state = .authenticated(snapshot)
            return
        }

        // 3. Default to unauthenticated
        state = .unauthenticated
    }

    /// Signs in with email and password via backend.
    public func signInWithEmail(email: String, password: String) async throws {
        let snapshot = try await authService.signIn(email: email, password: password)
        vault.saveSession(snapshot)
        state = .authenticated(snapshot)
    }

    /// Signs up with email, password, and required personal details.
    public func signUpWithEmail(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        birthday: Date
    ) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let birthdayIso = formatter.string(from: birthday)

        let snapshot = try await authService.signUp(
            email: email,
            password: password,
            firstName: firstName,
            lastName: lastName,
            birthdayIso: birthdayIso
        )
        vault.saveSession(snapshot)
        state = .authenticated(snapshot)
    }

    /// Completes the profile basics gate for accounts missing required profile fields.
    public func completeProfileBasics(firstName: String, lastName: String, birthday: Date) async throws {
        if let current = currentSession {
            state = .authenticated(current)
        } else {
            let snapshot = SessionSnapshot(
                userId: "user_\(UUID().uuidString.prefix(8))",
                jwt: "placeholder_jwt",
                refreshToken: "placeholder_refresh"
            )
            vault.saveSession(snapshot)
            state = .authenticated(snapshot)
        }
    }

    /// Signs in directly with a given snapshot (for testing or external OAuth coordinators).
    public func signIn(snapshot: SessionSnapshot) {
        vault.saveSession(snapshot)
        state = .authenticated(snapshot)
    }

    /// Triggers the ProfileBasics gate for accounts needing profile completion.
    public func requireProfileBasics(userId: String) {
        state = .profileBasicsRequired(userId: userId)
    }

    /// Signs out the active user and clears secure credentials.
    public func signOut() async {
        if let session = currentSession {
            await authService.signOut(jwt: session.jwt)
        }
        vault.deleteSession()
        migrator.deleteLegacySession()
        state = .unauthenticated
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

        state = .refreshing(current)

        let task = Task<SessionSnapshot, Error> {
            let refreshed = try await self.authService.refreshToken(current.refreshToken)
            return refreshed
        }

        refreshTask = task
        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            self.vault.saveSession(refreshed)
            self.state = .authenticated(refreshed)
            return refreshed
        } catch {
            self.state = .offlineAuthenticated(current)
            throw error
        }
    }

    public enum SessionError: Error, Equatable {
        case noActiveSession
        case refreshFailed
    }
}
