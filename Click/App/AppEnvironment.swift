import Foundation
import Observation

/// The application's top-level dependency container.
@Observable
@MainActor
public final class AppEnvironment {
    public let session: SessionController
    public let router: AppRouter
    public let settings: SettingsStore
    public let api: ClickAPIClient
    public let permissions: PermissionCoordinator
    public let avatarService: AvatarService
    public let onboardingRepository: OnboardingRepository

    public init(
        session: SessionController = SessionController(),
        router: AppRouter = AppRouter(),
        settings: SettingsStore = SettingsStore(),
        api: ClickAPIClient? = nil,
        permissions: PermissionCoordinator = .shared,
        avatarService: AvatarService = .shared
    ) {
        self.session = session
        self.router = router
        self.settings = settings
        self.permissions = permissions
        self.avatarService = avatarService

        let resolvedAPI = api ?? ClickAPIClient(
            baseURL: AppConfig.shared.apiBaseURL,
            tokenProvider: { [weak session] in
                await session?.currentSession?.jwt
            },
            tokenRefresher: { [weak session] in
                guard let session = session else { throw APIError.unauthorized }
                let refreshed = try await session.refreshSession()
                return refreshed.jwt
            }
        )
        self.api = resolvedAPI
        self.onboardingRepository = OnboardingRepository(client: resolvedAPI, settings: settings)

        // Connect dependencies to session controller
        session.apiClient = resolvedAPI
        session.settingsStore = settings
        session.onPostAuthResolved = { [weak self] in
            self?.handlePostAuthResolved()
        }
    }

    private var onboardingCoordinators: [String: OnboardingCoordinator] = [:]

    /// Retrieves or initializes the OnboardingCoordinator for a given user, reconciling with server truth.
    public func onboardingCoordinator(for userId: String) -> OnboardingCoordinator {
        if let existing = onboardingCoordinators[userId] {
            return existing
        }
        let coordinator = OnboardingCoordinator(userId: userId)
        onboardingCoordinators[userId] = coordinator

        // Reconcile against remote server truth and legacy hints
        Task { [weak self, weak coordinator] in
            guard let self = self, let coordinator = coordinator else { return }
            let resolved = await self.onboardingRepository.resolveOnboardingState(for: userId)
            coordinator.hydrate(resolved.state, hasAvatar: resolved.hasAvatar)
            self.handlePostAuthResolved()
        }

        return coordinator
    }

    /// Handles route flushing only when gates are cleared
    public func handlePostAuthResolved() {
        guard let session = session.currentSession else { return }
        let coordinator = onboardingCoordinator(for: session.userId)
        if !coordinator.needsOnboarding {
            router.flushPendingRoute()
        }
    }

    /// Initializes and restores local app state.
    public func bootstrap() async {
        await session.restoreSession()
    }
}
