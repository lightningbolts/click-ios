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
                NavigationStack {
                    ClicksView(initialSnapshot: .preview)
                }
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
                NavigationStack {
                    ClicksView(initialSnapshot: .preview)
                }
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
                    .tint(ClickColors.primary)
            }
        }
    }
}

/// The 5-tab main shell view (Home, Add Click, Clicks, Map, Me).
public struct MainTabShellView: View {
    @Environment(AppEnvironment.self) private var env

    public init() {}

    public var body: some View {
        @Bindable var r = env.router
        TabView(selection: $r.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: MainTab.home) {
                NavigationStack(path: $r.homePath) {
                    HomeView()
                }
            }

            Tab("Add Click", systemImage: "plus.circle.fill", value: MainTab.addClick) {
                NavigationStack(path: $r.addClickPath) {
                    FeedPlaceholderView(title: "Add Click")
                }
            }

            Tab("Clicks", systemImage: "bubble.left.and.bubble.right.fill", value: MainTab.connections) {
                NavigationStack(path: $r.connectionsPath) {
                    ClicksView()
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .userProfile(let userID, let connectionID):
                                ProfileView(userID: userID, connectionID: connectionID)
                            case .chat(let route):
                                ChatView(
                                    model: ConversationModel(
                                        identity: route.conversationIdentity,
                                        chatRepository: env.chat,
                                        currentUserID: env.session.currentSession?.userId ?? "",
                                        currentUserName: "You"
                                    )
                                )
                            default:
                                FeedPlaceholderView(title: "Coming Soon")
                            }
                        }
                }
            }

            Tab("Map", systemImage: "map.fill", value: MainTab.map) {
                NavigationStack(path: $r.mapPath) {
                    FeedPlaceholderView(title: "Map")
                }
            }

            Tab("Me", systemImage: "person.circle.fill", value: MainTab.settings) {
                NavigationStack(path: $r.settingsPath) {
                    ProfileView()
                }
            }
        }
        .tint(ClickColors.primary)
    }
}

private struct FeedPlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: ClickSpacing.medium) {
            Text(title)
                .font(ClickTypography.title)
            Text("Native implementation vertical slice")
                .font(ClickTypography.subheadline)
                .foregroundStyle(ClickColors.secondaryLabel)
        }
        .navigationTitle(title)
        .background(ClickColors.background)
    }
}

private struct SettingsPlaceholderView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section("Account") {
                if let session = env.session.currentSession {
                    LabeledContent("User ID", value: session.userId)
                }
                Button("Test Profile Basics Gate") {
                    env.session.requireProfileBasics(userId: env.session.currentSession?.userId ?? "test_user")
                }
                Button("Sign Out", role: .destructive) {
                    Task {
                        await env.session.signOut()
                    }
                }
            }

            Section("Preferences") {
                Toggle("Dark Mode", isOn: Bindable(env.settings).darkModeEnabled)
                Toggle("Message Notifications", isOn: Bindable(env.settings).messageNotificationsEnabled)
            }
        }
        .navigationTitle("Me")
    }
}
