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
    public let phase3: Phase3Repository
    public let chat: ChatRepository
    public let beacons: BeaconRepository
    public let events: EventEngagementRepository
    public let me: MeRepository
    public let location: LocationProvider
    public let proximity: ProximityRepository
    public let profiles: ProfileRepository
    public let groups: GroupRepository
    public let hubs: HubRepository
    public let joinedHubs = JoinedHubStore()
    public let timelineCache = ConversationTimelineCache()
    /// The conversation currently on screen, so inbox realtime doesn't count it as unread.
    public var activeChatID: String?

    public init(
        session: SessionController = SessionController(),
        router: AppRouter = AppRouter(),
        settings: SettingsStore = SettingsStore(),
        api: ClickAPIClient? = nil,
        permissions: PermissionCoordinator = .shared,
        avatarService: AvatarService = .shared,
        location: LocationProvider = .shared
    ) {
        self.session = session
        self.router = router
        self.settings = settings
        self.permissions = permissions
        self.avatarService = avatarService
        self.location = location

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
        self.phase3 = Phase3Repository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey
        )
        self.chat = ChatRepository(
            apiClient: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey,
            hubCoordinates: { @Sendable in
                // A transient fix for the hub geofence check only; never stored or shared.
                guard let fix = await location.currentLocation(maximumAge: 60, acceptableAccuracy: 150, timeout: .seconds(4)) else {
                    return nil
                }
                return (fix.coordinate.latitude, fix.coordinate.longitude)
            }
        )
        self.proximity = ProximityRepository(api: resolvedAPI)
        self.profiles = ProfileRepository(api: resolvedAPI)
        self.groups = GroupRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey
        )
        self.beacons = BeaconRepository(api: resolvedAPI)
        self.events = EventEngagementRepository(api: resolvedAPI)
        self.hubs = HubRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey
        )
        self.me = MeRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey
        )

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

        resolveOnboarding(for: userId, coordinator: coordinator)
        return coordinator
    }

    public func retryOnboardingResolution(for userId: String) {
        guard let coordinator = onboardingCoordinators[userId] else { return }
        coordinator.beginLoading()
        resolveOnboarding(for: userId, coordinator: coordinator)
    }

    private func resolveOnboarding(for userId: String, coordinator: OnboardingCoordinator) {
        Task { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            do {
                let resolved = try await self.onboardingRepository.resolveOnboardingState(for: userId)
                coordinator.hydrate(resolved.state, hasAvatar: resolved.hasAvatar)
                self.handlePostAuthResolved()
            } catch {
                coordinator.markLoadFailed("We couldn't load your onboarding state. Check your connection and try again.")
            }
        }
    }

    /// Handles route flushing only when gates are cleared
    public func handlePostAuthResolved() {
        switch session.state {
        case .restoring, .profileBasicsRequired, .unauthenticated, .terminalError:
            return
        case .authenticated, .refreshing, .offlineAuthenticated:
            break
        }

        guard let snapshot = session.currentSession else { return }
        let coordinator = onboardingCoordinator(for: snapshot.userId)
        if !coordinator.needsOnboarding {
            router.flushPendingRoute()
        }
    }

    /// Gate-aware deep-link entry. Authenticated is not enough: blocking profile/onboarding
    /// gates must finish before the route is executed.
    public func handleIncomingURL(_ url: URL) {
        guard let route = router.parseIncomingURL(url) else { return }
        handleIncomingRoute(route)
    }

    /// Gate-aware entry for typed intents originating from push notifications and native services.
    public func handleIncomingRoute(_ route: AppRoute) {
        guard let snapshot = session.currentSession else {
            router.pendingRoute = route
            return
        }

        switch session.state {
        case .profileBasicsRequired, .restoring:
            router.pendingRoute = route
            return
        default:
            break
        }

        let coordinator = onboardingCoordinator(for: snapshot.userId)
        if coordinator.needsOnboarding {
            router.pendingRoute = route
        } else {
            router.resolveRoute(route)
        }
    }

    /// Initializes and restores local app state.
    public func bootstrap() async {
        await session.restoreSession()
    }
}
