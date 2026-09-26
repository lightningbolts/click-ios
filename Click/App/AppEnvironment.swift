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
    public let encounterContext: EncounterContextRepository
    public let relationships: RelationshipRepository
    public let telemetryQueue = TelemetryQueue()
    public let connectionTelemetry: ConnectionFlowTelemetry
    public let friction: FrictionTelemetry
    public let joinedHubs = JoinedHubStore()
    public let timelineCache = ConversationTimelineCache()
    /// The user's own profile, plans and saved events, shared by every screen that shows them.
    let selfData = SelfDataStore()
    public let network: NetworkMonitor
    /// Optimistic sends and uploads that outlive the chat screen.
    public let pendingSends = PendingSendStore()
    /// Shared display-name resolver for chat, groups and hubs.
    public let identities: IdentityCache
    /// The conversation currently on screen, so inbox realtime doesn't count it as unread.
    public var activeChatID: String?
    /// The on-screen direct chat's connection ID (pushes may carry either ID).
    public var activeConnectionID: String?
    /// The latest in-person Click Drop window (post-connect), so Drops sent in it carry the encounter.
    public var clickDropSession: ClickDropSession?
    /// A message to scroll to when its conversation next opens (search deep links).
    public var pendingMessageFocus: MessageFocus?

    /// One live model per conversation for the session: re-entering a chat shows exactly what was
    /// on screen (timeline, decrypted media, older pages) and refreshes in place.
    private var conversationModels: [String: ConversationModel] = [:]

    public func conversationModel(for identity: ConversationIdentity) -> ConversationModel {
        if let hubID = identity.hubID, let existing = conversationModels[hubID] {
            return existing
        }
        if let connID = identity.connectionID, let existing = conversationModels[connID] {
            return existing
        }
        if !identity.chatID.isEmpty, let existing = conversationModels[identity.chatID] {
            return existing
        }
        if let existing = conversationModels.values.first(where: { model in
            (identity.connectionID != nil && model.identity.connectionID == identity.connectionID)
            || (!identity.chatID.isEmpty && model.identity.chatID == identity.chatID)
            || (identity.hubID != nil && model.identity.hubID == identity.hubID)
        }) {
            if let connID = identity.connectionID { conversationModels[connID] = existing }
            if !identity.chatID.isEmpty { conversationModels[identity.chatID] = existing }
            return existing
        }

        let model = ConversationModel(
            identity: identity,
            chatRepository: chat,
            currentUserID: session.currentSession?.userId ?? "",
            currentUserName: "You",
            timelineCache: timelineCache,
            pendingSends: pendingSends,
            identities: identities,
            store: .shared
        )
        model.onLocalSend = { [weak self] chatID, messageID, content, type, date in
            self?.inbox?.applyLocalSend(chatID: chatID, messageID: messageID, content: content, messageType: type, date: date)
        }
        model.onForwarded = { [weak self] target, sent in
            self?.liveModel(chatID: sent.chatID.isEmpty ? target.chatID : sent.chatID)?.appendExternal(sent)
        }
        if let connID = identity.connectionID { conversationModels[connID] = model }
        if !identity.chatID.isEmpty { conversationModels[identity.chatID] = model }
        if let hubID = identity.hubID { conversationModels[hubID] = model }
        return model
    }

    /// The Clicks inbox model owned by the shell (weak: the shell owns it).
    weak var inbox: ConversationListModel?

    private func liveModel(chatID: String) -> ConversationModel? {
        conversationModels[chatID] ?? conversationModels.values.first { $0.identity.chatID == chatID }
    }

    /// The inbox channel saw a new message: an open chat whose own channel is down applies it.
    func forwardInboxInsert(_ payload: RealtimeMessagePayload) {
        guard let model = liveModel(chatID: payload.chatID), model.isVisible else { return }
        Task { await model.receiveInboxInsert(payload) }
    }

    /// Foreground return: the chat on screen (if any) re-checks its socket and catches up.
    func resumeLiveConversations() {
        // Models are stored under several keys (chat, connection, hub): resume each once.
        var seen = Set<ObjectIdentifier>()
        for model in conversationModels.values where model.isVisible && seen.insert(ObjectIdentifier(model)).inserted {
            Task { await model.resume() }
        }
    }

    public init(
        session: SessionController = SessionController(),
        router: AppRouter = AppRouter(),
        settings: SettingsStore = SettingsStore(),
        api: ClickAPIClient? = nil,
        permissions: PermissionCoordinator = .shared,
        avatarService: AvatarService = .shared,
        location: LocationProvider = .shared,
        network: NetworkMonitor? = nil
    ) {
        self.network = network ?? NetworkMonitor()
        self.session = session
        self.router = router
        self.settings = settings
        self.permissions = permissions
        self.avatarService = avatarService
        self.location = location

        // Every realtime (re)join asks for a fresh token instead of reusing a captured one.
        ChatRealtimeManager.tokenProvider = { [weak session] in
            await session?.validAccessToken()
        }

        let resolvedAPI = api ?? ClickAPIClient(
            baseURL: AppConfig.shared.apiBaseURL,
            tokenProvider: { [weak session] in
                await session?.validAccessToken()
            },
            tokenRefresher: { [weak session] in
                guard let session = session else { throw APIError.unauthorized }
                let refreshed = try await session.refreshSession()
                return refreshed.jwt
            }
        )
        self.api = resolvedAPI
        let identities = IdentityCache(api: resolvedAPI)
        self.identities = identities
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
            identities: identities,
            hubCoordinates: { @Sendable in
                // A transient fix for the hub geofence check only; never stored or shared.
                guard let fix = await location.currentLocation(maximumAge: 60, acceptableAccuracy: 150, timeout: .seconds(4)) else {
                    return nil
                }
                return (fix.coordinate.latitude, fix.coordinate.longitude)
            }
        )
        self.proximity = ProximityRepository(api: resolvedAPI)
        self.encounterContext = EncounterContextRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey
        )
        self.relationships = RelationshipRepository(api: resolvedAPI)
        self.connectionTelemetry = ConnectionFlowTelemetry(queue: telemetryQueue)
        self.friction = FrictionTelemetry(queue: telemetryQueue)
        self.profiles = ProfileRepository(api: resolvedAPI)
        self.groups = GroupRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey,
            identities: identities
        )
        self.beacons = BeaconRepository(api: resolvedAPI)
        self.events = EventEngagementRepository(api: resolvedAPI)
        self.hubs = HubRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey,
            identities: identities
        )
        self.me = MeRepository(
            api: resolvedAPI,
            supabaseURL: AppConfig.shared.supabaseURL,
            supabaseAnonKey: AppConfig.shared.supabaseAnonKey
        )

        // Connect dependencies to session controller
        session.apiClient = resolvedAPI
        session.settingsStore = settings
        session.onSignOut = { [weak self] in
            await self?.clearSessionCaches()
        }
        selfData.attach(self)
        session.onPostAuthResolved = { [weak self] in
            self?.handlePostAuthResolved()
        }
    }

    /// Everything user-scoped that lives outside the Keychain and settings store.
    public func clearSessionCaches() async {
        await identities.removeAll()
        timelineCache.clear()
        pendingSends.removeAll()
        await beacons.clearCache()
        await telemetryQueue.removeAll()
        await EventReminderScheduler.cancelAll()
        onboardingCoordinators.removeAll()
        conversationModels.removeAll()
    }

    private var onboardingCoordinators: [String: OnboardingCoordinator] = [:]

    /// Retrieves or initializes the OnboardingCoordinator for a given user, reconciling with server truth.
    public func onboardingCoordinator(for userId: String) -> OnboardingCoordinator {
        if let existing = onboardingCoordinators[userId] {
            return existing
        }
        let coordinator = OnboardingCoordinator(userId: userId)
        onboardingCoordinators[userId] = coordinator
        if let cached = settings.onboardingState(for: userId) {
            coordinator.adoptCachedCompletion(cached)
        }

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
            var prefetched = self.session.takeRecentProfile(for: userId)
            // Transient failures retry quietly (the launch screen stays up) before any error.
            for attempt in 0..<3 {
                do {
                    let resolved = try await self.onboardingRepository.resolveOnboardingState(for: userId, prefetchedProfile: prefetched)
                    coordinator.hydrate(resolved.state, hasAvatar: resolved.hasAvatar)
                    self.handlePostAuthResolved()
                    return
                } catch {
                    prefetched = nil
                    // A cached completion already admitted the user; a failed background
                    // re-check must not bounce them back to onboarding.
                    guard coordinator.step != .complete else { return }
                    if attempt < 2 { try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3)) }
                }
            }
            coordinator.markLoadFailed(self.network.isOnline
                ? "Click couldn't finish setting up. Try again in a moment."
                : "You're offline. Connect to the internet and try again.")
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
        let api = self.api
        await telemetryQueue.setSender { envelope in
            let body = try JSONSerialization.data(withJSONObject: envelope.payload.mapValues(\.jsonObject))
            _ = try await api.executeRaw(APIRequest(path: envelope.path, method: .post, body: body))
        }
        await session.restoreSession()
    }

    /// Sends queued telemetry (called on foreground and background; never blocks the UI).
    /// A chat to open with the hangout planner showing (set by "Plan" on a profile; the chat
    /// consumes it when it appears). Keyed by connection ID.
    var pendingPlanConnectionID: String?

    @ObservationIgnored private var lastPresencePing: Date?

    /// Hangout detection (opt-in): on returning to the app, share a fresh position so Clicks
    /// who are with you right now (and opted in) both get "Hanging out?". At most every 10
    /// minutes, and never without a recent, reasonably precise fix.
    func reportPresenceIfEnabled() {
        guard settings.hangoutDetectionOptIn, location.isAuthorized, session.currentSession != nil else { return }
        if let last = lastPresencePing, Date().timeIntervalSince(last) < 600 { return }
        lastPresencePing = Date()
        Task {
            guard let fix = await location.currentLocation(maximumAge: 120, acceptableAccuracy: 100, timeout: .seconds(6)) else { return }
            try? await relationships.reportPresence(fix.coordinate)
        }
    }

    public func flushTelemetry() {
        Task.detached(priority: .utility) { [telemetryQueue] in await telemetryQueue.flush() }
    }
}

/// Where a search result lives: any of the conversation's IDs plus the message.
public struct MessageFocus: Equatable, Sendable {
    public let conversationIDs: Set<String>
    public let messageID: String

    public init(conversationIDs: [String?], messageID: String) {
        self.conversationIDs = Set(conversationIDs.compactMap { $0 }.filter { !$0.isEmpty })
        self.messageID = messageID
    }

    public func matches(_ identity: ConversationIdentity) -> Bool {
        !conversationIDs.isDisjoint(with: [identity.chatID, identity.connectionID, identity.hubID].compactMap { $0 })
    }
}

/// A post-connect collaboration window (`ProximityMatch.encounterID` / `collaborationEndsAt`).
public struct ClickDropSession: Equatable, Sendable {
    public let connectionID: String
    public let encounterID: String
    public let endsAt: Date

    /// The encounter for Drops sent to `connectionID` while the window is open.
    public func encounterID(for connectionID: String?, now: Date = .now) -> String? {
        connectionID == self.connectionID && endsAt > now ? encounterID : nil
    }
}
