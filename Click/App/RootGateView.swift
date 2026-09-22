import SwiftUI

/// Top-level gate view that manages authentication, profile onboarding, and shell transitions without visual flash.
public struct RootGateView: View {
    @Environment(AppEnvironment.self) private var env

    public init() {}

    public var body: some View {
        Group {
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
            case .authenticated, .refreshing, .offlineAuthenticated:
                MainTabShellView()
            }
        }
        .animation(ClickMotion.subtleFade, value: env.session.state)
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
                    FeedPlaceholderView(title: "Home")
                }
            }

            Tab("Add Click", systemImage: "plus.circle.fill", value: MainTab.addClick) {
                NavigationStack(path: $r.addClickPath) {
                    FeedPlaceholderView(title: "Add Click")
                }
            }

            Tab("Clicks", systemImage: "bubble.left.and.bubble.right.fill", value: MainTab.connections) {
                NavigationStack(path: $r.connectionsPath) {
                    FeedPlaceholderView(title: "Clicks")
                }
            }

            Tab("Map", systemImage: "map.fill", value: MainTab.map) {
                NavigationStack(path: $r.mapPath) {
                    FeedPlaceholderView(title: "Map")
                }
            }

            Tab("Me", systemImage: "person.circle.fill", value: MainTab.settings) {
                NavigationStack(path: $r.settingsPath) {
                    SettingsPlaceholderView()
                }
            }
        }
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
