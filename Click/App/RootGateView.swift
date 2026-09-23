import SwiftUI

/// Top-level gate view that manages authentication, profile onboarding, and shell transitions without visual flash.
public struct RootGateView: View {
    @Environment(AppEnvironment.self) private var env

    public init() {}

    public var body: some View {
        Group {
            if CommandLine.arguments.contains("-preview-chat") {
                NavigationStack {
                    ChatView(model: .preview)
                }
            } else if CommandLine.arguments.contains("-preview-clicks") {
                ClicksPreviewHost()
            } else if CommandLine.arguments.contains("-preview-home") {
                NavigationStack {
                    HomeView(initialSnapshot: .preview)
                }
            } else if CommandLine.arguments.contains("-preview-profile") {
                NavigationStack {
                    ProfileView(initialProfile: .preview)
                }
            } else {
                switch env.session.state {
                case .restoring:
                    LaunchLoadingView()
                case .unauthenticated, .terminalError:
                    if CommandLine.arguments.contains("-preview-signup") {
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
            if CommandLine.arguments.contains("-preview-chat") {
                NavigationStack {
                    ChatView(model: .preview)
                }
            } else if CommandLine.arguments.contains("-preview-home") {
                NavigationStack {
                    HomeView(initialSnapshot: .preview)
                }
            } else if CommandLine.arguments.contains("-preview-clicks") {
                ClicksPreviewHost()
            } else if CommandLine.arguments.contains("-preview-profile") {
                NavigationStack {
                    ProfileView(initialProfile: .preview)
                }
            } else if CommandLine.arguments.contains("-preview-onboarding-welcome") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 0, totalSteps: 5, canGoBack: false, onBack: {})
                    WelcomeView(firstName: "Alex") {}
                }
            } else if CommandLine.arguments.contains("-preview-onboarding-interests") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 1, totalSteps: 5, canGoBack: true, onBack: {})
                    InterestsPickerView { _ in }
                }
            } else if CommandLine.arguments.contains("-preview-onboarding-personality") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 2, totalSteps: 5, canGoBack: true, onBack: {})
                    PersonalityTaggingView { _ in }
                }
            } else if CommandLine.arguments.contains("-preview-onboarding-avatar") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 3, totalSteps: 5, canGoBack: true, onBack: {})
                    AvatarUploadView(onUpload: { _ in }, onSkip: {})
                }
            } else if CommandLine.arguments.contains("-preview-onboarding-connections") {
                VStack(spacing: 0) {
                    OnboardingShellChrome(currentStepIndex: 4, totalSteps: 5, canGoBack: true, onBack: {})
                    PriorConnectionsView(onComplete: {}, onSkip: {})
                }
            } else if CommandLine.arguments.contains("-preview-onboarding-flow") || coordinator.needsOnboarding {
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
                    SettingsView()
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
        .environment(meTabAvatar)
        .task(id: env.session.currentSession?.userId) {
            await seedMeTabAvatar()
        }
        .task(id: env.session.currentSession?.userId) {
            // Loaded at the shell so the Clicks badge is right before the tab is opened.
            conversations.attach(env)
            await conversations.load()
        }
    }

    /// Seeds the Me tab from the cached self profile, fetching it only when nothing is cached.
    /// Later profile refreshes on the Me root forward their avatar to `meTabAvatar`.
    private func seedMeTabAvatar() async {
        guard let userID = env.session.currentSession?.userId else {
            meTabAvatar.update(avatarURL: nil)
            return
        }
        if let cached = await env.phase3.cachedProfile(for: userID) {
            meTabAvatar.update(avatarURL: cached.profile.avatarUrl)
        } else if let fresh = try? await env.phase3.refreshSelfProfile(userID: userID) {
            // A failed fetch intentionally leaves the fallback symbol; the Me root refreshes
            // the profile itself and forwards the avatar when it succeeds.
            meTabAvatar.update(avatarURL: fresh.profile.avatarUrl)
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
