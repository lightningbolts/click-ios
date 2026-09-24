import SwiftUI

/// Top-level gate view that manages authentication, profile onboarding, and shell transitions without visual flash.
public struct RootGateView: View {
    @Environment(AppEnvironment.self) private var env

    public init() {}

    private static var isShellPreview: Bool { DebugLaunch.has("-preview-shell") }

    public var body: some View {
        Group {
            if Self.isShellPreview {
                // DEBUG-only: the real shell without a session, for layout checks in the Simulator.
                MainTabShellView()
            } else if DebugLaunch.has("-preview-chat") {
                NavigationStack {
                    ChatView(model: .preview)
                }
            } else if DebugLaunch.has("-preview-clicks") {
                ClicksPreviewHost()
            } else {
                switch env.session.state {
                case .restoring:
                    LaunchLoadingView()
                case .unauthenticated, .terminalError:
                    if DebugLaunch.has("-preview-signup") {
                        AuthView(initialMode: .signUp)
                    } else {
                        AuthView(initialMode: .signIn)
                    }
                case .profileBasicsRequired(let userId):
                    ProfileBasicsGateView(userId: userId)
                case .authenticated(let snapshot), .refreshing(let snapshot), .offlineAuthenticated(let snapshot):
                    AuthenticatedGateView(snapshot: snapshot)
                }
            }
        }
        .tint(ClickColors.accentForeground)
        .animation(ClickMotion.subtleFade, value: env.session.state)
    }
}

/// Routes authenticated sessions through onboarding or into the main tab shell.
private struct AuthenticatedGateView: View {
    @Environment(AppEnvironment.self) private var env
    let snapshot: SessionSnapshot

    var body: some View {
        let coordinator = env.onboardingCoordinator(for: snapshot.userId)

        Group {
            if DebugLaunch.has("-preview-chat") {
                NavigationStack {
                    ChatView(model: .preview)
                }
            } else if DebugLaunch.has("-preview-clicks") {
                ClicksPreviewHost()
            } else if DebugLaunch.has("-preview-onboarding-welcome") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 0, totalSteps: 5, canGoBack: false, onBack: {})
                    WelcomeView(firstName: "Alex") {}
                }
            } else if DebugLaunch.has("-preview-onboarding-interests") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 1, totalSteps: 5, canGoBack: true, onBack: {})
                    InterestsPickerView { _ in }
                }
            } else if DebugLaunch.has("-preview-onboarding-personality") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 2, totalSteps: 5, canGoBack: true, onBack: {})
                    PersonalityTaggingView { _ in }
                }
            } else if DebugLaunch.has("-preview-onboarding-avatar") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 3, totalSteps: 5, canGoBack: true, onBack: {})
                    AvatarUploadView(onUpload: { _ in }, onSkip: {})
                }
            } else if DebugLaunch.has("-preview-onboarding-connections") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 4, totalSteps: 5, canGoBack: true, onBack: {})
                    PriorConnectionsView(onComplete: {}, onSkip: {})
                }
            } else if DebugLaunch.has("-preview-onboarding-flow") || coordinator.needsOnboarding {
                OnboardingFlowView(
                    coordinator: coordinator,
                    firstName: nil,
                    onFinished: {
                        env.handlePostAuthResolved()
                    }
                )
            } else {
                MainTabShellView()
            }
        }
        .animation(ClickMotion.subtleFade, value: coordinator.step)
    }
}

/// Subtle initial launch loading view avoiding visual jump.
private struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            ClickColors.background.ignoresSafeArea()
            VStack(spacing: ClickSpacing.md) {
                ClickLogo(style: .mark, size: 52)
                ProgressView()
                    .tint(ClickColors.accentForeground)
            }
        }
    }
}

/// The 5-tab main shell (Home, Add Click, Clicks, Map, Me) using the native `TabView`.
/// Each tab owns an independent `NavigationStack` whose path lives in `AppRouter`, and every
/// stack registers the same canonical route destinations.
public struct MainTabShellView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meTabAvatar = MeTabAvatarModel()
    @State private var conversations = ConversationListModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        @Bindable var r = env.router
        // Routing selection through `selectTab` makes re-tapping the active tab pop to its root.
        let selection = Binding(get: { r.selectedTab }, set: { r.selectTab($0) })

        TabView(selection: selection) {
            Tab("Home", systemImage: "house.fill", value: MainTab.home) {
                NavigationStack(path: $r.homePath) {
                    HomeView()
                        .appRouteDestinations()
                }
            }

            Tab("Add Click", systemImage: "plus.circle.fill", value: MainTab.addClick) {
                NavigationStack(path: $r.addClickPath) {
                    AddClickView()
                        .appRouteDestinations()
                }
            }

            Tab("Clicks", systemImage: "person.2.fill", value: MainTab.connections) {
                NavigationStack(path: $r.connectionsPath) {
                    ClicksView(model: conversations)
                        .appRouteDestinations()
                }
            }
            .badge(conversations.unreadTotal)

            Tab("Map", systemImage: "location.fill", value: MainTab.map) {
                NavigationStack(path: $r.mapPath) {
                    ClickMapView()
                        .appRouteDestinations()
                }
            }

            Tab(value: MainTab.settings) {
                NavigationStack(path: $r.settingsPath) {
                    MeView()
                        .appRouteDestinations()
                }
            } label: {
                Label {
                    Text("Me")
                } icon: {
                    if let avatar = meTabAvatar.image {
                        Image(uiImage: avatar).renderingMode(.original)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                    }
                }
            }
        }
        .tint(ClickColors.accentForeground)
        .sheet(item: $r.presentedSheet) { item in
            NavigationStack {
                AppRouteDestination(route: item.route)
                    .appRouteDestinations()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .environment(meTabAvatar)
            .environment(conversations)
        }
        .environment(meTabAvatar)
        .environment(conversations)
        .task(id: env.session.currentSession?.userId) {
            await seedMeTabAvatar()
        }
        .onChange(of: scenePhase) { _, phase in
            // Rebind with the current token on return; tear down while backgrounded.
            switch phase {
            case .active:
                conversations.startRealtime()
                Task { await conversations.refreshIfStale() }
            case .background:
                conversations.stopRealtime()
            default:
                break
            }
        }
        .task(id: env.session.currentSession?.userId) {
            // Ghost Mode was removed from the app. Clear the server bit an older client may
            // have left on, so nobody stays hidden from Nearby without a way to turn it off.
            try? await env.me.clearLegacyGhostMode()
        }
        .task(id: env.session.currentSession?.userId) {
            // Decrypted timelines never carry over from another account.
            env.timelineCache.clear()
            PeerProfileModel.resetRegistry()
            // Loaded at the shell so the Clicks badge is right before the tab is opened.
            conversations.attach(env)
            conversations.startRealtime()
            await conversations.load()
            // Replay Tap to Connect captures that were saved while offline (same user only).
            if let userID = env.session.currentSession?.userId,
               !(await env.proximity.flushQueue(userID: userID)).isEmpty {
                await conversations.refresh()
            }
        }
    }

    /// Seeds the Me tab from the cached self profile, fetching it only when nothing is cached.
    /// Later profile refreshes on the Me root forward their avatar to `meTabAvatar`.
    private func seedMeTabAvatar() async {
        guard let userID = env.session.currentSession?.userId else {
            meTabAvatar.update(avatarURL: nil)
            return
        }
        if let cached = await env.me.cachedSelfProfile(userID: userID) {
            meTabAvatar.update(avatarURL: cached.avatarURL)
        } else if let fresh = try? await env.me.selfProfile(userID: userID) {
            // A failed fetch intentionally leaves the fallback symbol; the Me root refreshes
            // the profile itself and forwards the avatar when it succeeds.
            meTabAvatar.update(avatarURL: fresh.avatarURL)
        }
    }
}

/// Hosts the Clicks design preview with a seeded, network-free inbox model.
private struct ClicksPreviewHost: View {
    @State private var model = ConversationListModel(initialSnapshot: .preview)

    var body: some View {
        NavigationStack {
            ClicksView(model: model)
        }
    }
}
