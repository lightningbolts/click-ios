import Foundation
import Observation

/// Snapshot of an active authenticated session.
public struct SessionSnapshot: Equatable, Sendable {
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

/// Session controller protocol for dependency injection and mocking.
@MainActor
public protocol SessionControlling: AnyObject {
    var state: SessionState { get }
    var currentSession: SessionSnapshot? { get }
    func restoreSession() async
    func signIn(snapshot: SessionSnapshot)
    func signOut() async
    func refreshSession() async throws -> SessionSnapshot
}

/// Represents the high-level authentication lifecycle of the client.
public enum SessionState: Equatable, Sendable {
    case restoring
    case unauthenticated
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
    private var refreshTask: Task<SessionSnapshot, Error>?

    public init(migrator: LegacyKMPStateMigrator = .shared) {
        self.migrator = migrator
    }

    public var currentSession: SessionSnapshot? {
        switch state {
        case .authenticated(let snapshot),
             .refreshing(let snapshot),
             .offlineAuthenticated(let snapshot):
            return snapshot
        case .restoring, .unauthenticated, .terminalError:
            return nil
        }
    }

    /// Restores the existing session from Keychain or migrates from legacy KMP.
    public func restoreSession() async {
        state = .restoring

        // 1. Attempt legacy KMP migration if available
        if let legacy = migrator.readLegacySession() {
            let expiresAtDate: Date? = legacy.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let snapshot = SessionSnapshot(
                userId: legacy.userId ?? "legacy_user",
                jwt: legacy.jwt,
                refreshToken: legacy.refreshToken,
                expiresAt: expiresAtDate
            )
            state = .authenticated(snapshot)
            return
        }

        // 2. Default to unauthenticated
        state = .unauthenticated
    }

    public func signIn(snapshot: SessionSnapshot) {
        state = .authenticated(snapshot)
    }

    public func signOut() async {
        migrator.deleteLegacySession()
        state = .unauthenticated
    }

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
            // Placeholder for API refresh exchange; will be integrated in Phase 1
            let updated = current
            return updated
        }

        refreshTask = task
        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            state = .authenticated(refreshed)
            return refreshed
        } catch {
            state = .offlineAuthenticated(current)
            throw error
        }
    }

    public enum SessionError: Error, Equatable {
        case noActiveSession
        case refreshFailed
    }
}
